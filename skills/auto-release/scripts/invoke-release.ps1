[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("LocalBuild", "CommitPush", "Release")]
  [string]$Operation,

  [ValidatePattern('^v?\d+\.\d+\.\d+$')]
  [string]$Version,

  [string]$Summary,

  [string]$ReleaseNotes,

  [string]$RepositoryRoot = (Get-Location).Path,

  [string]$ConfigPath = ".codex-release.json",

  [ValidateSet("auto", "tauri", "node", "go", "python", "rust", "dotnet", "java", "cmake", "flutter", "android", "electron", "docker")]
  [string]$ProjectType = "auto",

  [ValidateSet("Stop", "CreateSeparate", "ReuseCompatible")]
  [string]$WorkflowPolicy = "Stop",

  [string]$WorkflowPath = ".github/workflows/release.yml",

  [string]$SeparateWorkflowPath = ".github/workflows/auto-release.yml"
)

$ErrorActionPreference = "Stop"
$script:ResolvedRepositoryRoot = $null
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$setupScript = Join-Path $PSScriptRoot "setup-project.ps1"
$releaseScript = Join-Path $PSScriptRoot "release.ps1"

function Get-OptionalProperty($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Default }
  return $property.Value
}

function Get-NormalizedPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
}

function Invoke-GitCaptured([string[]]$Arguments) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & git -C $script:ResolvedRepositoryRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  $standardOutput = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
  return (($standardOutput | Out-String).Trim())
}

function Invoke-GitChecked([string[]]$Arguments) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & git -C $script:ResolvedRepositoryRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  foreach ($line in @($output)) { Write-Host $line }
}

function Assert-ChineseSummary([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { throw "A Chinese summary is required" }
  if ($Value -match "[`r`n]") { throw "Summary must be one line" }
  if ($Value -notmatch '[\u4e00-\u9fff]') { throw "Summary must contain Chinese text" }
}

function Assert-RepositoryContext {
  if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root not found: $RepositoryRoot"
  }
  $script:ResolvedRepositoryRoot = Get-NormalizedPath (Resolve-Path -LiteralPath $RepositoryRoot).Path
  $gitRoot = Get-NormalizedPath (Invoke-GitCaptured @("rev-parse", "--show-toplevel"))
  if (-not $gitRoot.Equals($script:ResolvedRepositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository root mismatch: $gitRoot"
  }
}

function Resolve-RepositoryPath([string]$RelativePath) {
  if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Path must be repository-relative: $RelativePath" }
  $fullPath = Get-NormalizedPath (Join-Path $script:ResolvedRepositoryRoot $RelativePath)
  $prefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path escapes repository root: $RelativePath"
  }
  return $fullPath
}

function Read-ReleaseConfig {
  $path = Resolve-RepositoryPath $ConfigPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { throw "Release config is invalid JSON: $path" }
}

function Disable-StaleLoopbackProxy {
  $proxyValue = @($env:HTTPS_PROXY, $env:HTTP_PROXY, $env:ALL_PROXY) | Where-Object { $_ } | Select-Object -First 1
  if (-not $proxyValue) { return }
  try { $proxyUri = [Uri]$proxyValue } catch { return }
  if ($proxyUri.Host -notin @("127.0.0.1", "localhost", "::1")) { return }
  $client = New-Object Net.Sockets.TcpClient
  try { $reachable = $client.ConnectAsync($proxyUri.Host, $proxyUri.Port).Wait(750) -and $client.Connected }
  catch { $reachable = $false }
  finally { $client.Dispose() }
  if (-not $reachable) {
    Write-Warning "Ignoring stale loopback proxy $proxyValue"
    $env:HTTP_PROXY = $null
    $env:HTTPS_PROXY = $null
    $env:ALL_PROXY = $null
  }
}

function Get-BranchAndRemote($Config) {
  $branch = if ($Config) { [string]$Config.branch } else { Invoke-GitCaptured @("branch", "--show-current") }
  if (-not $branch) { throw "Detached HEAD is not supported" }
  $remote = if ($Config) { [string]$Config.remote } else { "origin" }
  if (-not $remote) { $remote = "origin" }
  return [pscustomobject]@{ Branch = $branch; Remote = $remote }
}

function Assert-RemoteReady($Config) {
  $target = Get-BranchAndRemote $Config
  Invoke-GitCaptured @("remote", "get-url", $target.Remote) | Out-Null
  Disable-StaleLoopbackProxy
  $remoteHead = Invoke-GitCaptured @("ls-remote", "--heads", $target.Remote, "refs/heads/$($target.Branch)")
  if ($remoteHead) {
    Invoke-GitChecked @(
      "fetch", "--no-tags", $target.Remote,
      "refs/heads/$($target.Branch):refs/remotes/$($target.Remote)/$($target.Branch)"
    )
    & git -C $script:ResolvedRepositoryRoot merge-base --is-ancestor "$($target.Remote)/$($target.Branch)" HEAD
    if ($LASTEXITCODE -ne 0) {
      throw "$($target.Remote)/$($target.Branch) is ahead or diverged; operation stopped"
    }
  }
  return [pscustomobject]@{ Branch = $target.Branch; Remote = $target.Remote; Exists = [bool]$remoteHead }
}

function Get-GitDirectory {
  $gitDirectory = Invoke-GitCaptured @("rev-parse", "--git-dir")
  if (-not [IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $script:ResolvedRepositoryRoot $gitDirectory }
  return Get-NormalizedPath $gitDirectory
}

function Backup-GitIndex {
  $indexPath = Join-Path (Get-GitDirectory) "index"
  return [pscustomobject]@{
    Path = $indexPath
    Exists = Test-Path -LiteralPath $indexPath -PathType Leaf
    Bytes = if (Test-Path -LiteralPath $indexPath -PathType Leaf) { [IO.File]::ReadAllBytes($indexPath) } else { $null }
  }
}

function Restore-GitIndex($Backup) {
  if ($Backup.Exists) { [IO.File]::WriteAllBytes($Backup.Path, [byte[]]$Backup.Bytes) }
  elseif (Test-Path -LiteralPath $Backup.Path -PathType Leaf) { Remove-Item -LiteralPath $Backup.Path -Force }
}

function Assert-NoConflicts {
  $conflicts = Invoke-GitCaptured @("diff", "--name-only", "--diff-filter=U")
  if ($conflicts) { throw "Unresolved Git conflicts: $conflicts" }
}

function Assert-NoStagedSecrets {
  $paths = @((Invoke-GitCaptured @("diff", "--cached", "--name-only", "--diff-filter=ACMR")) -split "`r?`n" | Where-Object { $_ })
  foreach ($path in $paths) {
    $normalized = $path.Replace("\", "/")
    $leaf = [IO.Path]::GetFileName($normalized)
    $isExample = $leaf -match '(?i)\.(?:example|sample|template)$'
    if (-not $isExample -and $normalized -match '(?i)(^|/)(?:\.env(?:\..+)?|id_(?:rsa|dsa|ecdsa|ed25519)|credentials?(?:\..+)?|secrets?(?:\..+)?|[^/]+\.(?:pem|p12|pfx|key))$') {
      throw "Refusing to commit possible secret file: $path"
    }
  }
  $diff = Invoke-GitCaptured @("diff", "--cached", "--no-ext-diff", "--unified=0", "--", ".")
  if ($diff -match '(?m)^\+(?!\+\+).*(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)') {
    throw "Refusing to commit content that looks like a credential"
  }
}

function Commit-AllChanges([bool]$Push) {
  Assert-ChineseSummary $Summary
  Assert-NoConflicts
  $config = Read-ReleaseConfig
  $remoteState = Assert-RemoteReady $config
  $indexBackup = Backup-GitIndex
  $committed = $false
  try {
    Invoke-GitChecked @("add", "-A")
    Assert-NoStagedSecrets
    & git -C $script:ResolvedRepositoryRoot diff --cached --quiet
    $hasChanges = $LASTEXITCODE -eq 1
    if ($LASTEXITCODE -notin @(0, 1)) { throw "git diff --cached --quiet failed" }
    if ($hasChanges) {
      Invoke-GitChecked @("commit", "-m", $Summary)
      $committed = $true
      Write-Host "Committed all changes: $Summary"
    }
    else {
      Write-Host "No working tree or index changes to commit"
    }
  }
  catch {
    if (-not $committed) { Restore-GitIndex $indexBackup }
    throw
  }

  if ($Push) {
    $arguments = @("push", $remoteState.Remote, $remoteState.Branch)
    if (-not $remoteState.Exists) { $arguments = @("push", "--set-upstream", $remoteState.Remote, $remoteState.Branch) }
    Invoke-GitChecked $arguments
    Write-Host "Pushed: $($remoteState.Remote)/$($remoteState.Branch)"
  }
  return [pscustomobject]@{ Committed = $committed; Head = Invoke-GitCaptured @("rev-parse", "HEAD") }
}

function Get-WorkflowSettings($Config) {
  $automation = Get-OptionalProperty $Config "automation"
  return [pscustomobject]@{
    Managed = [bool](Get-OptionalProperty $automation "managedWorkflow" $false)
    Path = [string](Get-OptionalProperty $automation "workflowFile" $WorkflowPath)
    Generator = [string](Get-OptionalProperty $automation "generator" "")
    ProjectType = [string](Get-OptionalProperty $Config "projectType" $ProjectType)
  }
}

function Ensure-ReleaseAutomation([string]$RequestedOperation) {
  if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) { throw "Setup script missing: $setupScript" }
  $config = Read-ReleaseConfig
  if (-not $config) {
    & $setupScript -Mode Generate -ProjectType $ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
      -ConfigPath $ConfigPath -WorkflowPath $WorkflowPath `
      -ExistingWorkflowPolicy $WorkflowPolicy -SeparateWorkflowPath $SeparateWorkflowPath
    return Read-ReleaseConfig
  }

  if ($RequestedOperation -eq "LocalBuild") {
    Write-Host "Local build uses repository config without validating GitHub release workflow"
    return $config
  }

  $updateManaged = $RequestedOperation -eq "Release"
  $settings = Get-WorkflowSettings $config
  if ($updateManaged -and $settings.Managed -and $settings.Generator -in @("auto-release", "project-release-automator")) {
    & $setupScript -Mode Generate -ProjectType $settings.ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
      -ConfigPath $ConfigPath -WorkflowPath $settings.Path -ExistingWorkflowPolicy Stop
  }
  else {
    & $setupScript -Mode Validate -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -WorkflowPath $settings.Path
  }
  return Read-ReleaseConfig
}

function Get-CurrentVersion($Config) {
  $read = $Config.version.read
  $path = Resolve-RepositoryPath ([string]$read.path)
  $match = [regex]::Match([IO.File]::ReadAllText($path), [string]$read.pattern)
  if (-not $match.Success -or -not $match.Groups["version"].Success) { throw "Cannot read the current project version" }
  return $match.Groups["version"].Value
}

function Get-VersionPatternsByPath($Config) {
  $patterns = @{}
  $readPath = ([string]$Config.version.read.path).Replace("\", "/")
  $patterns[$readPath] = @([string]$Config.version.read.pattern)
  foreach ($update in @(Get-OptionalProperty $Config.version "updates" @())) {
    $path = ([string]$update.path).Replace("\", "/")
    if (-not $patterns.ContainsKey($path)) { $patterns[$path] = @() }
    $patterns[$path] += [string]$update.pattern
  }
  return $patterns
}

function Get-NormalizedFileHash([string]$RelativePath, $VersionPatterns) {
  $fullPath = Resolve-RepositoryPath $RelativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return "missing" }
  if ($VersionPatterns.ContainsKey($RelativePath)) {
    $content = [IO.File]::ReadAllText($fullPath)
    foreach ($pattern in @($VersionPatterns[$RelativePath])) {
      try {
        $regex = [regex]::new($pattern)
        $content = $regex.Replace($content, {
          param($match)
          return ([regex]::new('\d+\.\d+\.\d+')).Replace($match.Value, '<release-version>', 1)
        })
      }
      catch { throw "Invalid version fingerprint pattern for ${RelativePath}: $pattern" }
    }
    $bytes = $script:Utf8NoBom.GetBytes($content)
  }
  else {
    $bytes = [IO.File]::ReadAllBytes($fullPath)
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Get-SourceFingerprint($Config) {
  $tracked = @((Invoke-GitCaptured @("ls-files")) -split "`r?`n" | Where-Object { $_ })
  $untracked = @((Invoke-GitCaptured @("ls-files", "--others", "--exclude-standard")) -split "`r?`n" | Where-Object { $_ })
  $untracked = @($untracked | Where-Object {
    $_.Replace("\", "/") -notmatch '(^|/)(?:\.venv|bin|build|dist|node_modules|obj|out|output|release|target|vendor|venv)(/|$)'
  })
  $patterns = Get-VersionPatternsByPath $Config
  $entries = @()
  foreach ($path in @($tracked + $untracked | Sort-Object -Unique)) {
    $normalized = $path.Replace("\", "/")
    $entries += "$normalized`:$((Get-NormalizedFileHash $normalized $patterns))"
  }
  $payload = $script:Utf8NoBom.GetBytes(($entries -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Get-ReceiptPath([string]$DirectoryName = "auto-release", [bool]$CreateDirectory = $true) {
  $directory = Join-Path (Get-GitDirectory) $DirectoryName
  if ($CreateDirectory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory | Out-Null
  }
  return Join-Path $directory "local-build.json"
}

function Expand-ArtifactToken([string]$Value, $Config, [string]$CurrentVersion) {
  $prefix = [string](Get-OptionalProperty $Config "tagPrefix" "v")
  return $Value.Replace("{projectName}", [string]$Config.projectName).
    Replace("{version}", $CurrentVersion).
    Replace("{tag}", "$prefix$CurrentVersion")
}

function Get-LocalArtifactRecords($Config) {
  $records = @()
  $currentVersion = Get-CurrentVersion $Config
  $outputRelative = [string](Get-OptionalProperty $Config.prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($outputRelative)) { $outputRelative = "output" }
  $outputPath = Resolve-RepositoryPath $outputRelative
  if (Test-Path -LiteralPath $outputPath -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $outputPath -File)) {
      $relative = $file.FullName.Substring($script:ResolvedRepositoryRoot.Length + 1).Replace("\", "/")
      $records += [pscustomobject]@{
        path = $relative
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
      }
    }
  }
  if ($records.Count -gt 0) {
    return @($records | Sort-Object path -Unique)
  }

  foreach ($artifact in @(Get-OptionalProperty $Config.prepare "artifacts" @())) {
    $relative = Expand-ArtifactToken ([string](Get-OptionalProperty $artifact "destination" $artifact.source)) $Config $currentVersion
    $path = Resolve-RepositoryPath $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $records += [pscustomobject]@{ path = $relative.Replace("\", "/"); sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
    }
  }
  if ($records.Count -eq 0) {
    $extensions = switch ([string]$Config.projectType) {
      "tauri" { @(".exe", ".msi", ".dmg", ".appimage", ".deb", ".rpm") }
      "node" { @(".tgz") }
      "electron" { @(".exe", ".zip", ".dmg", ".appimage") }
      "go" { @(".exe") }
      "python" { @(".whl", ".gz") }
      "rust" { @(".crate", ".exe") }
      "dotnet" { @(".nupkg", ".exe") }
      "java" { @(".jar") }
      "cmake" { @(".exe", ".zip") }
      "flutter" { @(".exe", ".apk", ".aab", ".zip") }
      "android" { @(".apk", ".aab") }
      default { @() }
    }
    foreach ($rootName in @("dist", "build", "out", "release", "target", "src-tauri\target\release")) {
      $rootPath = Join-Path $script:ResolvedRepositoryRoot $rootName
      if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
      foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 200) {
        $relative = $file.FullName.Substring($script:ResolvedRepositoryRoot.Length + 1).Replace("\", "/")
        $records += [pscustomobject]@{ path = $relative; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash }
      }
    }
  }
  return @($records | Sort-Object path -Unique)
}

function Write-LocalBuildReceipt($Config) {
  $artifacts = @(Get-LocalArtifactRecords $Config)
  $receipt = [pscustomobject][ordered]@{
    schemaVersion = 1
    projectType = [string]$Config.projectType
    sourceFingerprint = Get-SourceFingerprint $Config
    currentVersion = Get-CurrentVersion $Config
    builtAtUtc = [DateTime]::UtcNow.ToString("o")
    artifacts = $artifacts
  }
  [IO.File]::WriteAllText((Get-ReceiptPath), (($receipt | ConvertTo-Json -Depth 10) + "`n"), $script:Utf8NoBom)
  if ($artifacts.Count -eq 0) { Write-Warning "Local build succeeded, but no verifiable local artifact was found; release will rebuild locally" }
  else { Write-Host "Recorded local build receipt with $($artifacts.Count) artifact(s)" }
}

function Test-LocalBuildFresh($Config) {
  $path = Get-ReceiptPath "auto-release" $false
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $path = Get-ReceiptPath "project-release-automator" $false
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  try { $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { return $false }
  if ([string]$receipt.projectType -ne [string]$Config.projectType) { return $false }
  if ([string]$receipt.sourceFingerprint -ne (Get-SourceFingerprint $Config)) { return $false }
  $artifacts = @($receipt.artifacts)
  if ($artifacts.Count -eq 0) { return $false }
  foreach ($artifact in $artifacts) {
    $artifactPath = Resolve-RepositoryPath ([string]$artifact.path)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { return $false }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash -ne [string]$artifact.sha256) { return $false }
  }
  return $true
}

Assert-RepositoryContext

if ($Operation -eq "CommitPush") {
  Commit-AllChanges $true | Out-Null
  exit
}

$config = Ensure-ReleaseAutomation $Operation

if ($Operation -eq "LocalBuild") {
  & $releaseScript -Mode LocalBuild -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath
  Write-LocalBuildReceipt $config
  exit
}

if (-not $Version) { throw "Version is required for Release" }
Assert-ChineseSummary $Summary
if ([string]::IsNullOrWhiteSpace($ReleaseNotes) -or $ReleaseNotes -notmatch '[\u4e00-\u9fff]') {
  throw "Chinese ReleaseNotes are required for Release"
}
$releaseMode = [string](Get-OptionalProperty $config.publish.release "mode" "none")
if ($releaseMode -eq "none") { throw "Release operation requires GitHub Release creation" }
if (-not (Get-OptionalProperty $config.publish "workflow")) { throw "Release operation requires a tag-triggered build workflow" }

$localBuildIsFresh = Test-LocalBuildFresh $config
& $releaseScript -Mode Plan -Version $Version -Summary $Summary -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath
& $releaseScript -Mode Prepare -Version $Version -Summary $Summary -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -SkipBuild:$localBuildIsFresh
if (-not $localBuildIsFresh) {
  $config = Read-ReleaseConfig
  Write-LocalBuildReceipt $config
}
$commit = Commit-AllChanges $false
& $releaseScript -Mode Publish -Version $Version -Summary $Summary -ReleaseNotes $ReleaseNotes `
  -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -AllowExistingHead:(-not $commit.Committed)
