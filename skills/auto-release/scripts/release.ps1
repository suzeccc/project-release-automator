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

  [switch]$AllowExistingHead,

  [string]$ArtifactManifestPath,

  [string[]]$ManagedLocalArtifactPath = @(),

  [switch]$CanonicalLocalOutput
)

$ErrorActionPreference = "Stop"
$normalizedVersion = if ($Version) { $Version.TrimStart("v") } else { $null }
$script:GitHubCli = $null
$script:Config = $null
$script:ResolvedRepositoryRoot = $null
$script:ConfigFile = $null
$script:Tag = $null
$script:CommitStyleAnalysis = $null
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
if ($ArtifactManifestPath -and $Mode -notin @("LocalBuild", "Prepare")) {
  throw "ArtifactManifestPath is only valid for LocalBuild or Prepare"
}
if ($ManagedLocalArtifactPath.Count -gt 0 -and $Mode -ne "LocalBuild") {
  throw "ManagedLocalArtifactPath is only valid for LocalBuild"
}
if ($CanonicalLocalOutput -and $Mode -ne "Prepare") {
  throw "CanonicalLocalOutput is only valid for Prepare"
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
    $script:normalizedVersion = Get-CurrentVersion
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

  $commitConfig = Get-OptionalProperty $script:Config "commit"
  if ($commitConfig) {
    $commitPolicy = [string](Get-OptionalProperty $commitConfig "policy" "auto")
    if ($commitPolicy -notin @("auto", "conventional", "off")) {
      throw "commit.policy must be auto, conventional, or off"
    }
    $analyzeCount = [int](Get-OptionalProperty $commitConfig "analyzeCount" 30)
    $minimumSamples = [int](Get-OptionalProperty $commitConfig "minimumSamples" 3)
    $confidenceThreshold = [double](Get-OptionalProperty $commitConfig "confidenceThreshold" 0.6)
    $fallback = [string](Get-OptionalProperty $commitConfig "fallback" "conventional")
    if ($analyzeCount -lt 1) { throw "commit.analyzeCount must be positive" }
    if ($minimumSamples -lt 1 -or $minimumSamples -gt $analyzeCount) {
      throw "commit.minimumSamples must be positive and not exceed commit.analyzeCount"
    }
    if ($confidenceThreshold -le 0 -or $confidenceThreshold -gt 1) {
      throw "commit.confidenceThreshold must be greater than 0 and at most 1"
    }
    if ($fallback -ne "conventional") { throw "commit.fallback must be conventional" }
  }

  $prepare = Get-RequiredProperty $script:Config "prepare" "root"
  $localOutputDirectory = [string](Get-OptionalProperty $prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($localOutputDirectory) -or $localOutputDirectory -match '\{(?:version|tag)\}') {
    throw "prepare.localOutputDirectory must be a stable path without version or tag tokens"
  }
  Resolve-RepositoryPath $localOutputDirectory | Out-Null
  foreach ($commandProperty in @("bootstrapCommands", "localCommands", "commands")) {
    foreach ($command in @(Get-OptionalProperty $prepare $commandProperty @())) {
      Get-RequiredProperty $command "name" "prepare.$commandProperty[]" | Out-Null
      Get-RequiredProperty $command "command" "prepare.$commandProperty[]" | Out-Null
    }
  }
  foreach ($inputPath in @(Get-OptionalProperty $prepare "bootstrapInputs" @())) {
    if ([string]::IsNullOrWhiteSpace([string]$inputPath)) {
      throw "prepare.bootstrapInputs[] must be a repository-relative path"
    }
    Resolve-RepositoryPath ([string]$inputPath) | Out-Null
  }
  foreach ($requiredPath in @(Get-OptionalProperty $prepare "bootstrapRequiredPaths" @())) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredPath)) {
      throw "prepare.bootstrapRequiredPaths[] must be a repository-relative path"
    }
    Resolve-RepositoryPath ([string]$requiredPath) | Out-Null
  }
  foreach ($artifactProperty in @("localArtifacts", "artifacts")) {
    foreach ($artifact in @(Get-OptionalProperty $prepare $artifactProperty @())) {
      Get-RequiredProperty $artifact "source" "prepare.$artifactProperty[]" | Out-Null
    }
  }
  foreach ($searchRoot in @(Get-OptionalProperty $prepare "localSearchRoots" @())) {
    if ([string]::IsNullOrWhiteSpace([string]$searchRoot)) {
      throw "prepare.localSearchRoots[] must be a repository-relative path"
    }
    Resolve-RepositoryPath ([string]$searchRoot) | Out-Null
  }

  $publish = Get-RequiredProperty $script:Config "publish" "root"
  $release = Get-RequiredProperty $publish "release" "publish"
  $releaseMode = [string](Get-RequiredProperty $release "mode" "publish.release")
  if ($releaseMode -notin @("publish-draft", "create", "none")) {
    throw "publish.release.mode must be publish-draft, create, or none"
  }
}

function Assert-ConfiguredCommitSummary {
  $commitConfig = Get-OptionalProperty $script:Config "commit"
  $script:CommitStyleAnalysis = Get-RepositoryCommitStyleAnalysis `
    -RepositoryRoot $script:ResolvedRepositoryRoot `
    -CommitConfig $commitConfig
  Assert-CommitSummaryStyle -Summary $Summary -Analysis $script:CommitStyleAnalysis
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

function Get-GitDirectory {
  $path = Invoke-Captured "git" @("rev-parse", "--git-dir")
  if (-not [IO.Path]::IsPathRooted($path)) {
    $path = Join-Path $script:ResolvedRepositoryRoot $path
  }
  return Get-NormalizedPath $path
}

function Get-BootstrapFingerprint {
  $prepare = $script:Config.prepare
  $entries = @()
  foreach ($command in @(Get-OptionalProperty $prepare "bootstrapCommands" @())) {
    $commandText = [string]$command.command
    $entries += "command:$([string]$command.name):$commandText"
    $toolMatch = [regex]::Match($commandText, '^\s*(?:"(?<quoted>[^"]+)"|(?<bare>[^\s&]+))')
    $toolName = if ($toolMatch.Groups["quoted"].Success) { $toolMatch.Groups["quoted"].Value } else { $toolMatch.Groups["bare"].Value }
    $tool = if ($toolName) { Get-Command $toolName -ErrorAction SilentlyContinue } else { $null }
    if ($tool) {
      $toolPath = [string]$tool.Source
      $toolVersion = if ($toolPath -and (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        [string](Get-Item -LiteralPath $toolPath).VersionInfo.FileVersion
      }
      else { "" }
      $entries += "tool:$toolName`:$toolPath`:$toolVersion"
    }
    else {
      $entries += "tool:$toolName`:missing"
    }
  }
  $versionPatterns = @{}
  $readPath = ([string]$script:Config.version.read.path).Replace("\", "/")
  $versionPatterns[$readPath] = @([string]$script:Config.version.read.pattern)
  foreach ($update in @(Get-OptionalProperty $script:Config.version "updates" @())) {
    $updatePath = ([string]$update.path).Replace("\", "/")
    if (-not $versionPatterns.ContainsKey($updatePath)) { $versionPatterns[$updatePath] = @() }
    $versionPatterns[$updatePath] += [string]$update.pattern
  }
  foreach ($relativePath in @(Get-OptionalProperty $prepare "bootstrapInputs" @()) | Sort-Object -Unique) {
    $path = Resolve-RepositoryPath ([string]$relativePath)
    $hash = if (Test-Path -LiteralPath $path -PathType Leaf) {
      $normalizedRelative = ([string]$relativePath).Replace("\", "/")
      if ($versionPatterns.ContainsKey($normalizedRelative)) {
        $content = [IO.File]::ReadAllText($path)
        foreach ($pattern in @($versionPatterns[$normalizedRelative])) {
          $regex = [regex]::new($pattern)
          $content = $regex.Replace($content, {
            param($match)
            return ([regex]::new('\d+\.\d+\.\d+')).Replace($match.Value, '<release-version>', 1)
          })
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
        finally { $sha.Dispose() }
      }
      else {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
      }
    }
    else {
      "missing"
    }
    $entries += "input:$(([string]$relativePath).Replace('\', '/')):$hash"
  }
  $payload = [Text.UTF8Encoding]::new($false).GetBytes(($entries -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Invoke-CommandList($Commands, [bool]$Parallel) {
  $expanded = @(
    @($Commands) | ForEach-Object {
      [pscustomobject]@{
        name = Expand-ConfigTokens ([string]$_.name)
        command = Expand-ConfigTokens ([string]$_.command)
      }
    }
  )
  if ($expanded.Count -eq 0) { return }
  if ($Parallel) {
    Invoke-ParallelShellChecked -WorkingDirectory $script:ResolvedRepositoryRoot -Commands $expanded
  }
  else {
    Invoke-SequentialShellChecked -WorkingDirectory $script:ResolvedRepositoryRoot -Commands $expanded
  }
}

function Invoke-BootstrapCommands {
  $prepare = $script:Config.prepare
  $commands = @(Get-OptionalProperty $prepare "bootstrapCommands" @())
  if ($commands.Count -eq 0) { return }

  $fingerprint = Get-BootstrapFingerprint
  $stateDirectory = Join-Path (Get-GitDirectory) "auto-release"
  $statePath = Join-Path $stateDirectory "bootstrap.json"
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json }
    catch { $state = $null }
    $requiredPathsExist = @(
      @(Get-OptionalProperty $prepare "bootstrapRequiredPaths" @()) | Where-Object {
        -not (Test-Path -LiteralPath (Resolve-RepositoryPath ([string]$_)))
      }
    ).Count -eq 0
    if ($state -and [string]$state.fingerprint -eq $fingerprint -and $requiredPathsExist) {
      Write-Host "Dependency bootstrap is current; skipping installation"
      return
    }
  }

  Invoke-CommandList $commands $false
  New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
  $state = [pscustomobject][ordered]@{
    schemaVersion = 1
    fingerprint = $fingerprint
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
  }
  Write-Utf8NoBom $statePath (($state | ConvertTo-Json -Depth 5) + "`n")
}

function Invoke-ConfiguredCommands([bool]$LocalBuild = $false) {
  $prepare = $script:Config.prepare
  Invoke-BootstrapCommands
  $commands = if ($LocalBuild -and $null -ne $prepare.PSObject.Properties["localCommands"]) {
    @(Get-OptionalProperty $prepare "localCommands" @())
  }
  else {
    @(Get-OptionalProperty $prepare "commands" @())
  }
  Invoke-CommandList $commands ([bool](Get-OptionalProperty $prepare "parallel" $false))
}

function ConvertTo-LocalOutputStem {
  $name = [string]$script:Config.projectName
  foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
    $name = $name.Replace([string]$character, "-")
  }
  $name = $name.Trim().TrimEnd(".")
  if ([string]::IsNullOrWhiteSpace($name)) { return "app" }
  return $name
}

function Get-LocalArtifactExtension([IO.FileInfo]$File) {
  $lowerName = $File.Name.ToLowerInvariant()
  foreach ($extension in @(".tar.gz", ".appimage", ".nupkg", ".crate", ".whl", ".tgz", ".aab", ".apk", ".msi", ".dmg", ".deb", ".rpm", ".jar", ".zip", ".exe")) {
    if ($lowerName.EndsWith($extension, [StringComparison]::Ordinal)) { return $extension }
  }
  return $File.Extension.ToLowerInvariant()
}

function ConvertTo-RepositoryRelativePath([string]$Path) {
  $fullPath = Get-NormalizedPath $Path
  $prefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Artifact is outside the repository: $Path"
  }
  return $fullPath.Substring($prefix.Length).Replace("\", "/")
}

function Get-PreferredLocalFile($Files) {
  $candidates = @($Files | Where-Object { $_ -and $_.Exists })
  if ($candidates.Count -eq 0) { return $null }
  $stem = ConvertTo-LocalOutputStem
  $sorted = @($candidates | Sort-Object @{ Expression = {
    if ($_.BaseName.Equals($stem, [StringComparison]::OrdinalIgnoreCase)) { 0 }
    elseif ($_.BaseName.IndexOf($stem, [StringComparison]::OrdinalIgnoreCase) -ge 0) { 1 }
    else { 2 }
  } }, @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true })
  return $sorted[0]
}

function Get-DiscoveredLocalArtifactFiles {
  $type = [string](Get-OptionalProperty $script:Config "projectType" "")
  $files = @()
  if ($type -eq "tauri") {
    $root = Resolve-RepositoryPath "src-tauri/target/release"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.exe")
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "node") {
    $root = Resolve-RepositoryPath "dist"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.tgz")
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "go") {
    $root = Resolve-RepositoryPath "dist"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.exe")
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "python") {
    $root = Resolve-RepositoryPath "dist"
    if (Test-Path -LiteralPath $root -PathType Container) {
      foreach ($filter in @("*.whl", "*.tar.gz")) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter $filter)
        if ($preferred) { $files += $preferred }
      }
    }
  }
  elseif ($type -eq "rust") {
    $releaseRoot = Resolve-RepositoryPath "target/release"
    if (Test-Path -LiteralPath $releaseRoot -PathType Container) {
      $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $releaseRoot -File -Filter "*.exe")
      if (-not $preferred) {
        $depsRoot = Join-Path $releaseRoot "deps"
        if (Test-Path -LiteralPath $depsRoot -PathType Container) {
          $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $depsRoot -File -Filter "*.rlib")
        }
      }
      if ($preferred) { $files += $preferred }
    }
    if ($files.Count -eq 0) {
      $root = Resolve-RepositoryPath "target/package"
      if (Test-Path -LiteralPath $root -PathType Container) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.crate")
        if ($preferred) { $files += $preferred }
      }
    }
  }
  elseif ($type -eq "dotnet") {
    $searchRoots = @(Get-OptionalProperty $script:Config.prepare "localSearchRoots" @("bin/Release"))
    foreach ($relativeRoot in $searchRoots) {
      $binRoot = Resolve-RepositoryPath ([string]$relativeRoot)
      if (Test-Path -LiteralPath $binRoot -PathType Container) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $binRoot -Recurse -File -Filter "*.exe")
        if (-not $preferred) {
          $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $binRoot -Recurse -File -Filter "*.dll" | Where-Object {
            $_.FullName -notmatch '[\\/](?:ref|runtimes)[\\/]'
          })
        }
        if ($preferred) { $files += $preferred; break }
      }
    }
    if ($files.Count -eq 0) {
      $root = Resolve-RepositoryPath "dist"
      if (Test-Path -LiteralPath $root -PathType Container) {
        $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -File -Filter "*.nupkg")
        if ($preferred) { $files += $preferred }
      }
    }
  }
  elseif ($type -eq "java") {
    $candidates = @()
    foreach ($relativeRoot in @("target", "build/libs")) {
      $root = Resolve-RepositoryPath $relativeRoot
      if (Test-Path -LiteralPath $root -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $root -File -Filter "*.jar" | Where-Object {
          $_.Name -notmatch '(?i)(?:-sources|-javadoc|-tests)\.jar$' -and $_.Name -notmatch '(?i)^original-'
        })
      }
    }
    $preferred = Get-PreferredLocalFile $candidates
    if ($preferred) { $files += $preferred }
  }
  elseif ($type -eq "cmake") {
    $root = Resolve-RepositoryPath "build"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $candidates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.exe" | Where-Object {
        $_.FullName -notmatch '[\\/]CMakeFiles[\\/]'
      })
      $preferred = Get-PreferredLocalFile $candidates
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "flutter") {
    $root = Resolve-RepositoryPath "build/windows"
    if (Test-Path -LiteralPath $root -PathType Container) {
      $candidates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.exe" | Where-Object {
        $_.FullName -match '[\\/]runner[\\/]Release[\\/]'
      })
      $preferred = Get-PreferredLocalFile $candidates
      if ($preferred) { $files += $preferred }
    }
  }
  elseif ($type -eq "android") {
    $candidates = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $script:ResolvedRepositoryRoot -Directory)) {
      $root = Join-Path $directory.FullName "build\outputs"
      if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($extension in @("*.apk", "*.aab")) {
          $preferred = Get-PreferredLocalFile @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $extension)
          if ($preferred) { $candidates += $preferred }
        }
      }
    }
    $files += $candidates
  }
  elseif ($type -eq "electron") {
    $candidates = @()
    $searchRoots = @(Get-OptionalProperty $script:Config.prepare "localSearchRoots" @("dist", "out", "release"))
    foreach ($relativeRoot in $searchRoots) {
      $root = Resolve-RepositoryPath $relativeRoot
      if (Test-Path -LiteralPath $root -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.exe" | Where-Object {
          $_.Name -notmatch '(?i)uninstall'
        })
      }
    }
    $preferred = Get-PreferredLocalFile $candidates
    if ($preferred) { $files += $preferred }
  }
  return @($files | Sort-Object FullName -Unique)
}

function Stop-ProcessesUsingLocalArtifacts([string[]]$Paths) {
  if ($env:OS -ne "Windows_NT") { return }
  $targets = @{}
  foreach ($path in @($Paths | Where-Object { $_ })) {
    if ([IO.Path]::GetExtension($path) -ne ".exe") { continue }
    $targets[(Get-NormalizedPath $path).ToLowerInvariant()] = $true
  }
  if ($targets.Count -eq 0) { return }

  $stopped = @()
  foreach ($process in @(Get-Process)) {
    if ($process.Id -eq $PID) { continue }
    try { $processPath = [string]$process.Path }
    catch { continue }
    if (-not $processPath) { continue }
    $normalizedProcessPath = (Get-NormalizedPath $processPath).ToLowerInvariant()
    if (-not $targets.ContainsKey($normalizedProcessPath)) { continue }

    Write-Host "Stopping process $($process.ProcessName) ($($process.Id)) using local artifact: $processPath"
    try {
      Stop-Process -Id $process.Id -Force -ErrorAction Stop
      $stopped += [pscustomobject]@{ Id = $process.Id; Path = $processPath }
    }
    catch {
      if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) { throw }
    }
  }

  foreach ($entry in $stopped) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (Get-Process -Id $entry.Id -ErrorAction SilentlyContinue) {
      if ([DateTime]::UtcNow -ge $deadline) {
        throw "Timed out stopping process $($entry.Id) using local artifact: $($entry.Path)"
      }
      Start-Sleep -Milliseconds 100
    }
  }
}

function Get-LocalBuildExecutablePaths {
  $paths = @()
  $prepare = $script:Config.prepare
  $artifactDefinitions = if ($null -ne $prepare.PSObject.Properties["localArtifacts"]) {
    @(Get-OptionalProperty $prepare "localArtifacts" @())
  }
  else {
    @(Get-OptionalProperty $prepare "artifacts" @())
  }
  $usedLocalNames = @{}
  foreach ($artifact in $artifactDefinitions) {
    $sourceRelative = Expand-ConfigTokens ([string]$artifact.source)
    $source = Resolve-RepositoryPath $sourceRelative
    $destination = Get-LocalArtifactDestination ([IO.FileInfo]::new($source)) $artifact $usedLocalNames
    if ([IO.Path]::GetExtension($source) -eq ".exe") { $paths += $source }
    if ([IO.Path]::GetExtension($destination) -eq ".exe") { $paths += $destination }
  }
  if ($artifactDefinitions.Count -eq 0) {
    foreach ($file in @(Get-DiscoveredLocalArtifactFiles)) {
      $destination = Get-LocalArtifactDestination $file ([pscustomobject]@{}) $usedLocalNames
      if ($file.Extension -eq ".exe") { $paths += $file.FullName }
      if ([IO.Path]::GetExtension($destination) -eq ".exe") { $paths += $destination }
    }
  }
  foreach ($relativePath in @($ManagedLocalArtifactPath)) {
    $path = Resolve-RepositoryPath $relativePath
    if ([IO.Path]::GetExtension($path) -eq ".exe") { $paths += $path }
  }
  return @($paths | Sort-Object -Unique)
}

function Stop-LocalBuildProcesses {
  Stop-ProcessesUsingLocalArtifacts @(Get-LocalBuildExecutablePaths)
}

function Get-LocalArtifactDestination([IO.FileInfo]$Source, $Artifact, [hashtable]$UsedNames) {
  $prepare = $script:Config.prepare
  $outputRelative = [string](Get-OptionalProperty $prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($outputRelative)) { $outputRelative = "output" }
  $outputDirectory = Resolve-RepositoryPath $outputRelative
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

  $extension = Get-LocalArtifactExtension $Source
  $localName = [string](Get-OptionalProperty $Artifact "localName" "")
  if ($localName) {
    if ([IO.Path]::GetFileName($localName) -ne $localName) {
      throw "prepare.artifacts[].localName must be a file name: $localName"
    }
  }
  else {
    $localName = "$(ConvertTo-LocalOutputStem)$extension"
  }

  $nameExtension = [IO.Path]::GetExtension($localName)
  if ($localName.EndsWith(".tar.gz", [StringComparison]::OrdinalIgnoreCase)) {
    $nameExtension = ".tar.gz"
  }
  $baseName = $localName.Substring(0, $localName.Length - $nameExtension.Length)
  $candidate = $localName
  $count = 1
  while ($UsedNames.ContainsKey($candidate.ToLowerInvariant())) {
    $count += 1
    $candidate = "$baseName-$count$nameExtension"
  }
  $localName = $candidate
  $UsedNames[$localName.ToLowerInvariant()] = $true
  return Join-Path $outputDirectory $localName
}

function Get-PreparedArtifacts([bool]$LocalBuild = $false) {
  $results = @()
  $artifactDefinitions = if ($LocalBuild -and $null -ne $script:Config.prepare.PSObject.Properties["localArtifacts"]) {
    @(Get-OptionalProperty $script:Config.prepare "localArtifacts" @())
  }
  else {
    @(Get-OptionalProperty $script:Config.prepare "artifacts" @())
  }
  if ($LocalBuild -and $artifactDefinitions.Count -eq 0) {
    foreach ($file in @(Get-DiscoveredLocalArtifactFiles)) {
      $artifactDefinitions += [pscustomobject][ordered]@{
        source = ConvertTo-RepositoryRelativePath $file.FullName
        sha256 = $true
      }
    }
  }
  if ($LocalBuild -and $artifactDefinitions.Count -eq 0) {
    Write-Warning "Build completed, but no file-based local artifact could be discovered"
    return @()
  }

  $usedLocalNames = @{}
  foreach ($artifact in $artifactDefinitions) {
    $sourceRelative = Expand-ConfigTokens ([string]$artifact.source)
    $source = Resolve-RepositoryPath $sourceRelative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "Built artifact not found: $source"
    }

    $destination = $source
    if ($LocalBuild) {
      $destination = Get-LocalArtifactDestination (Get-Item -LiteralPath $source) $artifact $usedLocalNames
    }
    else {
      $destinationRelative = Get-OptionalProperty $artifact "destination"
      if ($destinationRelative) {
        $destination = Resolve-RepositoryPath (Expand-ConfigTokens ([string]$destinationRelative))
      }
    }
    if (-not $source.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
      if ($LocalBuild) {
        Stop-ProcessesUsingLocalArtifacts @($destination)
      }
      $destinationDirectory = Split-Path -Parent $destination
      New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
      Copy-Item -LiteralPath $source -Destination $destination -Force
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

function Write-ArtifactManifest($Artifacts) {
  if (-not $ArtifactManifestPath) { return }
  $path = if ([IO.Path]::IsPathRooted($ArtifactManifestPath)) {
    Get-NormalizedPath $ArtifactManifestPath
  }
  else {
    Get-NormalizedPath (Join-Path $script:ResolvedRepositoryRoot $ArtifactManifestPath)
  }
  $gitDirectory = Get-GitDirectory
  $gitPrefix = $gitDirectory + [IO.Path]::DirectorySeparatorChar
  if (-not $path.StartsWith($gitPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Artifact manifest must be stored inside the Git directory"
  }
  $directory = Split-Path -Parent $path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $records = @(
    @($Artifacts) | ForEach-Object {
      [pscustomobject][ordered]@{
        path = ConvertTo-RepositoryRelativePath ([string]$_.Path)
        sha256 = if ($_.SHA256) { [string]$_.SHA256 } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.Path).Hash }
        length = [long]$_.Length
      }
    }
  )
  $manifest = [pscustomobject][ordered]@{
    schemaVersion = 1
    artifacts = $records
  }
  Write-Utf8NoBom $path (($manifest | ConvertTo-Json -Depth 10) + "`n")
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
    "Commit style: $($script:CommitStyleAnalysis.selectedStyle) ($($script:CommitStyleAnalysis.reason))",
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
      if ($CanonicalLocalOutput) { Stop-LocalBuildProcesses }
      Invoke-ConfiguredCommands
      $artifacts = @(Get-PreparedArtifacts ([bool]$CanonicalLocalOutput))
      Write-ArtifactManifest $artifacts
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
  Stop-LocalBuildProcesses
  Invoke-ConfiguredCommands $true
  $artifacts = @(Get-PreparedArtifacts $true)
  Write-ArtifactManifest $artifacts
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
  if ($Mode -in @("Plan", "Publish")) {
    Assert-ConfiguredCommitSummary
  }
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
