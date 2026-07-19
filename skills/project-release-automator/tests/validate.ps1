$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$skill = Get-Content -Raw -Encoding UTF8 (Join-Path $root "SKILL.md")
$script = Join-Path $root "scripts\release.ps1"
$utils = Join-Path $root "scripts\release-utils.ps1"
$reference = Join-Path $root "references\config.md"

function Assert-Match([string]$Value, [string]$Pattern, [string]$Message) {
  if ($Value -notmatch $Pattern) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -ne $Expected) {
    throw "$Message. Expected: $Expected; Actual: $Actual"
  }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
  try {
    & $Action
  }
  catch {
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "$Message. Unexpected error: $($_.Exception.Message)"
    }
    return
  }
  throw "$Message. Expected an exception"
}

function Remove-TestDirectory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $resolved = [IO.Path]::GetFullPath($Path)
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (
    -not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($resolved) -notlike "project-release-automator-*"
  ) {
    throw "Refusing to remove unexpected test path: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($path in @($script, $utils, $reference)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required skill file missing: $path"
  }
}

. $utils
$scriptSource = Get-Content -Raw -Encoding UTF8 $script
$referenceSource = Get-Content -Raw -Encoding UTF8 $reference

$runJson = @'
[
  {"databaseId":3001,"headBranch":"v1.2.3","headSha":"target-sha","status":"in_progress","url":"https://example.invalid/runs/3001"},
  {"databaseId":3002,"headBranch":"v1.2.3","headSha":"other-sha","status":"completed","url":"https://example.invalid/runs/3002"}
]
'@
$selectedRun = Select-WorkflowRun -Json $runJson -Tag "v1.2.3" -HeadSha "target-sha"
Assert-Equal @($selectedRun).Count 1 "workflow selection returned multiple objects"
Assert-Equal ([string]$selectedRun.databaseId) "3001" "wrong workflow ID"
Assert-Equal (Select-WorkflowRun -Json $runJson -Tag "v9.9.9" -HeadSha "missing") $null "missing run must return null"

$waitingRun = '{"status":"in_progress","conclusion":"","jobs":[{"name":"Build","status":"in_progress","conclusion":""}]}' | ConvertFrom-Json
$waitingSnapshot = Get-WorkflowRunSnapshot -Run $waitingRun
Assert-Equal $waitingSnapshot.State "Waiting" "active job must wait"
Assert-Equal (Test-WorkflowSnapshotChanged -PreviousSignature $waitingSnapshot.Signature -Snapshot $waitingSnapshot) $false "same state must not print twice"

$failedRun = '{"status":"in_progress","conclusion":"","jobs":[{"name":"Build","status":"completed","conclusion":"failure"}]}' | ConvertFrom-Json
$failedSnapshot = Get-WorkflowRunSnapshot -Run $failedRun
Assert-Equal $failedSnapshot.State "Failed" "terminal job failure must stop waiting"
Assert-Match $failedSnapshot.Message "Build.*failure" "failure must identify the job"

$successRun = '{"status":"completed","conclusion":"success","jobs":[{"name":"Build","status":"completed","conclusion":"success"}]}' | ConvertFrom-Json
$successSnapshot = Get-WorkflowRunSnapshot -Run $successRun
Assert-Equal $successSnapshot.State "Succeeded" "successful workflow must complete"

$updatesHeading =
  ([char]0x66F4).ToString() +
  ([char]0x65B0).ToString() +
  ([char]0x5185).ToString() +
  ([char]0x5BB9).ToString()
$newLabel = ([char]0x65B0).ToString() + ([char]0x589E).ToString()
$fixLabel = ([char]0x4FEE).ToString() + ([char]0x590D).ToString()
$validNotes = @(
  "## $updatesHeading",
  "",
  "- ${newLabel}: user-visible capability.",
  "- ${fixLabel}: release blocker."
) -join [Environment]::NewLine
Assert-ReleaseNotes -ReleaseNotes $validNotes -Heading "## $updatesHeading" -MinItems 2 -MaxItems 6 -RequireChinese $true
Assert-Throws {
  Assert-ReleaseNotes -ReleaseNotes "one-line summary" -Heading "## Changes" -MinItems 2 -MaxItems 6
} "must contain heading" "missing release heading must fail"
Assert-Throws {
  Assert-ReleaseNotes -ReleaseNotes "## Changes`n`n- one" -Heading "## Changes" -MinItems 2 -MaxItems 6
} "2 to 6" "too few release-note items must fail"

$parallelRoot = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-parallel-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $parallelRoot | Out-Null
$shell = (Get-Process -Id $PID).Path
try {
  $worker = @'
param([string]$OwnMarker, [string]$OtherMarker)
New-Item -ItemType File -Path $OwnMarker -Force | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not (Test-Path -LiteralPath $OtherMarker)) {
  if ([DateTime]::UtcNow -ge $deadline) { exit 9 }
  Start-Sleep -Milliseconds 50
}
'@
  [IO.File]::WriteAllText((Join-Path $parallelRoot "a.ps1"), $worker)
  [IO.File]::WriteAllText((Join-Path $parallelRoot "b.ps1"), $worker)
  $quotedShell = '"' + $shell + '"'
  Invoke-ParallelShellChecked -WorkingDirectory $parallelRoot -Commands @(
    @{ name = "worker-a"; command = "$quotedShell -NoProfile -File a.ps1 a.marker b.marker" },
    @{ name = "worker-b"; command = "$quotedShell -NoProfile -File b.ps1 b.marker a.marker" }
  )

  [IO.File]::WriteAllText((Join-Path $parallelRoot "fail.ps1"), "exit 7")
  [IO.File]::WriteAllText(
    (Join-Path $parallelRoot "slow.ps1"),
    'Start-Sleep -Seconds 10; New-Item -ItemType File -Path "leaked.marker" | Out-Null'
  )
  Assert-Throws {
    Invoke-ParallelShellChecked -WorkingDirectory $parallelRoot -Commands @(
      @{ name = "worker-fail"; command = "$quotedShell -NoProfile -File fail.ps1" },
      @{ name = "worker-slow"; command = "$quotedShell -NoProfile -File slow.ps1" }
    )
  } "worker-fail.*exit code 7" "parallel failure must identify the original command"
  Start-Sleep -Milliseconds 500
  if (Test-Path -LiteralPath (Join-Path $parallelRoot "leaked.marker")) {
    throw "parallel failure left a child process running"
  }
}
finally {
  Remove-TestDirectory $parallelRoot
}

$planRoot = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-plan-" + [guid]::NewGuid().ToString("N"))
$bareRoot = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-remote-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $planRoot | Out-Null
New-Item -ItemType Directory -Path $bareRoot | Out-Null
try {
  & git -C $planRoot init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git init failed" }
  & git -C $bareRoot init --bare | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "bare git init failed" }
  & git -C $planRoot remote add origin $bareRoot
  if ($LASTEXITCODE -ne 0) { throw "git remote add failed" }
  [IO.File]::WriteAllText(
    (Join-Path $planRoot "package.json"),
    '{"name":"example","version":"1.0.0"}',
    [Text.UTF8Encoding]::new($false)
  )
  $config = @'
{
  "schemaVersion": 1,
  "projectName": "Example",
  "branch": "main",
  "remote": "origin",
  "tagPrefix": "v",
  "version": {
    "read": {
      "path": "package.json",
      "pattern": "\\\"version\\\"\\s*:\\s*\\\"(?<version>\\d+\\.\\d+\\.\\d+)\\\""
    },
    "updates": [
      {
        "path": "package.json",
        "pattern": "(\\\"version\\\"\\s*:\\s*\\\")\\d+\\.\\d+\\.\\d+(\\\")",
        "replacement": "${1}{version}$2",
        "expectedMatches": 1
      }
    ]
  },
  "prepare": {
    "parallel": false,
    "commands": [{"name":"Check","command":"echo checked"}],
    "artifacts": []
  },
  "publish": {
    "release": {"mode":"none"}
  }
}
'@
  [IO.File]::WriteAllText(
    (Join-Path $planRoot ".codex-release.json"),
    $config,
    [Text.UTF8Encoding]::new($false)
  )
  & git -C $planRoot config user.name "Project Release Test"
  & git -C $planRoot config user.email "project-release-automator@example.invalid"
  & git -C $planRoot add package.json .codex-release.json
  & git -C $planRoot commit -m "Initial test project" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "initial commit failed" }
  & git -C $planRoot push --set-upstream origin main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "initial push failed" }

  $plan = & $script `
    -Mode Plan `
    -Version v1.1.0 `
    -Summary "Generic project release." `
    -RepositoryRoot $planRoot
  $planText = $plan -join [Environment]::NewLine
  Assert-Match $planText "Project: Example" "plan missing configured project name"
  Assert-Match $planText "Target version: 1\.1\.0" "plan missing target version"
  Assert-Match $planText "Prepare command: Check -> echo checked" "plan missing configured command"
  Assert-Match $planText "Release mode: none" "plan missing release strategy"

  & $script `
    -Mode Prepare `
    -Version v1.1.0 `
    -Summary "Generic project release." `
    -RepositoryRoot $planRoot
  $preparedPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $planRoot "package.json") | ConvertFrom-Json
  Assert-Equal $preparedPackage.version "1.1.0" "Prepare did not apply the configured version update"
}
finally {
  Remove-TestDirectory $planRoot
  Remove-TestDirectory $bareRoot
}

Assert-Match $scriptSource '\.codex-release\.json' "script does not use repository config"
Assert-Match $scriptSource 'remoteUrlPattern' "script does not validate configured remote"
Assert-Match $scriptSource 'git.*push|"push"' "script does not push releases"
Assert-Match $scriptSource '"--atomic"' "script does not use atomic push"
Assert-Match $scriptSource 'Local tag already exists' "missing local tag guard"
Assert-Match $scriptSource 'Remote tag already exists' "missing remote tag guard"
Assert-Match $scriptSource 'ahead or diverged' "missing remote divergence guard"
Assert-Match $scriptSource 'Release is already public' "missing public release guard"
Assert-Match $scriptSource 'gh\.exe' "missing GitHub CLI fallback"
Assert-Match $scriptSource 'Invoke-ParallelShellChecked' "missing parallel prepare support"
Assert-Match $scriptSource 'publish-draft.*create.*none' "missing release modes"
if ($scriptSource -match 'D:\\QiLin|CopyShare|suzeccc') {
  throw "generic release script still contains CopyShare-specific values"
}
if ($scriptSource -match 'gh.*run.*watch') {
  throw "script must use structured workflow polling"
}

Assert-Match $skill '^---[\s\S]*name: project-release-automator' "skill name is not project-release-automator"
Assert-Match $skill '\.codex-release\.json' "skill does not document repository config"
Assert-Match $skill 'Plan[\s\S]*Prepare[\s\S]*Publish' "missing phase order"
Assert-Match $skill '`--force`' "missing force-push guard"
Assert-Match $skill '`git add \.`' "missing staging guard"
Assert-Match $referenceSource 'publish-draft' "config reference missing draft strategy"
Assert-Match $referenceSource 'uploadAssets' "config reference missing upload assets"

Write-Host "project-release-automator contract passed"
