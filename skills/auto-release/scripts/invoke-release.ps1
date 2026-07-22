[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("LocalBuild", "Ignore", "CommitPush", "Release")]
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

  [string]$SeparateWorkflowPath = ".github/workflows/auto-release.yml",

  [switch]$ForceRebuild,

  [switch]$WhatIf,

  [ValidateSet("Single", "AutoSplit")]
  [string]$CommitStrategy = "Single",

  [string]$CommitPlanPath,

  [ValidateRange(2, 8)]
  [int]$MaxCommits = 4,

  [ValidateSet("Audit", "Apply", "ApplyAndUntrack")]
  [string]$IgnoreMode = "Audit",

  [string]$IgnorePlanPath,

  [ValidateSet("Human", "Json")]
  [string]$OutputFormat = "Human"
)

$ErrorActionPreference = "Stop"
$script:ResolvedRepositoryRoot = $null
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:Stage = "Initialize"
$setupScript = Join-Path $PSScriptRoot "setup-project.ps1"
$releaseScript = Join-Path $PSScriptRoot "release.ps1"
$ignoreScript = Join-Path $PSScriptRoot "ignore-audit.ps1"
$utilsScript = Join-Path $PSScriptRoot "release-utils.ps1"

if (-not (Test-Path -LiteralPath $utilsScript -PathType Leaf)) {
  throw "Release utilities missing: $utilsScript"
}
. $utilsScript

if ($OutputFormat -eq "Json") {
  $InformationPreference = "SilentlyContinue"
}

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

function Write-OperationResult($Result) {
  if ($OutputFormat -eq "Json") {
    [Console]::Out.WriteLine(($Result | ConvertTo-Json -Depth 20 -Compress))
  }
}

function Write-Preview($Preview) {
  if ($OutputFormat -eq "Json") {
    Write-OperationResult $Preview
    return
  }
  Write-Host "WhatIf: $($Preview.operation)"
  Write-Host "Repository: $($Preview.repositoryRoot)"
  if ($Preview.projectType) { Write-Host "Project type: $($Preview.projectType)" }
  if ($null -ne $Preview.localBuildFresh) { Write-Host "Reusable local build: $($Preview.localBuildFresh)" }
  if ($Preview.branch) { Write-Host "Branch: $($Preview.remote)/$($Preview.branch)" }
  if ($Preview.commitStyle) {
    Write-Host "Commit style: $($Preview.commitStyle.selectedStyle) ($($Preview.commitStyle.reason))"
  }
  foreach ($group in @($Preview.commitPlan.groups)) {
    Write-Host "Commit: $($group.summary)"
    foreach ($path in @($group.paths)) { Write-Host "  - $path" }
  }
  foreach ($action in @($Preview.actions)) { Write-Host "Would: $action" }
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

function Get-ConfiguredCommitStyleAnalysis($Config) {
  $commitConfig = Get-OptionalProperty $Config "commit"
  return Get-RepositoryCommitStyleAnalysis `
    -RepositoryRoot $script:ResolvedRepositoryRoot `
    -CommitConfig $commitConfig
}

function Assert-ConfiguredCommitSummary($Config) {
  Assert-ChineseSummary $Summary
  $analysis = Get-ConfiguredCommitStyleAnalysis $Config
  Assert-CommitSummaryStyle -Summary $Summary -Analysis $analysis
  return $analysis
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

function Get-BranchAndRemote($Config, [bool]$UseConfiguredBranch = $true) {
  $branch = if ($UseConfiguredBranch -and $Config) {
    [string]$Config.branch
  }
  else {
    Invoke-GitCaptured @("branch", "--show-current")
  }
  if (-not $branch) { throw "Detached HEAD is not supported" }
  $remote = if ($Config) { [string]$Config.remote } else { "origin" }
  if (-not $remote) { $remote = "origin" }
  return [pscustomobject]@{ Branch = $branch; Remote = $remote }
}

function Assert-RemoteReady($Config, [bool]$UseConfiguredBranch = $true) {
  $target = Get-BranchAndRemote $Config $UseConfiguredBranch
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

function Get-ChangedPaths {
  $tracked = @((Invoke-GitCaptured @("diff", "HEAD", "--name-only", "--no-renames", "--")) -split "`r?`n" | Where-Object { $_ })
  $untracked = @((Invoke-GitCaptured @("ls-files", "--others", "--exclude-standard")) -split "`r?`n" | Where-Object { $_ })
  return @($tracked + $untracked | ForEach-Object { $_.Replace("\", "/") } | Sort-Object -Unique)
}

function Get-PlanRelativePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "Commit plan contains an empty path" }
  if ($Path.IndexOfAny([char[]]@("*", "?", "[", "]")) -ge 0) {
    throw "Commit plan paths must be exact and cannot contain wildcards: $Path"
  }
  $fullPath = if ([IO.Path]::IsPathRooted($Path)) {
    [IO.Path]::GetFullPath($Path)
  }
  else {
    [IO.Path]::GetFullPath((Join-Path $script:ResolvedRepositoryRoot $Path))
  }
  $rootPrefix = $script:ResolvedRepositoryRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Commit plan path escapes repository root: $Path"
  }
  $relative = $fullPath.Substring($rootPrefix.Length).Replace("\", "/")
  if ($relative -match '(^|/)\.git(/|$)') { throw "Commit plan cannot include Git metadata: $Path" }
  return $relative
}

function Get-CommitPlanFilePath {
  if ([string]::IsNullOrWhiteSpace($CommitPlanPath)) {
    throw "CommitPlanPath is required when CommitStrategy is AutoSplit"
  }
  $fullPath = if ([IO.Path]::IsPathRooted($CommitPlanPath)) {
    [IO.Path]::GetFullPath($CommitPlanPath)
  }
  else {
    [IO.Path]::GetFullPath((Join-Path $script:ResolvedRepositoryRoot $CommitPlanPath))
  }
  $gitDirectory = Get-GitDirectory
  $gitPrefix = $gitDirectory + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($gitPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Commit plan must be stored under the Git directory: $gitDirectory"
  }
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Commit plan not found: $fullPath" }
  return $fullPath
}

function Get-PathContentFingerprint([string[]]$Paths) {
  $entries = @()
  foreach ($path in @($Paths | Sort-Object -Unique)) {
    $fullPath = [IO.Path]::GetFullPath((Join-Path $script:ResolvedRepositoryRoot $path))
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      $entries += "$path`:missing"
      continue
    }
    $entries += "$path`:$((Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash)"
  }
  $bytes = $script:Utf8NoBom.GetBytes(($entries -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Read-CommitPlan($CommitAnalysis) {
  $path = Get-CommitPlanFilePath
  try { $rawPlan = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { throw "Commit plan is invalid JSON: $path" }
  if ([int](Get-OptionalProperty $rawPlan "schemaVersion" 0) -ne 1) {
    throw "Commit plan schemaVersion must be 1"
  }
  $baseHead = Invoke-GitCaptured @("rev-parse", "HEAD")
  $plannedBase = [string](Get-OptionalProperty $rawPlan "baseHead" "")
  if ($plannedBase -and $plannedBase -ne $baseHead) {
    throw "Commit plan baseHead does not match the current HEAD"
  }
  $groups = @($rawPlan.groups)
  if ($groups.Count -lt 2) { throw "AutoSplit requires at least two commit groups" }
  if ($groups.Count -gt $MaxCommits) { throw "Commit plan exceeds MaxCommits ($MaxCommits)" }

  $actualPaths = @(Get-ChangedPaths)
  if ($actualPaths.Count -eq 0) { throw "There are no changes to commit" }
  $actualSet = @{}
  foreach ($pathValue in $actualPaths) { $actualSet[$pathValue] = $true }
  $plannedSet = @{}
  $normalizedGroups = @()
  foreach ($group in $groups) {
    $summaryValue = [string](Get-OptionalProperty $group "summary" "")
    Assert-ChineseSummary $summaryValue
    Assert-CommitSummaryStyle -Summary $summaryValue -Analysis $CommitAnalysis
    $paths = @($group.paths | ForEach-Object { Get-PlanRelativePath ([string]$_) })
    if ($paths.Count -eq 0) { throw "Commit group has no paths: $summaryValue" }
    foreach ($relative in $paths) {
      if ($plannedSet.ContainsKey($relative)) { throw "Commit plan path appears more than once: $relative" }
      if (-not $actualSet.ContainsKey($relative)) { throw "Commit plan includes an unchanged path: $relative" }
      $plannedSet[$relative] = $true
    }
    $normalizedGroups += [pscustomobject][ordered]@{
      summary = $summaryValue
      paths = @($paths | Sort-Object -Unique)
    }
  }
  $missing = @($actualPaths | Where-Object { -not $plannedSet.ContainsKey($_) })
  if ($missing.Count -gt 0) { throw "Commit plan does not cover all changes: $($missing -join ', ')" }
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = $baseHead
    groups = $normalizedGroups
    path = $path
  }
}

function Commit-PlannedChanges([bool]$Push) {
  Assert-NoConflicts
  $config = Read-ReleaseConfig
  $commitAnalysis = Get-ConfiguredCommitStyleAnalysis $config
  $plan = Read-CommitPlan $commitAnalysis
  $remoteState = Assert-RemoteReady $config $false
  $target = Get-BranchAndRemote $config $false
  $baseHead = [string]$plan.baseHead
  $indexBackup = Backup-GitIndex
  $allPaths = @($plan.groups | ForEach-Object { @($_.paths) })
  $contentFingerprint = Get-PathContentFingerprint $allPaths
  $transactionBranch = "auto-release/transaction-$([guid]::NewGuid().ToString('N'))"
  $commits = @()
  $finalized = $false
  try {
    Invoke-GitChecked @("add", "-A")
    Assert-NoStagedSecrets
    Restore-GitIndex $indexBackup

    Invoke-GitChecked @("switch", "-c", $transactionBranch, $baseHead)
    foreach ($group in @($plan.groups)) {
      Invoke-GitChecked @("reset", "--mixed", "HEAD")
      Invoke-GitChecked (@("add", "-A", "--") + @($group.paths))
      Assert-NoStagedSecrets
      Invoke-GitChecked @("diff", "--cached", "--check")
      & git -C $script:ResolvedRepositoryRoot diff --cached --quiet
      if ($LASTEXITCODE -eq 0) { throw "Commit group has no staged changes: $($group.summary)" }
      if ($LASTEXITCODE -ne 1) { throw "git diff --cached --quiet failed" }
      Invoke-GitChecked @("commit", "-m", [string]$group.summary)
      $commits += [pscustomobject][ordered]@{
        summary = [string]$group.summary
        head = Invoke-GitCaptured @("rev-parse", "HEAD")
        paths = @($group.paths)
      }
    }

    if ((Get-PathContentFingerprint $allPaths) -ne $contentFingerprint) {
      throw "Planned files changed during the commit transaction"
    }
    $remaining = Invoke-GitCaptured @("status", "--porcelain", "--untracked-files=all")
    if ($remaining) { throw "Unplanned changes appeared during the commit transaction: $remaining" }

    Invoke-GitChecked @("switch", $target.Branch)
    Invoke-GitChecked @("merge", "--ff-only", $transactionBranch)
    $finalized = $true
    Invoke-GitChecked @("branch", "-D", $transactionBranch)

    if ($Push) {
      $remoteState = Assert-RemoteReady $config $false
      $arguments = @("push", $remoteState.Remote, $remoteState.Branch)
      if (-not $remoteState.Exists) { $arguments = @("push", "--set-upstream", $remoteState.Remote, $remoteState.Branch) }
      Invoke-GitChecked $arguments
      Write-Host "Pushed $($commits.Count) commits: $($remoteState.Remote)/$($remoteState.Branch)"
    }
  }
  catch {
    $failure = $_
    if (-not $finalized) {
      try {
        $currentBranch = Invoke-GitCaptured @("branch", "--show-current")
        if ($currentBranch -eq $transactionBranch) {
          Invoke-GitChecked @("reset", "--mixed", $baseHead)
          Invoke-GitChecked @("switch", $target.Branch)
        }
        Restore-GitIndex $indexBackup
        $branchExists = Invoke-GitCaptured @("branch", "--list", $transactionBranch)
        if ($branchExists) { Invoke-GitChecked @("branch", "-D", $transactionBranch) }
      }
      catch { Write-Warning "Commit transaction rollback needs manual inspection: $($_.Exception.Message)" }
    }
    throw $failure
  }

  return [pscustomobject][ordered]@{
    Committed = $commits.Count -gt 0
    CommitCount = $commits.Count
    Commits = $commits
    Head = Invoke-GitCaptured @("rev-parse", "HEAD")
    CommitStyle = $commitAnalysis
  }
}

function Commit-AllChanges(
  [bool]$Push,
  [string]$ExpectedSourceFingerprint = "",
  [bool]$UseConfiguredBranch = $true
) {
  Assert-NoConflicts
  $config = Read-ReleaseConfig
  $commitAnalysis = Assert-ConfiguredCommitSummary $config
  $remoteState = Assert-RemoteReady $config $UseConfiguredBranch
  $indexBackup = Backup-GitIndex
  $committed = $false
  try {
    Invoke-GitChecked @("add", "-A")
    Assert-NoStagedSecrets
    if ($ExpectedSourceFingerprint -and (Get-SourceFingerprint $config) -ne $ExpectedSourceFingerprint) {
      throw "Source files changed after the verified build; release stopped before commit"
    }
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
  return [pscustomobject]@{
    Committed = $committed
    Head = Invoke-GitCaptured @("rev-parse", "HEAD")
    CommitStyle = $commitAnalysis
  }
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
    if ($RequestedOperation -eq "LocalBuild") {
      & $setupScript -Mode GenerateLocal -ProjectType $ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
        -ConfigPath $ConfigPath -WorkflowPath $WorkflowPath
    }
    else {
      & $setupScript -Mode Generate -ProjectType $ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
        -ConfigPath $ConfigPath -WorkflowPath $WorkflowPath `
        -ExistingWorkflowPolicy $WorkflowPolicy -SeparateWorkflowPath $SeparateWorkflowPath
    }
    return Read-ReleaseConfig
  }

  if ($RequestedOperation -eq "LocalBuild") {
    Write-Host "Local build uses repository config without validating GitHub release workflow"
    return $config
  }

  $updateManaged = $RequestedOperation -eq "Release"
  $settings = Get-WorkflowSettings $config
  $automation = Get-OptionalProperty $config "automation"
  $localOnly = [bool](Get-OptionalProperty $automation "localOnly" $false)
  if ($updateManaged -and $localOnly -and $settings.Generator -in @("auto-release", "project-release-automator")) {
    & $setupScript -Mode Generate -ProjectType $settings.ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot `
      -ConfigPath $ConfigPath -WorkflowPath $settings.Path `
      -ExistingWorkflowPolicy $WorkflowPolicy -SeparateWorkflowPath $SeparateWorkflowPath
  }
  elseif ($updateManaged -and $settings.Managed -and $settings.Generator -in @("auto-release", "project-release-automator")) {
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

function Read-LocalBuildReceipt {
  $path = Get-ReceiptPath "auto-release" $false
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $path = Get-ReceiptPath "project-release-automator" $false
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { return $null }
}

function Get-ReceiptArtifactPaths {
  $receipt = Read-LocalBuildReceipt
  if (-not $receipt) { return @() }
  return @($receipt.artifacts | ForEach-Object { [string]$_.path } | Where-Object { $_ })
}

function Get-ArtifactManifestPath {
  $directory = Split-Path -Parent (Get-ReceiptPath)
  return Join-Path $directory "artifacts.json"
}

function Expand-ArtifactToken([string]$Value, $Config, [string]$CurrentVersion) {
  $prefix = [string](Get-OptionalProperty $Config "tagPrefix" "v")
  return $Value.Replace("{projectName}", [string]$Config.projectName).
    Replace("{version}", $CurrentVersion).
    Replace("{tag}", "$prefix$CurrentVersion")
}

function Get-LocalArtifactRecords($Config, [string]$ManifestPath = "") {
  if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    try { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json }
    catch { throw "Local artifact manifest is invalid: $ManifestPath" }
    $manifestRecords = @($manifest.artifacts)
    foreach ($record in $manifestRecords) {
      $path = Resolve-RepositoryPath ([string]$record.path)
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Manifest artifact not found: $($record.path)"
      }
      $record.sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    }
    return @($manifestRecords | Select-Object path, sha256 | Sort-Object path -Unique)
  }
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

function Remove-StaleManagedArtifacts($Config, [string[]]$PreviousPaths, $CurrentArtifacts) {
  $outputRelative = [string](Get-OptionalProperty $Config.prepare "localOutputDirectory" "output")
  if ([string]::IsNullOrWhiteSpace($outputRelative)) { $outputRelative = "output" }
  $outputRoot = Resolve-RepositoryPath $outputRelative
  $outputPrefix = $outputRoot + [IO.Path]::DirectorySeparatorChar
  $current = @{}
  foreach ($artifact in @($CurrentArtifacts)) {
    $current[([string]$artifact.path).Replace("\", "/").ToLowerInvariant()] = $true
  }
  foreach ($relativePath in @($PreviousPaths | Where-Object { $_ })) {
    $key = $relativePath.Replace("\", "/").ToLowerInvariant()
    if ($current.ContainsKey($key)) { continue }
    $path = Resolve-RepositoryPath $relativePath
    if (-not $path.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      Remove-Item -LiteralPath $path -Force
      Write-Host "Removed stale managed local artifact: $relativePath"
    }
  }
}

function Write-LocalBuildReceipt(
  $Config,
  [string]$ManifestPath = "",
  [string[]]$PreviousPaths = @(),
  [bool]$PruneStaleArtifacts = $false
) {
  $artifacts = @(Get-LocalArtifactRecords $Config $ManifestPath)
  if ($PruneStaleArtifacts) {
    Remove-StaleManagedArtifacts $Config $PreviousPaths $artifacts
  }
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
  $receipt = Read-LocalBuildReceipt
  if (-not $receipt) { return $false }
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

function Invoke-StableReleaseBuild($Config, [string]$ManifestPath) {
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $before = Get-SourceFingerprint $Config
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
      Remove-Item -LiteralPath $ManifestPath -Force
    }
    $canonicalLocalOutput = [string](Get-OptionalProperty $Config.publish.release "mode" "none") -eq "publish-draft"
    & $releaseScript -Mode Prepare -Version $Version -Summary $Summary `
      -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath `
      -ArtifactManifestPath $ManifestPath -CanonicalLocalOutput:$canonicalLocalOutput | Out-Host
    $Config = Read-ReleaseConfig
    $after = Get-SourceFingerprint $Config
    if ($before -eq $after) {
      Write-LocalBuildReceipt $Config $ManifestPath
      return [pscustomobject]@{ Config = $Config; Fingerprint = $after }
    }
    if ($attempt -lt 2) {
      Write-Warning "Source files changed during the verified build; rebuilding once with the new state"
    }
  }
  throw "Source files kept changing during the verified build; release stopped"
}

function Invoke-WhatIfPreview {
  $config = Read-ReleaseConfig
  $detected = $null
  if (-not $config -and $Operation -ne "CommitPush") {
    $detected = (& $setupScript -Mode Detect -ProjectType $ProjectType -RepositoryRoot $script:ResolvedRepositoryRoot) | ConvertFrom-Json
  }
  $projectTypeValue = if ($config) { [string](Get-OptionalProperty $config "projectType" "custom") } else { [string]$detected.projectType }
  $actions = @()
  $branch = ""
  $remote = ""
  $fresh = $null
  $commitAnalysis = $null
  if ($Operation -eq "CommitPush") {
    $commitAnalysis = Get-ConfiguredCommitStyleAnalysis $config
    $target = Get-BranchAndRemote $config $false
    $branch = $target.Branch
    $remote = $target.Remote
    if ($CommitStrategy -eq "AutoSplit") {
      $commitPlan = Read-CommitPlan $commitAnalysis
      $actions = @("validate exact commit-plan coverage", "create $(@($commitPlan.groups).Count) commits on a transaction branch", "fast-forward the current branch", "push all commits together")
    }
    else {
      Assert-ChineseSummary $Summary
      Assert-CommitSummaryStyle -Summary $Summary -Analysis $commitAnalysis
      $actions = @("stage all safe changes", "commit with the supplied Chinese summary", "push the current branch")
    }
  }
  elseif ($Operation -eq "LocalBuild") {
    $fresh = if ($config) { -not $ForceRebuild -and (Test-LocalBuildFresh $config) } else { $false }
    if ($fresh) {
      $actions = @("reuse the verified local build receipt")
    }
    else {
      $actions = @("initialize local-only configuration if needed", "run dependency bootstrap when its inputs changed", "run fast local commands", "write canonical output and build receipt")
    }
  }
  else {
    if (-not $Version) { throw "Version is required for Release" }
    $commitAnalysis = Assert-ConfiguredCommitSummary $config
    if ([string]::IsNullOrWhiteSpace($ReleaseNotes) -or $ReleaseNotes -notmatch '[\u4e00-\u9fff]') {
      throw "Chinese ReleaseNotes are required for Release"
    }
    if ($config) {
      $target = Get-BranchAndRemote $config $true
      $branch = $target.Branch
      $remote = $target.Remote
      $fresh = -not $ForceRebuild -and (Test-LocalBuildFresh $config)
    }
    $actions = @("create or validate release automation", "plan version $Version", "run a verified build unless reusable", "commit safe changes", "atomically push branch and tag", "wait for GitHub Actions and publish the draft Release")
  }
  $changesText = Invoke-GitCaptured @("status", "--short")
  return [pscustomobject][ordered]@{
    operation = $Operation
    status = "planned"
    whatIf = $true
    repositoryRoot = $script:ResolvedRepositoryRoot
    projectType = $projectTypeValue
    version = $Version
    branch = $branch
    remote = $remote
    localBuildFresh = $fresh
    commitStyle = $commitAnalysis
    commitStrategy = $CommitStrategy
    commitPlan = $commitPlan
    changes = @($changesText -split "`r?`n" | Where-Object { $_ })
    actions = $actions
  }
}

function Invoke-Main {
  $script:Stage = "RepositoryCheck"
  Assert-RepositoryContext
  if ($Operation -eq "Ignore") {
    $script:Stage = "Ignore"
    if (-not (Test-Path -LiteralPath $ignoreScript -PathType Leaf)) { throw "Ignore audit script missing: $ignoreScript" }
    $mode = if ($WhatIf) { "Audit" } else { $IgnoreMode }
    $ignoreArguments = @{
      Mode = $mode
      RepositoryRoot = $script:ResolvedRepositoryRoot
      OutputFormat = "Json"
      NoWritePlan = [bool]$WhatIf
    }
    if ($IgnorePlanPath) { $ignoreArguments.PlanPath = $IgnorePlanPath }
    $output = & $ignoreScript @ignoreArguments
    if ($LASTEXITCODE -ne 0) { throw "Ignore $mode failed" }
    $result = (@($output) | Select-Object -Last 1) | ConvertFrom-Json
    if ($OutputFormat -eq "Json") {
      Write-OperationResult $result
    }
    elseif ($mode -eq "Audit") {
      Write-Host "Ignore audit: $script:ResolvedRepositoryRoot"
      foreach ($rule in @($result.plan.rules)) { Write-Host "Add: $($rule.pattern) - $($rule.reason)" }
      foreach ($item in @($result.plan.review)) { Write-Host "Review: $($item.pattern) - $($item.reason)" }
      foreach ($path in @($result.plan.untrackPaths)) { Write-Host "Tracked match: $path" }
      foreach ($path in @($result.plan.sensitivePaths)) { Write-Host "Sensitive: $path" }
      Write-Host "Plan: $($result.planPath)"
    }
    else {
      Write-Host "Ignore $mode completed"
      Write-Host "Rules added: $(@($result.rulesAdded).Count)"
      Write-Host "Paths untracked: $(@($result.untrackedPaths).Count)"
    }
    return
  }
  if ($WhatIf) {
    $script:Stage = "Plan"
    Write-Preview (Invoke-WhatIfPreview)
    return
  }

  if ($Operation -eq "CommitPush") {
    $script:Stage = "CommitPush"
    $commit = if ($CommitStrategy -eq "AutoSplit") {
      Commit-PlannedChanges $true
    }
    else {
      Commit-AllChanges $true "" $false
    }
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation; status = "succeeded"; committed = $commit.Committed; commitCount = $commit.CommitCount; commits = $commit.Commits; head = $commit.Head; commitStyle = $commit.CommitStyle
    })
    return
  }

  $script:Stage = "Automation"
  $config = Ensure-ReleaseAutomation $Operation

  if ($Operation -eq "LocalBuild") {
    $script:Stage = "LocalBuild"
    if (-not $ForceRebuild -and (Test-LocalBuildFresh $config)) {
      Write-Host "Local build is current; reusing verified output. Use -ForceRebuild to rebuild."
      $receipt = Read-LocalBuildReceipt
      Write-OperationResult ([pscustomobject][ordered]@{
        operation = $Operation; status = "succeeded"; reused = $true; artifacts = @($receipt.artifacts)
      })
      return
    }
    $previousPaths = @(Get-ReceiptArtifactPaths)
    $manifestPath = Get-ArtifactManifestPath
    try {
      if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
      }
      & $releaseScript -Mode LocalBuild -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath `
        -ArtifactManifestPath $manifestPath -ManagedLocalArtifactPath $previousPaths | Out-Host
      Write-LocalBuildReceipt $config $manifestPath $previousPaths $true
    }
    finally {
      if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
      }
    }
    $receipt = Read-LocalBuildReceipt
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation; status = "succeeded"; reused = $false; artifacts = @($receipt.artifacts)
    })
    return
  }

  if (-not $Version) { throw "Version is required for Release" }
  $commitAnalysis = Assert-ConfiguredCommitSummary $config
  if ([string]::IsNullOrWhiteSpace($ReleaseNotes) -or $ReleaseNotes -notmatch '[\u4e00-\u9fff]') {
    throw "Chinese ReleaseNotes are required for Release"
  }
  $releaseMode = [string](Get-OptionalProperty $config.publish.release "mode" "none")
  if ($releaseMode -eq "none") { throw "Release operation requires GitHub Release creation" }
  if (-not (Get-OptionalProperty $config.publish "workflow")) { throw "Release operation requires a tag-triggered build workflow" }

  $localBuildIsFresh = -not $ForceRebuild -and (Test-LocalBuildFresh $config)
  $script:Stage = "Plan"
  & $releaseScript -Mode Plan -Version $Version -Summary $Summary -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath | Out-Host
  $manifestPath = Get-ArtifactManifestPath
  try {
    $verifiedFingerprint = ""
    $script:Stage = "Prepare"
    if ($localBuildIsFresh) {
      $before = Get-SourceFingerprint $config
      & $releaseScript -Mode Prepare -Version $Version -Summary $Summary `
        -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -SkipBuild | Out-Host
      $config = Read-ReleaseConfig
      $after = Get-SourceFingerprint $config
      if ($before -eq $after -and (Test-LocalBuildFresh $config)) {
        $verifiedFingerprint = $after
      }
      else {
        Write-Warning "The verified local build became stale during release preparation; rebuilding"
        $result = Invoke-StableReleaseBuild $config $manifestPath
        $config = $result.Config
        $verifiedFingerprint = $result.Fingerprint
      }
    }
    else {
      $result = Invoke-StableReleaseBuild $config $manifestPath
      $config = $result.Config
      $verifiedFingerprint = $result.Fingerprint
    }
    $script:Stage = "Commit"
    $commit = Commit-AllChanges $false $verifiedFingerprint $true
    $script:Stage = "Publish"
    & $releaseScript -Mode Publish -Version $Version -Summary $Summary -ReleaseNotes $ReleaseNotes `
      -RepositoryRoot $script:ResolvedRepositoryRoot -ConfigPath $ConfigPath -AllowExistingHead:(-not $commit.Committed)
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation; status = "succeeded"; version = $Version; tag = "$([string](Get-OptionalProperty $config 'tagPrefix' 'v'))$($Version.TrimStart('v'))"; head = $commit.Head; localBuildReused = $localBuildIsFresh; commitStyle = $commitAnalysis
    })
  }
  finally {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      Remove-Item -LiteralPath $manifestPath -Force
    }
  }
}

try {
  Invoke-Main
}
catch {
  if ($OutputFormat -eq "Json") {
    $code = "AUTO_RELEASE_$($script:Stage.ToUpperInvariant())_FAILED"
    Write-OperationResult ([pscustomobject][ordered]@{
      operation = $Operation
      status = "failed"
      stage = $script:Stage
      errorCode = $code
      message = $_.Exception.Message
    })
    exit 1
  }
  throw
}
