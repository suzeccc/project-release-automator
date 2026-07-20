$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$skill = Get-Content -Raw -Encoding UTF8 (Join-Path $root "SKILL.md")
$script = Join-Path $root "scripts\release.ps1"
$setupScript = Join-Path $root "scripts\setup-project.ps1"
$invokeScript = Join-Path $root "scripts\invoke-release.ps1"
$utils = Join-Path $root "scripts\release-utils.ps1"
$reference = Join-Path $root "references\config.md"
$workflowTemplates = @(
  Join-Path $root "assets\workflows\tauri.yml"
  Join-Path $root "assets\workflows\node.yml"
  Join-Path $root "assets\workflows\go.yml"
  Join-Path $root "assets\workflows\python.yml"
  Join-Path $root "assets\workflows\rust.yml"
  Join-Path $root "assets\workflows\dotnet.yml"
  Join-Path $root "assets\workflows\java.yml"
  Join-Path $root "assets\workflows\cmake.yml"
  Join-Path $root "assets\workflows\flutter.yml"
  Join-Path $root "assets\workflows\android.yml"
  Join-Path $root "assets\workflows\electron.yml"
  Join-Path $root "assets\workflows\docker.yml"
)

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

function New-TestDirectory([string]$Label) {
  $path = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-$Label-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $path | Out-Null
  & git -C $path init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "git init failed for $Label fixture" }
  return $path
}

function Write-TestUtf8([string]$Path, [string]$Content) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

foreach ($path in @($script, $setupScript, $invokeScript, $utils, $reference) + $workflowTemplates) {
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
  Start-Sleep -Milliseconds 1500
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
    "commands": [{"name":"Check {projectName}","command":"echo {version}"}],
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
  Assert-Match $planText "Prepare command: Check Example -> echo 1\.1\.0" "plan did not expand configured command tokens"
  Assert-Match $planText "Release mode: none" "plan missing release strategy"

  & $script `
    -Mode Prepare `
    -Version v1.1.0 `
    -Summary "Generic project release." `
    -RepositoryRoot $planRoot
  $preparedPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $planRoot "package.json") | ConvertFrom-Json
  Assert-Equal $preparedPackage.version "1.1.0" "Prepare did not apply the configured version update"

  $schema2Config = Get-Content -Raw -Encoding UTF8 (Join-Path $planRoot ".codex-release.json") | ConvertFrom-Json
  $schema2Config.schemaVersion = 2
  Write-TestUtf8 `
    (Join-Path $planRoot ".codex-release.json") `
    (($schema2Config | ConvertTo-Json -Depth 20) + "`n")
  $schema2Plan = & $script `
    -Mode Plan `
    -Version v1.1.0 `
    -Summary "Generic project release." `
    -RepositoryRoot $planRoot
  Assert-Match ($schema2Plan -join [Environment]::NewLine) "Project: Example" "release runner rejected schema v2"
}
finally {
  Remove-TestDirectory $planRoot
  Remove-TestDirectory $bareRoot
}

$nodeRoot = New-TestDirectory "node"
try {
  Write-TestUtf8 (Join-Path $nodeRoot "package.json") @'
{
  "name": "node-fixture",
  "version": "1.2.3",
  "scripts": {
    "test": "node --test",
    "build": "node build.js"
  }
}
'@
  Write-TestUtf8 (Join-Path $nodeRoot "package-lock.json") @'
{
  "name": "node-fixture",
  "version": "1.2.3",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "node-fixture",
      "version": "1.2.3"
    }
  }
}
'@
  $nodeDetection = (& $setupScript -Mode Detect -RepositoryRoot $nodeRoot) | ConvertFrom-Json
  Assert-Equal $nodeDetection.projectType "node" "Node fixture was not detected"
  Assert-Equal $nodeDetection.packageManager "npm" "Node package manager was not detected"
  if (Test-Path -LiteralPath (Join-Path $nodeRoot ".codex-release.json")) {
    throw "Detect mode wrote a release config"
  }
  & $setupScript -Mode Generate -RepositoryRoot $nodeRoot
  & $setupScript -Mode Validate -RepositoryRoot $nodeRoot
  $nodeConfigPath = Join-Path $nodeRoot ".codex-release.json"
  $nodeWorkflowPath = Join-Path $nodeRoot ".github\workflows\release.yml"
  $nodeConfig = Get-Content -Raw -Encoding UTF8 $nodeConfigPath | ConvertFrom-Json
  Assert-Equal $nodeConfig.schemaVersion 2 "Node config does not use schema v2"
  Assert-Equal $nodeConfig.automation.template "node-v1" "Node config uses the wrong template"
  Assert-Equal @($nodeConfig.version.updates).Count 3 "Node config did not constrain all root version entries"
  $nodeConfigHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeConfigPath).Hash
  $nodeWorkflowHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeWorkflowPath).Hash
  & $setupScript -Mode Generate -RepositoryRoot $nodeRoot
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeConfigPath).Hash $nodeConfigHash "Node config generation is not idempotent"
  Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeWorkflowPath).Hash $nodeWorkflowHash "Node workflow generation is not idempotent"
}
finally {
  Remove-TestDirectory $nodeRoot
}

$tauriRoot = New-TestDirectory "tauri"
try {
  Write-TestUtf8 (Join-Path $tauriRoot "src-tauri\tauri.conf.json") @'
{
  "productName": "Tauri Fixture",
  "version": "2.3.4",
  "identifier": "invalid.example.fixture"
}
'@
  Write-TestUtf8 (Join-Path $tauriRoot "src-tauri\Cargo.toml") @'
[package]
name = "tauri-fixture"
version = "2.3.4"
edition = "2021"
'@
  Write-TestUtf8 (Join-Path $tauriRoot "src-tauri\Cargo.lock") @'
version = 4

[[package]]
name = "tauri-fixture"
version = "2.3.4"
'@
  Write-TestUtf8 (Join-Path $tauriRoot "package.json") @'
{
  "name": "tauri-fixture",
  "version": "2.3.4",
  "scripts": {
    "tauri": "tauri",
    "test": "vitest"
  }
}
'@
  Write-TestUtf8 (Join-Path $tauriRoot "pnpm-lock.yaml") "lockfileVersion: '9.0'`n"
  $tauriDetection = (& $setupScript -Mode Detect -RepositoryRoot $tauriRoot) | ConvertFrom-Json
  Assert-Equal $tauriDetection.projectType "tauri" "Tauri fixture was not detected with highest priority"
  Assert-Equal $tauriDetection.packageManager "pnpm" "Tauri package manager was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $tauriRoot
  & $setupScript -Mode Validate -RepositoryRoot $tauriRoot
  $tauriConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $tauriRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $tauriConfig.automation.template "tauri-v1" "Tauri config uses the wrong template"
  Assert-Equal @($tauriConfig.publish.release.requiredAssets).Count 6 "Tauri config does not validate all platform bundles"
  $tauriWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $tauriRoot ".github\workflows\release.yml")
  Assert-Match $tauriWorkflow 'windows-11-arm' "Tauri workflow is missing Windows ARM64"
  Assert-Match $tauriWorkflow 'x86_64-apple-darwin' "Tauri workflow is missing macOS Intel"
  Assert-Match $tauriWorkflow 'aarch64-apple-darwin' "Tauri workflow is missing macOS Apple Silicon"
  Assert-Match $tauriWorkflow 'x86_64-unknown-linux-gnu' "Tauri workflow is missing Linux"
}
finally {
  Remove-TestDirectory $tauriRoot
}

$goRoot = New-TestDirectory "go"
try {
  Write-TestUtf8 (Join-Path $goRoot "go.mod") "module example.invalid/team/go-fixture`n`ngo 1.24`n"
  Write-TestUtf8 (Join-Path $goRoot "cmd\go-fixture\main.go") "package main`n`nfunc main() {}`n"
  $goDetection = (& $setupScript -Mode Detect -RepositoryRoot $goRoot) | ConvertFrom-Json
  Assert-Equal $goDetection.projectType "go" "Go fixture was not detected"
  Assert-Equal $goDetection.buildPath "./cmd/go-fixture" "Go command build path was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $goRoot
  & $setupScript -Mode Validate -RepositoryRoot $goRoot
  Assert-Equal ([IO.File]::ReadAllText((Join-Path $goRoot "VERSION")).Trim()) "0.1.0" "Go VERSION default is wrong"
  $goConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $goRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $goConfig.automation.template "go-v1" "Go config uses the wrong template"
  Assert-Equal @($goConfig.publish.release.requiredAssets).Count 6 "Go config does not validate six release assets"
}
finally {
  Remove-TestDirectory $goRoot
}

$pythonRoot = New-TestDirectory "python"
try {
  Write-TestUtf8 (Join-Path $pythonRoot "pyproject.toml") @'
[project]
name = "python-fixture"
version = "1.2.3"
requires-python = ">=3.10"
'@
  New-Item -ItemType Directory -Path (Join-Path $pythonRoot "tests") | Out-Null
  $pythonDetection = (& $setupScript -Mode Detect -RepositoryRoot $pythonRoot) | ConvertFrom-Json
  Assert-Equal $pythonDetection.projectType "python" "Python fixture was not detected"
  Assert-Equal $pythonDetection.packageManager "pip" "Python package manager fallback is wrong"
  & $setupScript -Mode Generate -RepositoryRoot $pythonRoot
  & $setupScript -Mode Validate -RepositoryRoot $pythonRoot
  $pythonConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $pythonRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $pythonConfig.automation.template "python-v1" "Python config uses the wrong template"
  Assert-Equal @($pythonConfig.publish.release.requiredAssets).Count 2 "Python config does not validate wheel and sdist"
  $pythonWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $pythonRoot ".github\workflows\release.yml")
  Assert-Match $pythonWorkflow 'actions/setup-python@v6' "Python workflow uses the wrong setup action"
}
finally {
  Remove-TestDirectory $pythonRoot
}

$rustRoot = New-TestDirectory "rust"
try {
  Write-TestUtf8 (Join-Path $rustRoot "Cargo.toml") @'
[package]
name = "rust-fixture"
version = "1.2.3"
edition = "2021"
'@
  Write-TestUtf8 (Join-Path $rustRoot "src\lib.rs") "pub fn answer() -> u32 { 42 }`n"
  $rustDetection = (& $setupScript -Mode Detect -RepositoryRoot $rustRoot) | ConvertFrom-Json
  Assert-Equal $rustDetection.projectType "rust" "Rust fixture was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $rustRoot
  & $setupScript -Mode Validate -RepositoryRoot $rustRoot
  $rustConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $rustRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $rustConfig.automation.template "rust-v1" "Rust config uses the wrong template"
  Assert-Match ([string]$rustConfig.prepare.commands[1].command) 'cargo package' "Rust package command is missing"
}
finally {
  Remove-TestDirectory $rustRoot
}

$dotnetRoot = New-TestDirectory "dotnet"
try {
  Write-TestUtf8 (Join-Path $dotnetRoot "DotNetFixture.csproj") @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <PackageId>DotNet.Fixture</PackageId>
    <Version>1.2.3</Version>
  </PropertyGroup>
</Project>
'@
  $dotnetDetection = (& $setupScript -Mode Detect -RepositoryRoot $dotnetRoot) | ConvertFrom-Json
  Assert-Equal $dotnetDetection.projectType "dotnet" ".NET fixture was not detected"
  Assert-Equal $dotnetDetection.projectName "DotNet.Fixture" ".NET PackageId was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $dotnetRoot
  & $setupScript -Mode Validate -RepositoryRoot $dotnetRoot
  $dotnetConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $dotnetRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $dotnetConfig.automation.template "dotnet-v1" ".NET config uses the wrong template"
  $dotnetWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $dotnetRoot ".github\workflows\release.yml")
  Assert-Match $dotnetWorkflow 'actions/setup-dotnet@v5' ".NET workflow uses the wrong setup action"
  Assert-Match $dotnetWorkflow 'dotnet-version: "8\.0\.x"' ".NET SDK was not inferred from TargetFramework"
}
finally {
  Remove-TestDirectory $dotnetRoot
}

$mavenRoot = New-TestDirectory "maven"
try {
  Write-TestUtf8 (Join-Path $mavenRoot "pom.xml") @'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>example.invalid</groupId>
  <artifactId>java-fixture</artifactId>
  <version>1.2.3</version>
</project>
'@
  $mavenDetection = (& $setupScript -Mode Detect -RepositoryRoot $mavenRoot) | ConvertFrom-Json
  Assert-Equal $mavenDetection.projectType "java" "Maven fixture was not detected as Java"
  Assert-Equal $mavenDetection.packageManager "maven" "Maven build system was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $mavenRoot
  & $setupScript -Mode Validate -RepositoryRoot $mavenRoot
  $mavenConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $mavenRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $mavenConfig.automation.template "java-v1" "Maven config uses the wrong template"
  $mavenWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $mavenRoot ".github\workflows\release.yml")
  Assert-Match $mavenWorkflow 'actions/setup-java@v5' "Java workflow uses the wrong setup action"
  Assert-Match $mavenWorkflow 'cache: maven' "Maven dependency cache is missing"
}
finally {
  Remove-TestDirectory $mavenRoot
}

$gradleRoot = New-TestDirectory "gradle"
try {
  Write-TestUtf8 (Join-Path $gradleRoot "build.gradle.kts") @'
plugins { java }
group = "example.invalid"
version = "1.2.3"
'@
  Write-TestUtf8 (Join-Path $gradleRoot "settings.gradle.kts") 'rootProject.name = "gradle-fixture"'
  $gradleDetection = (& $setupScript -Mode Detect -RepositoryRoot $gradleRoot) | ConvertFrom-Json
  Assert-Equal $gradleDetection.projectType "java" "Gradle fixture was not detected as Java"
  Assert-Equal $gradleDetection.packageManager "gradle" "Gradle build system was not detected"
  Assert-Equal $gradleDetection.projectName "gradle-fixture" "Gradle root project name was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $gradleRoot
  & $setupScript -Mode Validate -RepositoryRoot $gradleRoot
  $gradleWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $gradleRoot ".github\workflows\release.yml")
  Assert-Match $gradleWorkflow 'cache: gradle' "Gradle dependency cache is missing"
  Assert-Match $gradleWorkflow 'build/libs' "Gradle artifact directory is wrong"
}
finally {
  Remove-TestDirectory $gradleRoot
}

$cmakeRoot = New-TestDirectory "cmake"
try {
  Write-TestUtf8 (Join-Path $cmakeRoot "CMakeLists.txt") @'
cmake_minimum_required(VERSION 3.24)
project(cmake_fixture VERSION 1.2.3 LANGUAGES CXX)
add_executable(cmake_fixture main.cpp)
'@
  Write-TestUtf8 (Join-Path $cmakeRoot "main.cpp") "int main() { return 0; }`n"
  $cmakeDetection = (& $setupScript -Mode Detect -RepositoryRoot $cmakeRoot) | ConvertFrom-Json
  Assert-Equal $cmakeDetection.projectType "cmake" "CMake fixture was not detected"
  Assert-Equal $cmakeDetection.projectName "cmake_fixture" "CMake project name was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $cmakeRoot
  & $setupScript -Mode Validate -RepositoryRoot $cmakeRoot
  $cmakeConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $cmakeRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $cmakeConfig.automation.template "cmake-v1" "CMake config uses the wrong template"
  Assert-Equal @($cmakeConfig.publish.release.requiredAssets).Count 6 "CMake config does not validate six platform archives"
  $cmakeWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $cmakeRoot ".github\workflows\release.yml")
  Assert-Match $cmakeWorkflow 'windows-11-arm' "CMake workflow is missing Windows ARM64"
  Assert-Match $cmakeWorkflow 'cmake_fixture' "CMake executable target was not rendered"
}
finally {
  Remove-TestDirectory $cmakeRoot
}

$flutterRoot = New-TestDirectory "flutter"
try {
  Write-TestUtf8 (Join-Path $flutterRoot "pubspec.yaml") @'
name: flutter_fixture
version: 1.2.3+4
environment:
  sdk: ">=3.0.0 <4.0.0"
'@
  New-Item -ItemType Directory -Path (Join-Path $flutterRoot "test") | Out-Null
  $flutterDetection = (& $setupScript -Mode Detect -RepositoryRoot $flutterRoot) | ConvertFrom-Json
  Assert-Equal $flutterDetection.projectType "flutter" "Flutter fixture was not detected"
  Assert-Equal $flutterDetection.version "1.2.3" "Flutter build metadata was not normalized"
  & $setupScript -Mode Generate -RepositoryRoot $flutterRoot
  & $setupScript -Mode Validate -RepositoryRoot $flutterRoot
  $flutterConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $flutterRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $flutterConfig.automation.template "flutter-v1" "Flutter config uses the wrong template"
  Assert-Equal @($flutterConfig.publish.release.requiredAssets).Count 7 "Flutter config does not validate all packages"
  $flutterWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $flutterRoot ".github\workflows\release.yml")
  Assert-Match $flutterWorkflow 'subosito/flutter-action@v2' "Flutter setup action is wrong"
  Assert-Match $flutterWorkflow 'android-aab' "Flutter workflow is missing Android App Bundle"
}
finally {
  Remove-TestDirectory $flutterRoot
}

$androidRoot = New-TestDirectory "android"
try {
  Write-TestUtf8 (Join-Path $androidRoot "settings.gradle.kts") 'rootProject.name = "android-fixture"'
  Write-TestUtf8 (Join-Path $androidRoot "build.gradle.kts") 'plugins { id("com.android.application") version "8.7.0" apply false }'
  Write-TestUtf8 (Join-Path $androidRoot "app\build.gradle.kts") @'
plugins { id("com.android.application") }
android {
  namespace = "invalid.example.fixture"
  defaultConfig {
    applicationId = "invalid.example.fixture"
    versionCode = 1
    versionName = "1.2.3"
  }
}
'@
  Write-TestUtf8 (Join-Path $androidRoot "gradlew") "#!/bin/sh`n"
  Write-TestUtf8 (Join-Path $androidRoot "gradlew.bat") "@echo off`r`n"
  $androidDetection = (& $setupScript -Mode Detect -RepositoryRoot $androidRoot) | ConvertFrom-Json
  Assert-Equal $androidDetection.projectType "android" "Android fixture was not detected before generic Java"
  Assert-Equal $androidDetection.buildPath "app" "Android application module was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $androidRoot
  & $setupScript -Mode Validate -RepositoryRoot $androidRoot
  $androidConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $androidRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $androidConfig.automation.template "android-v1" "Android config uses the wrong template"
  Assert-Equal @($androidConfig.publish.release.requiredAssets).Count 2 "Android config does not validate APK and AAB"
  $androidWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $androidRoot ".github\workflows\release.yml")
  Assert-Match $androidWorkflow 'gradle/actions/setup-gradle@v6' "Android workflow uses the wrong Gradle action"
}
finally {
  Remove-TestDirectory $androidRoot
}

$electronRoot = New-TestDirectory "electron"
try {
  Write-TestUtf8 (Join-Path $electronRoot "package.json") @'
{
  "name": "electron-fixture",
  "productName": "Electron Fixture",
  "version": "1.2.3",
  "devDependencies": {"electron": "^40.0.0"},
  "scripts": {"test": "node --test", "dist": "electron-builder"},
  "build": {"directories": {"output": "release-build"}}
}
'@
  Write-TestUtf8 (Join-Path $electronRoot "package-lock.json") '{"name":"electron-fixture","version":"1.2.3","lockfileVersion":3,"packages":{"":{"name":"electron-fixture","version":"1.2.3"}}}'
  $electronDetection = (& $setupScript -Mode Detect -RepositoryRoot $electronRoot) | ConvertFrom-Json
  Assert-Equal $electronDetection.projectType "electron" "Electron fixture was detected as generic Node.js"
  & $setupScript -Mode Generate -RepositoryRoot $electronRoot
  & $setupScript -Mode Validate -RepositoryRoot $electronRoot
  $electronConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $electronRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $electronConfig.automation.template "electron-v1" "Electron config uses the wrong template"
  Assert-Equal @($electronConfig.publish.release.requiredAssets).Count 6 "Electron config does not validate six platform archives"
  $electronWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $electronRoot ".github\workflows\release.yml")
  Assert-Match $electronWorkflow 'release-build/\*' "Electron output directory was not rendered"
}
finally {
  Remove-TestDirectory $electronRoot
}

$dockerRoot = New-TestDirectory "docker"
try {
  Write-TestUtf8 (Join-Path $dockerRoot "Dockerfile") @'
FROM scratch
LABEL org.opencontainers.image.title="docker-fixture"
'@
  $dockerDetection = (& $setupScript -Mode Detect -RepositoryRoot $dockerRoot) | ConvertFrom-Json
  Assert-Equal $dockerDetection.projectType "docker" "Docker-only fixture was not detected"
  & $setupScript -Mode Generate -RepositoryRoot $dockerRoot
  & $setupScript -Mode Validate -RepositoryRoot $dockerRoot
  Assert-Equal ([IO.File]::ReadAllText((Join-Path $dockerRoot "VERSION")).Trim()) "0.1.0" "Docker VERSION default is wrong"
  $dockerConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $dockerRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $dockerConfig.automation.template "docker-v1" "Docker config uses the wrong template"
  $dockerWorkflow = Get-Content -Raw -Encoding UTF8 (Join-Path $dockerRoot ".github\workflows\release.yml")
  Assert-Match $dockerWorkflow 'packages: write' "Docker workflow cannot publish GHCR packages"
  Assert-Match $dockerWorkflow 'docker/build-push-action@v7' "Docker workflow uses the wrong build action"
  Assert-Match $dockerWorkflow 'linux/amd64,linux/arm64' "Docker workflow is not multi-architecture"
}
finally {
  Remove-TestDirectory $dockerRoot
}

$ambiguousRoot = New-TestDirectory "ambiguous"
try {
  Write-TestUtf8 (Join-Path $ambiguousRoot "package.json") '{"name":"ambiguous","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $ambiguousRoot "go.mod") "module example.invalid/ambiguous`n`ngo 1.24`n"
  Assert-Throws {
    & $setupScript -Mode Detect -RepositoryRoot $ambiguousRoot
  } "detection is ambiguous" "Mixed Node and Go project must require an explicit project type"
}
finally {
  Remove-TestDirectory $ambiguousRoot
}

$humanWorkflowRoot = New-TestDirectory "human-workflow"
try {
  Write-TestUtf8 (Join-Path $humanWorkflowRoot "package.json") '{"name":"protected","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $humanWorkflowRoot ".github\workflows\release.yml") @'
name: Human Release
on: workflow_dispatch
jobs: {}
'@
  Assert-Throws {
    & $setupScript -Mode Generate -RepositoryRoot $humanWorkflowRoot
  } "Refusing to overwrite human-managed workflow" "Generator overwrote a human workflow"
  if (Test-Path -LiteralPath (Join-Path $humanWorkflowRoot ".codex-release.json")) {
    throw "Generator wrote config before checking the workflow conflict"
  }
}
finally {
  Remove-TestDirectory $humanWorkflowRoot
}

$separateWorkflowRoot = New-TestDirectory "separate-workflow"
try {
  Write-TestUtf8 (Join-Path $separateWorkflowRoot "package.json") '{"name":"separate","version":"1.0.0"}'
  $humanWorkflow = @'
name: Existing CI
on: workflow_dispatch
jobs: {}
'@
  Write-TestUtf8 (Join-Path $separateWorkflowRoot ".github\workflows\release.yml") $humanWorkflow
  & $setupScript -Mode Generate -RepositoryRoot $separateWorkflowRoot -ExistingWorkflowPolicy CreateSeparate
  Assert-Equal ([IO.File]::ReadAllText((Join-Path $separateWorkflowRoot ".github\workflows\release.yml"))) $humanWorkflow "Separate policy changed the human workflow"
  $separateConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $separateWorkflowRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $separateConfig.automation.workflowFile ".github/workflows/project-release.yml" "Separate policy selected the wrong workflow"
  Assert-Equal $separateConfig.automation.managedWorkflow $true "Separate workflow must remain generator-managed"
  Assert-Match (Get-Content -Raw -Encoding UTF8 (Join-Path $separateWorkflowRoot ".github\workflows\project-release.yml")) '^# Generated by Project Release Automator' "Separate managed workflow was not generated"
}
finally {
  Remove-TestDirectory $separateWorkflowRoot
}

$reuseWorkflowRoot = New-TestDirectory "reuse-workflow"
try {
  Write-TestUtf8 (Join-Path $reuseWorkflowRoot "package.json") '{"name":"reuse","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $reuseWorkflowRoot ".github\workflows\release.yml") @'
name: Human Release
on:
  push:
    tags:
      - "v*"
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: gh release create "$GITHUB_REF_NAME" package.tgz --draft
'@
  & $setupScript -Mode Generate -RepositoryRoot $reuseWorkflowRoot -ExistingWorkflowPolicy ReuseCompatible
  $reuseConfig = Get-Content -Raw -Encoding UTF8 (Join-Path $reuseWorkflowRoot ".codex-release.json") | ConvertFrom-Json
  Assert-Equal $reuseConfig.automation.workflowFile ".github/workflows/release.yml" "Reuse policy changed the human workflow path"
  Assert-Equal $reuseConfig.automation.managedWorkflow $false "Reused human workflow must not become generator-managed"
  Assert-Equal $reuseConfig.publish.workflow.name "Human Release" "Reused human workflow name was not recorded"
  if (Test-Path -LiteralPath (Join-Path $reuseWorkflowRoot ".github\workflows\project-release.yml")) {
    throw "Reuse policy generated an unnecessary separate workflow"
  }
}
finally {
  Remove-TestDirectory $reuseWorkflowRoot
}

$operationsRoot = New-TestDirectory "operations"
$operationsRemote = Join-Path ([IO.Path]::GetTempPath()) ("project-release-automator-operations-remote-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $operationsRemote | Out-Null
try {
  & git -C $operationsRemote init --bare | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "operations bare remote init failed" }
  & git -C $operationsRoot remote add origin $operationsRemote
  & git -C $operationsRoot config user.name "Project Release Test"
  & git -C $operationsRoot config user.email "project-release-automator@example.invalid"
  Write-TestUtf8 (Join-Path $operationsRoot "package.json") '{"name":"local-app","version":"1.0.0"}'
  Write-TestUtf8 (Join-Path $operationsRoot "source.txt") "initial`n"
  Write-TestUtf8 (Join-Path $operationsRoot ".gitignore") "dist/`n"
  Write-TestUtf8 (Join-Path $operationsRoot ".codex-release.json") @'
{
  "schemaVersion": 1,
  "projectName": "local-app",
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
    "commands": [
      {"name":"Build local program","command":"if not exist dist mkdir dist && echo local>dist\\local-app.exe"}
    ],
    "artifacts": [
      {"source":"dist/local-app.exe","sha256":true}
    ]
  },
  "publish": {"release":{"mode":"none"}}
}
'@
  & git -C $operationsRoot add package.json source.txt .gitignore .codex-release.json
  & git -C $operationsRoot commit -m "Initial operations fixture" | Out-Null
  & git -C $operationsRoot push --set-upstream origin main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "operations initial push failed" }

  & $invokeScript -Operation LocalBuild -RepositoryRoot $operationsRoot
  $localPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot "package.json") | ConvertFrom-Json
  Assert-Equal $localPackage.version "1.0.0" "LocalBuild changed the project version"
  if (-not (Test-Path -LiteralPath (Join-Path $operationsRoot "dist\local-app.exe") -PathType Leaf)) { throw "LocalBuild did not build the local program" }
  if (-not (Test-Path -LiteralPath (Join-Path $operationsRoot ".git\project-release-automator\local-build.json") -PathType Leaf)) { throw "LocalBuild did not record a build receipt" }

  Remove-Item -LiteralPath (Join-Path $operationsRoot "dist\local-app.exe") -Force
  & $script -Mode Prepare -Version v1.1.0 -Summary "Skip local build test" -RepositoryRoot $operationsRoot -SkipBuild
  if (Test-Path -LiteralPath (Join-Path $operationsRoot "dist\local-app.exe")) { throw "Prepare SkipBuild still ran build commands" }
  $preparedPackage = Get-Content -Raw -Encoding UTF8 (Join-Path $operationsRoot "package.json") | ConvertFrom-Json
  Assert-Equal $preparedPackage.version "1.1.0" "Prepare SkipBuild did not update the release version"

  Add-Content -Encoding UTF8 -LiteralPath (Join-Path $operationsRoot "source.txt") -Value "unstaged"
  Write-TestUtf8 (Join-Path $operationsRoot "staged.txt") "staged`n"
  & git -C $operationsRoot add staged.txt
  Write-TestUtf8 (Join-Path $operationsRoot "untracked.txt") "untracked`n"
  $commitSummary = "$newLabel operations changes"
  & $invokeScript -Operation CommitPush -Summary $commitSummary -RepositoryRoot $operationsRoot
  Assert-Equal (git -C $operationsRoot log -1 --pretty=%s) $commitSummary "CommitPush used the wrong commit summary"
  Assert-Equal (git -C $operationsRoot status --porcelain) $null "CommitPush did not commit all changes"
  $localHead = git -C $operationsRoot rev-parse HEAD
  $remoteHead = (git -C $operationsRoot ls-remote origin refs/heads/main).Split("`t")[0]
  Assert-Equal $remoteHead $localHead "CommitPush did not push the current branch"

  Write-TestUtf8 (Join-Path $operationsRoot ".env") "TOKEN=secret`n"
  Assert-Throws {
    & $invokeScript -Operation CommitPush -Summary $commitSummary -RepositoryRoot $operationsRoot
  } "possible secret file" "CommitPush accepted a possible secret file"
  & git -C $operationsRoot diff --cached --quiet
  if ($LASTEXITCODE -ne 0) { throw "Secret rejection did not restore the original index" }
}
finally {
  Remove-TestDirectory $operationsRoot
  Remove-TestDirectory $operationsRemote
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
Assert-Match $scriptSource 'Expand-ConfigTokens \(\[string\]\$_.command\)' "prepare commands do not expand release tokens"
Assert-Match $scriptSource 'publish-draft.*create.*none' "missing release modes"
Assert-Match $scriptSource 'schemaVersion -notin @\(1, 2\)' "release runner does not accept schema v1 and v2"
Assert-Match $scriptSource 'LocalBuild' "release runner does not support local builds"
Assert-Match $scriptSource 'SkipBuild' "release runner cannot reuse a current local build"
Assert-Match $scriptSource 'AllowExistingHead' "release runner cannot publish without an unnecessary empty commit"
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
Assert-Match $skill 'Detect[\s\S]*Generate[\s\S]*Validate' "skill does not document project setup modes"
Assert-Match $skill 'LocalBuild[\s\S]*CommitPush[\s\S]*Release' "skill does not document the three user operations"
Assert-Match $referenceSource 'publish-draft' "config reference missing draft strategy"
Assert-Match $referenceSource 'uploadAssets' "config reference missing upload assets"

$setupSource = Get-Content -Raw -Encoding UTF8 $setupScript
Assert-Match $setupSource 'Refusing to overwrite human-managed workflow' "setup script lacks workflow overwrite protection"
Assert-Match $setupSource 'CreateSeparate[\s\S]*ReuseCompatible' "setup script lacks human workflow policies"
Assert-Match $setupSource 'tauri[\s\S]*node[\s\S]*go' "setup script does not support all project types"
foreach ($projectType in @("python", "rust", "dotnet", "java")) {
  Assert-Match $setupSource ('"' + $projectType + '"') "setup script does not support $projectType"
}
foreach ($projectType in @("cmake", "flutter", "android", "electron", "docker")) {
  Assert-Match $setupSource ('"' + $projectType + '"') "setup script does not support $projectType"
}
if ($setupSource -match 'D:\\QiLin|CopyShare|suzeccc') {
  throw "generic setup script contains project-specific values"
}
$invokeSource = Get-Content -Raw -Encoding UTF8 $invokeScript
Assert-Match $invokeSource 'ValidateSet\("LocalBuild", "CommitPush", "Release"\)' "unified operation entrypoint is incomplete"
Assert-Match $invokeSource 'git.*"add", "-A"|@\("add", "-A"\)' "CommitPush does not stage all changes"
Assert-Match $invokeSource 'possible secret file' "CommitPush lacks secret path protection"
Assert-Match $invokeSource 'sourceFingerprint' "Release lacks local build freshness tracking"
Assert-Match $invokeSource 'AllowExistingHead' "Release does not support unchanged working trees"
foreach ($template in $workflowTemplates) {
  $templateSource = Get-Content -Raw -Encoding UTF8 $template
  Assert-Match $templateSource '^# Generated by Project Release Automator' "workflow template lacks managed marker"
  Assert-Match $templateSource 'permissions:[\s\S]*contents: write' "workflow template lacks release permissions"
  Assert-Match $templateSource 'draft|releaseDraft' "workflow template does not create a draft release"
}

Write-Host "project-release-automator contract passed"
