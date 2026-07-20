[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("LocalBuild", "Plan", "Prepare", "Publish")]
  [string]$Mode,

  [ValidatePattern('^v?\d+\.\d+\.\d+$')]
  [string]$Version,

  [string]$Summary,

  [string]$ReleaseNotes,

  [string]$RepositoryRoot = (Get-Location).Path,

  [string]$ConfigPath = ".codex-release.json",

  [switch]$SkipBuild,

  [switch]$AllowExistingHead
)

$ErrorActionPreference = "Stop"
$normalizedVersion = if ($Version) { $Version.TrimStart("v") } else { $null }
$script:GitHubCli = $null
$script:Config = $null
$script:ResolvedRepositoryRoot = $null
$script:ConfigFile = $null
$script:Tag = $null
$utilsScript = Join-Path $PSScriptRoot "release-utils.ps1"

if (-not (Test-Path -LiteralPath $utilsScript)) {
  throw "Release utilities missing: $utilsScript"
}
. $utilsScript

if ($Mode -ne "LocalBuild" -and -not $Version) {
  throw "Version is required for $Mode"
}
if ($Mode -ne "LocalBuild" -and [string]::IsNullOrWhiteSpace($Summary)) {
  throw "Summary is required for $Mode"
}
if ($Summary -and $Summary -match "[`r`n]") {
  throw "Summary must be one line"
}
if ($SkipBuild -and $Mode -ne "Prepare") {
  throw "SkipBuild is only valid for Prepare"
}
if ($AllowExistingHead -and $Mode -ne "Publish") {
  throw "AllowExistingHead is only valid for Publish"
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments) {
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

function Invoke-Captured([string]$FilePath, [string[]]$Arguments) {
  $output = & $FilePath @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return (($output | Out-String).Trim())
}

function Get-OptionalProperty($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) {
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }
  return $property.Value
}

function Get-RequiredProperty($Object, [string]$Name, [string]$Context) {
  $value = Get-OptionalProperty $Object $Name
  if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
    throw "Missing required config field: $Context.$Name"
  }
  return $value
}

function Get-NormalizedPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
}

function Assert-PathInsideRepository([string]$Path) {
  $fullPath = Get-NormalizedPath $Path
  $root = $script:ResolvedRepositoryRoot
  $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
  if (
    -not $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
    -not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
  ) {
    throw "Configured path escapes repository root: $Path"
  }
  return $fullPath
}

function Resolve-RepositoryPath([string]$Path) {
  if ([IO.Path]::IsPathRooted($Path)) {
    throw "Configured path must be relative: $Path"
  }
  return Assert-PathInsideRepository (Join-Path $script:ResolvedRepositoryRoot $Path)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Expand-ConfigTokens([string]$Value) {
  if ($null -eq $Value) {
    return $null
  }
  return $Value.
    Replace("{projectName}", [string]$script:Config.projectName).
    Replace("{version}", $normalizedVersion).
    Replace("{tag}", $script:Tag)
}

function Initialize-ReleaseContext {
  if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root not found: $RepositoryRoot"
  }

  $script:ResolvedRepositoryRoot = Get-NormalizedPath (Resolve-Path -LiteralPath $RepositoryRoot).Path
  $candidateConfig = if ([IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
  }
  else {
    Join-Path $script:ResolvedRepositoryRoot $ConfigPath
  }
  if (-not (Test-Path -LiteralPath $candidateConfig -PathType Leaf)) {
    throw "Release config not found: $candidateConfig"
  }
  $script:ConfigFile = Assert-PathInsideRepository (Resolve-Path -LiteralPath $candidateConfig).Path
  $script:Config = Get-Content -Raw -Encoding UTF8 $script:ConfigFile | ConvertFrom-Json
  Assert-ReleaseConfig
  if ($Mode -eq "LocalBuild" -and -not $normalizedVersion) {
    $normalizedVersion = Get-CurrentVersion
  }
  $tagPrefix = [string](Get-OptionalProperty $script:Config "tagPrefix" "v")
  $script:Tag = "$tagPrefix$normalizedVersion"
}

function Assert-ReleaseConfig {
  $schemaVersion = [int](Get-RequiredProperty $script:Config "schemaVersion" "root")
  if ($schemaVersion -notin @(1, 2)) {
    throw "Unsupported release config schemaVersion"
  }
  foreach ($name in @("projectName", "branch", "remote")) {
    Get-RequiredProperty $script:Config $name "root" | Out-Null
  }

  $versionConfig = Get-RequiredProperty $script:Config "version" "root"
  $readConfig = Get-RequiredProperty $versionConfig "read" "version"
  Get-RequiredProperty $readConfig "path" "version.read" | Out-Null
  $readPattern = [string](Get-RequiredProperty $readConfig "pattern" "version.read")
  $readRegex = [regex]::new($readPattern)
  if ($readRegex.GetGroupNames() -notcontains "version") {
    throw "version.read.pattern must contain a named 'version' capture group"
  }

  foreach ($update in @(Get-OptionalProperty $versionConfig "updates" @())) {
    Get-RequiredProperty $update "path" "version.updates[]" | Out-Null
    Get-RequiredProperty $update "pattern" "version.updates[]" | Out-Null
    Get-RequiredProperty $update "replacement" "version.updates[]" | Out-Null
    $expectedMatches = [int](Get-OptionalProperty $update "expectedMatches" 1)
    if ($expectedMatches -lt 1) {
      throw "version.updates[].expectedMatches must be positive"
    }
  }

  $prepare = Get-RequiredProperty $script:Config "prepare" "root"
  foreach ($command in @(Get-OptionalProperty $prepare "commands" @())) {
    Get-RequiredProperty $command "name" "prepare.commands[]" | Out-Null
    Get-RequiredProperty $command "command" "prepare.commands[]" | Out-Null
  }
  foreach ($artifact in @(Get-OptionalProperty $prepare "artifacts" @())) {
    Get-RequiredProperty $artifact "source" "prepare.artifacts[]" | Out-Null
  }

  $publish = Get-RequiredProperty $script:Config "publish" "root"
  $release = Get-RequiredProperty $publish "release" "publish"
  $releaseMode = [string](Get-RequiredProperty $release "mode" "publish.release")
  if ($releaseMode -notin @("publish-draft", "create", "none")) {
    throw "publish.release.mode must be publish-draft, create, or none"
  }
}

function Assert-RepositoryRoot {
  $gitRoot = Invoke-Captured "git" @("rev-parse", "--show-toplevel")
  $normalizedGitRoot = Get-NormalizedPath $gitRoot
  if (-not $normalizedGitRoot.Equals($script:ResolvedRepositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository root mismatch: $gitRoot"
  }
}

function Assert-Repository {
  Assert-RepositoryRoot
  $branch = Invoke-Captured "git" @("branch", "--show-current")
  if ($branch -ne [string]$script:Config.branch) {
    throw "Release requires branch $($script:Config.branch); current branch is $branch"
  }

  $remote = [string]$script:Config.remote
  $remoteUrl = Invoke-Captured "git" @("remote", "get-url", $remote)
  $remotePattern = Get-OptionalProperty $script:Config "remoteUrlPattern"
  if ($remotePattern -and $remoteUrl -notmatch [string]$remotePattern) {
    throw "Unexpected $remote remote: $remoteUrl"
  }
}

function Assert-LocalTagAbsent([string]$Tag) {
  & git show-ref --verify --quiet "refs/tags/$Tag"
  if ($LASTEXITCODE -eq 0) {
    throw "Local tag already exists: $Tag"
  }
}

function Get-RemoteTag([string]$Tag) {
  return Invoke-Captured "git" @(
    "ls-remote",
    "--tags",
    [string]$script:Config.remote,
    "refs/tags/$Tag"
  )
}

function Assert-RemoteTagAbsent([string]$Tag) {
  if (Get-RemoteTag $Tag) {
    throw "Remote tag already exists: $Tag"
  }
}

function Update-RemoteBranch {
  $remote = [string]$script:Config.remote
  $branch = [string]$script:Config.branch
  Invoke-Checked "git" @(
    "fetch",
    "--no-tags",
    $remote,
    "refs/heads/${branch}:refs/remotes/${remote}/${branch}"
  )
}

function Assert-RemoteIsAncestor {
  $remoteRef = "$($script:Config.remote)/$($script:Config.branch)"
  & git merge-base --is-ancestor $remoteRef HEAD
  if ($LASTEXITCODE -ne 0) {
    throw "$remoteRef is ahead or diverged; release stopped"
  }
}

function Resolve-GitHubCli {
  $command = Get-Command gh -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $fallback = Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\bin\gh.exe"
  if (Test-Path -LiteralPath $fallback) {
    return $fallback
  }

  throw "GitHub CLI is not installed"
}

function Assert-GitHubAuth {
  $script:GitHubCli = Resolve-GitHubCli
  Invoke-Checked $script:GitHubCli @("auth", "status")
}

function Disable-StaleLoopbackProxy {
  $proxyValue = @($env:HTTPS_PROXY, $env:HTTP_PROXY) |
    Where-Object { $_ } |
    Select-Object -First 1
  if (-not $proxyValue) {
    return
  }

  try {
    $proxyUri = [Uri]$proxyValue
  }
  catch {
    return
  }

  if ($proxyUri.Host -notin @("127.0.0.1", "localhost", "::1")) {
    return
  }

  $client = New-Object Net.Sockets.TcpClient
  $reachable = $false
  try {
    $reachable = $client.ConnectAsync($proxyUri.Host, $proxyUri.Port).Wait(750) -and $client.Connected
  }
  catch {
    $reachable = $false
  }
  finally {
    $client.Dispose()
  }

  if (-not $reachable) {
    Write-Warning "Ignoring stale loopback proxy $proxyValue for GitHub CLI"
    $env:HTTP_PROXY = $null
    $env:HTTPS_PROXY = $null
  }
}

function Assert-VersionNotLower([string]$Current, [string]$Requested) {
  if ([version]$Requested -lt [version]$Current) {
    throw "Requested version $Requested is lower than current version $Current"
  }
}

function Get-CurrentVersion {
  $readConfig = $script:Config.version.read
  $path = Resolve-RepositoryPath ([string]$readConfig.path)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Version source not found: $path"
  }
  $content = [IO.File]::ReadAllText($path)
  $match = [regex]::Match($content, [string]$readConfig.pattern)
  if (-not $match.Success -or -not $match.Groups["version"].Success) {
    throw "Version pattern not found in $($readConfig.path)"
  }
  $value = $match.Groups["version"].Value
  if ($value -notmatch '^\d+\.\d+\.\d+$') {
    throw "Project version is not a supported semantic version: $value"
  }
  return $value
}

function Get-VersionFilePaths {
  return @(
    @(Get-OptionalProperty $script:Config.version "updates" @()) |
      ForEach-Object { [string]$_.path } |
      Sort-Object -Unique
  )
}

function Backup-VersionFiles {
  $backup = @{}
  foreach ($path in Get-VersionFilePaths) {
    $fullPath = Resolve-RepositoryPath $path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      throw "Version file not found: $path"
    }
    $backup[$path] = [IO.File]::ReadAllBytes($fullPath)
  }
  return $backup
}

function Restore-VersionFiles([hashtable]$Backup) {
  foreach ($entry in $Backup.GetEnumerator()) {
    [IO.File]::WriteAllBytes(
      (Resolve-RepositoryPath ([string]$entry.Key)),
      [byte[]]$entry.Value
    )
  }
}

function Update-VersionFiles {
  foreach ($update in @(Get-OptionalProperty $script:Config.version "updates" @())) {
    $path = Resolve-RepositoryPath ([string]$update.path)
    $content = [IO.File]::ReadAllText($path)
    $regex = [regex]::new([string]$update.pattern)
    $expectedMatches = [int](Get-OptionalProperty $update "expectedMatches" 1)
    $actualMatches = $regex.Matches($content).Count
    if ($actualMatches -ne $expectedMatches) {
      throw "Version pattern in $($update.path) matched $actualMatches times; expected $expectedMatches"
    }
    $replacement = Expand-ConfigTokens ([string]$update.replacement)
    Write-Utf8NoBom $path ($regex.Replace($content, $replacement))
  }
}

function Invoke-ConfiguredCommands {
  $prepare = $script:Config.prepare
  $commands = @(
    @(Get-OptionalProperty $prepare "commands" @()) | ForEach-Object {
      [pscustomobject]@{
        name = Expand-ConfigTokens ([string]$_.name)
        command = Expand-ConfigTokens ([string]$_.command)
      }
    }
  )
  if ($commands.Count -eq 0) {
    return
  }
  if ([bool](Get-OptionalProperty $prepare "parallel" $false)) {
    Invoke-ParallelShellChecked -WorkingDirectory $script:ResolvedRepositoryRoot -Commands $commands
  }
  else {
    Invoke-SequentialShellChecked -WorkingDirectory $script:ResolvedRepositoryRoot -Commands $commands
  }
}

function Get-PreparedArtifacts {
  $results = @()
  foreach ($artifact in @(Get-OptionalProperty $script:Config.prepare "artifacts" @())) {
    $sourceRelative = Expand-ConfigTokens ([string]$artifact.source)
    $source = Resolve-RepositoryPath $sourceRelative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "Built artifact not found: $source"
    }

    $destinationRelative = Get-OptionalProperty $artifact "destination"
    $destination = $source
    if ($destinationRelative) {
      $destination = Resolve-RepositoryPath (Expand-ConfigTokens ([string]$destinationRelative))
      $destinationDirectory = Split-Path -Parent $destination
      New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
      if (-not $source.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
      }
    }

    $file = Get-Item -LiteralPath $destination
    if ([bool](Get-OptionalProperty $artifact "verifyWindowsVersion" $false)) {
      if ($file.VersionInfo.FileVersion -ne $normalizedVersion) {
        throw "FileVersion mismatch for $destination`: $($file.VersionInfo.FileVersion)"
      }
      if ($file.VersionInfo.ProductVersion -ne $normalizedVersion) {
        throw "ProductVersion mismatch for $destination`: $($file.VersionInfo.ProductVersion)"
      }
    }

    $sha256 = $null
    if ([bool](Get-OptionalProperty $artifact "sha256" $true)) {
      $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
    }
    $results += [pscustomobject]@{
      Path = $destination
      Length = $file.Length
      SHA256 = $sha256
    }
  }
  return $results
}

function Find-WorkflowRun($Workflow, [string]$HeadSha) {
  $timeoutSeconds = [int](Get-OptionalProperty $Workflow "findTimeoutSeconds" 120)
  $event = [string](Get-OptionalProperty $Workflow "event" "push")
  $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $json = Invoke-Captured $script:GitHubCli @(
      "run", "list",
      "--workflow", [string]$Workflow.name,
      "--event", $event,
      "--limit", "30",
      "--json", "databaseId,headBranch,headSha,status,url"
    )
    $run = Select-WorkflowRun -Json $json -Tag $script:Tag -HeadSha $HeadSha
    if ($run) {
      return $run
    }
    Start-Sleep -Seconds 5
  }
  throw "Timed out waiting for workflow $($Workflow.name) for $($script:Tag)"
}

function Wait-WorkflowRun($Workflow, [long]$RunId) {
  $waitMinutes = [int](Get-OptionalProperty $Workflow "waitTimeoutMinutes" 90)
  $deadline = [DateTime]::UtcNow.AddMinutes($waitMinutes)
  $previousSignature = $null
  $lastReadError = $null
  $previousReadError = $null

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $json = Invoke-Captured $script:GitHubCli @(
        "run", "view", [string]$RunId,
        "--json", "status,conclusion,url,jobs"
      )
      $run = ConvertFrom-Json -InputObject $json
      $lastReadError = $null
      $previousReadError = $null
    }
    catch {
      $lastReadError = $_.Exception.Message
      if ($lastReadError -ne $previousReadError) {
        Write-Warning "Workflow status read failed; retrying: $lastReadError"
        $previousReadError = $lastReadError
      }
      Start-Sleep -Seconds 10
      continue
    }

    $snapshot = Get-WorkflowRunSnapshot -Run $run
    if (Test-WorkflowSnapshotChanged -PreviousSignature $previousSignature -Snapshot $snapshot) {
      Write-Host $snapshot.Message
      $previousSignature = $snapshot.Signature
    }
    if ($snapshot.State -eq "Failed") {
      throw $snapshot.Message
    }
    if ($snapshot.State -eq "Succeeded") {
      return $run
    }
    Start-Sleep -Seconds 10
  }

  if ($lastReadError) {
    throw "Timed out waiting for workflow $RunId; last read error: $lastReadError"
  }
  throw "Timed out waiting for workflow $RunId"
}

function Assert-ReleaseAssets($RequiredAssets, [object[]]$Assets) {
  $names = @($Assets | ForEach-Object { $_.name })
  foreach ($check in @($RequiredAssets)) {
    $pattern = [string](Get-RequiredProperty $check "pattern" "publish.release.requiredAssets[]")
    $label = [string](Get-OptionalProperty $check "label" $pattern)
    if (-not ($names | Where-Object { $_ -match $pattern })) {
      throw "Release asset missing: $label"
    }
  }
}

function Resolve-UploadAssets($ReleaseConfig) {
  $resolved = @()
  foreach ($configuredPath in @(Get-OptionalProperty $ReleaseConfig "uploadAssets" @())) {
    $relativePattern = Expand-ConfigTokens ([string]$configuredPath)
    if (
      [IO.Path]::IsPathRooted($relativePattern) -or
      $relativePattern -match '(^|[\\/])\.\.([\\/]|$)'
    ) {
      throw "Upload asset pattern must stay inside the repository: $relativePattern"
    }
    $matches = @(Get-ChildItem -Path (Join-Path $script:ResolvedRepositoryRoot $relativePattern) -File)
    if ($matches.Count -eq 0) {
      throw "Upload asset pattern matched no files: $relativePattern"
    }
    foreach ($match in $matches) {
      $resolved += Assert-PathInsideRepository $match.FullName
    }
  }
  return @($resolved | Sort-Object -Unique)
}

function Invoke-ReleasePublication([string]$ReleaseNotes) {
  $releaseConfig = $script:Config.publish.release
  $releaseMode = [string]$releaseConfig.mode
  if ($releaseMode -eq "none") {
    Write-Host "Tag pushed; GitHub Release creation disabled by config"
    return
  }

  $titleTemplate = [string](Get-OptionalProperty $releaseConfig "title" "{projectName} {tag}")
  $title = Expand-ConfigTokens $titleTemplate

  if ($releaseMode -eq "publish-draft") {
    $releaseJson = Invoke-Captured $script:GitHubCli @(
      "release", "view", $script:Tag,
      "--json", "isDraft,url,assets"
    )
    $release = $releaseJson | ConvertFrom-Json
    if (-not $release.isDraft) {
      throw "Release is already public; refusing to edit it"
    }
    Assert-ReleaseAssets `
      (Get-OptionalProperty $releaseConfig "requiredAssets" @()) `
      @($release.assets)

    Invoke-Checked $script:GitHubCli @(
      "release", "edit", $script:Tag,
      "--title", $title,
      "--notes", $ReleaseNotes,
      "--draft=false"
    )
    Write-Host "Release published: $($release.url)"
    return
  }

  $uploadAssets = Resolve-UploadAssets $releaseConfig
  $arguments = @("release", "create", $script:Tag)
  $arguments += $uploadAssets
  $arguments += @("--title", $title, "--notes", $ReleaseNotes)
  Invoke-Checked $script:GitHubCli $arguments

  $releaseJson = Invoke-Captured $script:GitHubCli @(
    "release", "view", $script:Tag,
    "--json", "url,assets"
  )
  $release = $releaseJson | ConvertFrom-Json
  Assert-ReleaseAssets `
    (Get-OptionalProperty $releaseConfig "requiredAssets" @()) `
    @($release.assets)
  Write-Host "Release published: $($release.url)"
}

function Invoke-Plan {
  Assert-Repository
  $currentVersion = Get-CurrentVersion
  Assert-VersionNotLower $currentVersion $normalizedVersion
  $releaseMode = [string]$script:Config.publish.release.mode

  @(
    "Project: $($script:Config.projectName)",
    "Repository: $($script:ResolvedRepositoryRoot)",
    "Config: $($script:ConfigFile)",
    "Current version: $currentVersion",
    "Target version: $normalizedVersion",
    "Tag: $($script:Tag)",
    "Branch push: $($script:Config.remote)/$($script:Config.branch)",
    "Prepare parallel: $([bool](Get-OptionalProperty $script:Config.prepare 'parallel' $false))"
  )
  foreach ($command in @(Get-OptionalProperty $script:Config.prepare "commands" @())) {
    "Prepare command: $(Expand-ConfigTokens ([string]$command.name)) -> $(Expand-ConfigTokens ([string]$command.command))"
  }
  foreach ($artifact in @(Get-OptionalProperty $script:Config.prepare "artifacts" @())) {
    $source = Expand-ConfigTokens ([string]$artifact.source)
    $destination = Expand-ConfigTokens ([string](Get-OptionalProperty $artifact "destination" $artifact.source))
    "Artifact: $source -> $destination"
  }
  $workflow = Get-OptionalProperty $script:Config.publish "workflow"
  if ($workflow) {
    "Workflow: $($workflow.name) via gh run view --json"
  }
  "Release mode: $releaseMode"
  "Push: git push --atomic $($script:Config.remote) $($script:Config.branch) $($script:Tag)"
}

function Invoke-Prepare {
  Assert-Repository
  Update-RemoteBranch
  Assert-RemoteIsAncestor
  Assert-LocalTagAbsent $script:Tag
  Assert-RemoteTagAbsent $script:Tag

  $currentVersion = Get-CurrentVersion
  Assert-VersionNotLower $currentVersion $normalizedVersion
  $backup = Backup-VersionFiles

  try {
    if ([version]$normalizedVersion -gt [version]$currentVersion) {
      Update-VersionFiles
    }
    if ((Get-CurrentVersion) -ne $normalizedVersion) {
      throw "Project version does not match requested version after update"
    }

    $artifacts = @()
    if ($SkipBuild) {
      Write-Host "Local build is current; skipping configured build commands"
    }
    else {
      Invoke-ConfiguredCommands
      $artifacts = @(Get-PreparedArtifacts)
    }
    Write-Host "Prepared $($script:Config.projectName) $($script:Tag)"
    if ($artifacts.Count -gt 0) {
      $artifacts | Format-List
    }
  }
  catch {
    Restore-VersionFiles $backup
    throw
  }
}

function Invoke-LocalBuild {
  Assert-RepositoryRoot
  $currentVersion = Get-CurrentVersion
  Write-Host "Local build: $($script:Config.projectName) $currentVersion"
  Invoke-ConfiguredCommands
  $artifacts = @(Get-PreparedArtifacts)
  Write-Host "Local build completed without changing the project version"
  if ($artifacts.Count -gt 0) {
    $artifacts | Format-List
  }
}

function Invoke-Publish {
  Assert-Repository
  $releaseConfig = $script:Config.publish.release
  $releaseMode = [string]$releaseConfig.mode
  if ($releaseMode -ne "none") {
    $notesConfig = Get-OptionalProperty $script:Config "releaseNotes"
    $defaultHeading =
      "## " +
      ([char]0x66F4).ToString() +
      ([char]0x65B0).ToString() +
      ([char]0x5185).ToString() +
      ([char]0x5BB9).ToString()
    $heading = [string](Get-OptionalProperty $notesConfig "heading" $defaultHeading)
    $minItems = [int](Get-OptionalProperty $notesConfig "minItems" 2)
    $maxItems = [int](Get-OptionalProperty $notesConfig "maxItems" 6)
    $requireChinese = [bool](Get-OptionalProperty $notesConfig "requireChinese" $false)
    Assert-ReleaseNotes `
      -ReleaseNotes $ReleaseNotes `
      -Heading $heading `
      -MinItems $minItems `
      -MaxItems $maxItems `
      -RequireChinese $requireChinese
  }

  Update-RemoteBranch
  Assert-RemoteIsAncestor
  Assert-LocalTagAbsent $script:Tag
  Assert-RemoteTagAbsent $script:Tag

  $currentVersion = Get-CurrentVersion
  if ($currentVersion -ne $normalizedVersion) {
    throw "Project version $currentVersion does not match requested version $normalizedVersion"
  }

  $status = Invoke-Captured "git" @("status", "--porcelain")
  if ($status) {
    throw "Working tree must be clean before Publish"
  }

  $headSubject = Invoke-Captured "git" @("log", "-1", "--pretty=%s")
  if (-not $AllowExistingHead -and $headSubject -ne $Summary) {
    throw "HEAD subject does not match the release summary"
  }

  $workflow = Get-OptionalProperty $script:Config.publish "workflow"
  $needsGitHub = $workflow -or $releaseMode -ne "none"
  if ($needsGitHub) {
    Disable-StaleLoopbackProxy
    Assert-GitHubAuth
  }

  $headSha = Invoke-Captured "git" @("rev-parse", "HEAD")
  Invoke-Checked "git" @("tag", "-a", $script:Tag, "-m", $Summary)

  try {
    Invoke-Checked "git" @(
      "push",
      "--atomic",
      [string]$script:Config.remote,
      [string]$script:Config.branch,
      $script:Tag
    )
  }
  catch {
    $remoteTag = ""
    try {
      $remoteTag = Get-RemoteTag $script:Tag
    }
    catch {
      Write-Warning "Could not verify remote tag state after push failure"
    }
    if (-not $remoteTag) {
      & git tag -d $script:Tag | Out-Null
    }
    throw
  }

  if ($workflow) {
    $run = Find-WorkflowRun -Workflow $workflow -HeadSha $headSha
    Write-Host "Workflow: $($run.url)"
    Wait-WorkflowRun -Workflow $workflow -RunId ([long]$run.databaseId) | Out-Null
  }

  Invoke-ReleasePublication -ReleaseNotes $ReleaseNotes
}

$previousLocation = Get-Location
try {
  Initialize-ReleaseContext
  Set-Location -LiteralPath $script:ResolvedRepositoryRoot
  if ($Mode -eq "LocalBuild") {
    Invoke-LocalBuild
  }
  elseif ($Mode -eq "Plan") {
    Invoke-Plan
  }
  elseif ($Mode -eq "Prepare") {
    Invoke-Prepare
  }
  else {
    Invoke-Publish
  }
}
finally {
  Set-Location -LiteralPath $previousLocation
}
