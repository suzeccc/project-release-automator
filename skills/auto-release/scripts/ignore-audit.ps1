[CmdletBinding()]
param(
  [ValidateSet("Audit", "Apply", "ApplyAndUntrack")]
  [string]$Mode = "Audit",

  [string]$RepositoryRoot = (Get-Location).Path,

  [string]$PlanPath,

  [switch]$NoWritePlan,

  [ValidateSet("Human", "Json")]
  [string]$OutputFormat = "Human"
)

$ErrorActionPreference = "Stop"
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:Root = $null
$script:GitDirectory = $null
$script:Candidates = @()
$script:CandidatePatterns = @{}
$script:BeginMarker = "# BEGIN Auto Release managed ignores"
$script:EndMarker = "# END Auto Release managed ignores"

function Invoke-GitCaptured([string[]]$Arguments, [bool]$AllowFailure = $false) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & git -C $script:Root @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  $standardOutput = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = (($standardOutput | Out-String).Trim())
  }
}

function Invoke-GitChecked([string[]]$Arguments) {
  $result = Invoke-GitCaptured $Arguments
  foreach ($line in @($result.Output -split "`r?`n" | Where-Object { $_ })) { Write-Host $line }
}

function Get-NormalizedPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
}

function Initialize-Context {
  if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root not found: $RepositoryRoot"
  }
  $script:Root = Get-NormalizedPath (Resolve-Path -LiteralPath $RepositoryRoot).Path
  $gitRootResult = Invoke-GitCaptured @("rev-parse", "--show-toplevel")
  $gitRoot = Get-NormalizedPath $gitRootResult.Output
  if (-not $gitRoot.Equals($script:Root, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository root mismatch: $gitRoot"
  }
  $gitDirectory = (Invoke-GitCaptured @("rev-parse", "--git-dir")).Output
  if (-not [IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $script:Root $gitDirectory }
  $script:GitDirectory = Get-NormalizedPath $gitDirectory
}

function Get-ResolvedPlanPath {
  $path = if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    Join-Path $script:GitDirectory "auto-release\ignore-plan.json"
  }
  elseif ([IO.Path]::IsPathRooted($PlanPath)) {
    [IO.Path]::GetFullPath($PlanPath)
  }
  else {
    [IO.Path]::GetFullPath((Join-Path $script:Root $PlanPath))
  }
  $prefix = $script:GitDirectory + [IO.Path]::DirectorySeparatorChar
  if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Ignore plan must be stored under the Git directory: $script:GitDirectory"
  }
  return $path
}

function Get-RepositoryRelativePath([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $prefix = $script:Root + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path escapes repository root: $Path"
  }
  return $fullPath.Substring($prefix.Length).Replace("\", "/")
}

function Get-WorktreeFingerprint {
  $head = (Invoke-GitCaptured @("rev-parse", "HEAD")).Output
  $status = (Invoke-GitCaptured @("status", "--porcelain=v1", "--untracked-files=all")).Output
  $payload = $script:Utf8NoBom.GetBytes("$head`n$status")
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Add-Candidate(
  [string]$Pattern,
  [string]$SamplePath,
  [string]$MatchRegex,
  [string]$Category,
  [string]$Reason,
  [double]$Confidence = 1.0,
  [bool]$AllowTrackedIfUnreferenced = $false,
  [string]$ReferenceToken = ""
) {
  if ($script:CandidatePatterns.ContainsKey($Pattern)) { return }
  $script:CandidatePatterns[$Pattern] = $true
  $script:Candidates += [pscustomobject][ordered]@{
    pattern = $Pattern
    samplePath = $SamplePath
    matchRegex = $MatchRegex
    category = $Category
    reason = $Reason
    confidence = $Confidence
    allowTrackedIfUnreferenced = $AllowTrackedIfUnreferenced
    referenceToken = $ReferenceToken
  }
}

function Test-RootPath([string]$RelativePath) {
  return Test-Path -LiteralPath (Join-Path $script:Root $RelativePath)
}

function Get-DetectedProjectTypes {
  $types = @()
  $packagePath = Join-Path $script:Root "package.json"
  $packageText = if (Test-Path -LiteralPath $packagePath -PathType Leaf) { [IO.File]::ReadAllText($packagePath) } else { "" }
  $pubspecPath = Join-Path $script:Root "pubspec.yaml"
  $pubspecText = if (Test-Path -LiteralPath $pubspecPath -PathType Leaf) { [IO.File]::ReadAllText($pubspecPath) } else { "" }
  if ($packageText) { $types += "node" }
  if (Test-RootPath "src-tauri\tauri.conf.json") { $types += "tauri" }
  if (Test-RootPath "Cargo.toml" -or Test-RootPath "src-tauri\Cargo.toml") { $types += "rust" }
  if (Test-RootPath "go.mod") { $types += "go" }
  if (Test-RootPath "pyproject.toml" -or Test-RootPath "setup.py" -or Test-RootPath "requirements.txt") { $types += "python" }
  $dotnetProjects = @(Get-ChildItem -LiteralPath $script:Root -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -in @(".sln", ".csproj", ".fsproj")
  })
  if ($dotnetProjects.Count -gt 0) { $types += "dotnet" }
  if (Test-RootPath "pom.xml" -or Test-RootPath "build.gradle" -or Test-RootPath "build.gradle.kts") { $types += "java" }
  if (Test-RootPath "gradlew" -and (Test-RootPath "settings.gradle" -or Test-RootPath "settings.gradle.kts")) { $types += "android" }
  if (Test-RootPath "CMakeLists.txt") { $types += "cmake" }
  if ($pubspecText -match '(?m)^\s+sdk:\s*flutter\s*$') { $types += "flutter" }
  if ($packageText -match '(?i)"electron"\s*:') { $types += "electron" }
  if (Test-RootPath "Dockerfile" -or Test-RootPath "docker-compose.yml" -or Test-RootPath "compose.yml") { $types += "docker" }
  return @($types | Sort-Object -Unique)
}

function Add-CommonCandidates {
  Add-Candidate "*.log" ".auto-release-probe.log" '(?i)(^|/)[^/]+\.log$' "Logs" "Runtime and tool logs"
  Add-Candidate "logs/" "logs/.auto-release-probe" '(?i)(^|/)logs/' "Logs" "Runtime log directory"
  Add-Candidate ".env" ".env" '(?i)(^|/)\.env$' "Secrets" "Local environment configuration"
  Add-Candidate ".env.*" ".env.local" '(?i)(^|/)\.env\.(?!(?:example|sample|template)$)[^/]+$' "Secrets" "Local environment variants"
  Add-Candidate "*.pem" ".auto-release-probe.pem" '(?i)(^|/)[^/]+\.pem$' "Secrets" "Private certificate material"
  Add-Candidate "*.key" ".auto-release-probe.key" '(?i)(^|/)[^/]+\.key$' "Secrets" "Private key material"
  Add-Candidate "*.p12" ".auto-release-probe.p12" '(?i)(^|/)[^/]+\.p12$' "Secrets" "Signing credential"
  Add-Candidate "*.pfx" ".auto-release-probe.pfx" '(?i)(^|/)[^/]+\.pfx$' "Secrets" "Signing credential"
  Add-Candidate "*.keystore" ".auto-release-probe.keystore" '(?i)(^|/)[^/]+\.keystore$' "Secrets" "Signing credential"
  Add-Candidate "*.jks" ".auto-release-probe.jks" '(?i)(^|/)[^/]+\.jks$' "Secrets" "Java signing credential"
  Add-Candidate ".DS_Store" ".DS_Store" '(?i)(^|/)\.DS_Store$' "OS" "macOS metadata"
  Add-Candidate "Thumbs.db" "Thumbs.db" '(?i)(^|/)Thumbs\.db$' "OS" "Windows thumbnail cache"
  Add-Candidate "desktop.ini" "desktop.ini" '(?i)(^|/)desktop\.ini$' "OS" "Windows folder metadata"
  Add-Candidate ".idea/" ".idea/.auto-release-probe" '(?i)(^|/)\.idea/' "IDE" "JetBrains user-local state"
  Add-Candidate "*.code-workspace" ".auto-release-probe.code-workspace" '(?i)(^|/)[^/]+\.code-workspace$' "IDE" "Editor-local workspace"
  Add-Candidate "output/" "output/.auto-release-probe" '(?i)(^|/)output/' "Build" "Auto Release canonical local output" 1.0 $true "output/"
  if (Test-RootPath ".planning") { Add-Candidate "/.planning/" ".planning/.auto-release-probe" '(?i)^\.planning/' "Agent" "Local agent planning state" }
  if (Test-RootPath ".playwright-cli") { Add-Candidate "/.playwright-cli/" ".playwright-cli/.auto-release-probe" '(?i)^\.playwright-cli/' "Agent" "Local browser automation state" }
  if (Test-RootPath "previews") { Add-Candidate "/previews/" "previews/.auto-release-probe" '(?i)^previews/' "Local" "Local design and preview artifacts" 1.0 $true "previews/" }
}

function Add-ProjectCandidates([string[]]$ProjectTypes) {
  if ($ProjectTypes -contains "node") {
    Add-Candidate "node_modules/" "node_modules/.auto-release-probe" '(?i)(^|/)node_modules/' "Node" "Installed Node.js dependencies"
    Add-Candidate ".pnpm-store/" ".pnpm-store/.auto-release-probe" '(?i)(^|/)\.pnpm-store/' "Node" "pnpm local store"
    Add-Candidate "dist/" "dist/.auto-release-probe" '(?i)(^|/)dist/' "Build" "Frontend or package build output" 1.0 $true "dist/"
    Add-Candidate "coverage/" "coverage/.auto-release-probe" '(?i)(^|/)coverage/' "Test" "Coverage report output"
    Add-Candidate ".vite/" ".vite/.auto-release-probe" '(?i)(^|/)\.vite/' "Node" "Vite cache"
    Add-Candidate ".turbo/" ".turbo/.auto-release-probe" '(?i)(^|/)\.turbo/' "Node" "Turborepo cache"
    Add-Candidate ".cache/" ".cache/.auto-release-probe" '(?i)(^|/)\.cache/' "Build" "Tool cache"
    Add-Candidate "*.tsbuildinfo" ".auto-release-probe.tsbuildinfo" '(?i)(^|/)[^/]+\.tsbuildinfo$' "TypeScript" "TypeScript incremental build state"
    Add-Candidate "npm-debug.log*" "npm-debug.log" '(?i)(^|/)npm-debug\.log' "Logs" "npm debug logs"
    Add-Candidate "yarn-debug.log*" "yarn-debug.log" '(?i)(^|/)yarn-debug\.log' "Logs" "Yarn debug logs"
    Add-Candidate "pnpm-debug.log*" "pnpm-debug.log" '(?i)(^|/)pnpm-debug\.log' "Logs" "pnpm debug logs"
  }
  if ($ProjectTypes -contains "rust" -or $ProjectTypes -contains "tauri") {
    Add-Candidate "target/" "target/.auto-release-probe" '(?i)(^|/)target/' "Rust" "Cargo build output" 1.0 $true "target/"
  }
  if ($ProjectTypes -contains "tauri") {
    Add-Candidate "src-tauri/gen/" "src-tauri/gen/.auto-release-probe" '(?i)^src-tauri/gen/' "Tauri" "Generated mobile project state"
    Add-Candidate "src-tauri/.tauri/" "src-tauri/.tauri/.auto-release-probe" '(?i)^src-tauri/\.tauri/' "Tauri" "Tauri local state"
  }
  if ($ProjectTypes -contains "python") {
    Add-Candidate ".venv/" ".venv/.auto-release-probe" '(?i)(^|/)\.venv/' "Python" "Python virtual environment"
    Add-Candidate "venv/" "venv/.auto-release-probe" '(?i)(^|/)venv/' "Python" "Python virtual environment"
    Add-Candidate "__pycache__/" "__pycache__/.auto-release-probe" '(?i)(^|/)__pycache__/' "Python" "Python bytecode cache"
    Add-Candidate "*.py[cod]" ".auto-release-probe.pyc" '(?i)(^|/)[^/]+\.py[cod]$' "Python" "Python bytecode"
    Add-Candidate ".pytest_cache/" ".pytest_cache/.auto-release-probe" '(?i)(^|/)\.pytest_cache/' "Python" "pytest cache"
    Add-Candidate ".mypy_cache/" ".mypy_cache/.auto-release-probe" '(?i)(^|/)\.mypy_cache/' "Python" "mypy cache"
    Add-Candidate ".ruff_cache/" ".ruff_cache/.auto-release-probe" '(?i)(^|/)\.ruff_cache/' "Python" "Ruff cache"
    Add-Candidate "*.egg-info/" ".auto-release-probe.egg-info/.auto-release-probe" '(?i)(^|/)[^/]+\.egg-info/' "Python" "Python package metadata"
    Add-Candidate "build/" "build/.auto-release-probe" '(?i)(^|/)build/' "Build" "Python build output" 1.0 $true "build/"
  }
  if ($ProjectTypes -contains "dotnet") {
    Add-Candidate "bin/" "bin/.auto-release-probe" '(?i)(^|/)bin/' "DotNet" ".NET build output" 1.0 $true "bin/"
    Add-Candidate "obj/" "obj/.auto-release-probe" '(?i)(^|/)obj/' "DotNet" ".NET intermediate output" 1.0 $true "obj/"
    Add-Candidate ".vs/" ".vs/.auto-release-probe" '(?i)(^|/)\.vs/' "DotNet" "Visual Studio local state"
    Add-Candidate "*.user" ".auto-release-probe.user" '(?i)(^|/)[^/]+\.user$' "DotNet" "Visual Studio user settings"
  }
  if ($ProjectTypes -contains "java" -or $ProjectTypes -contains "android") {
    Add-Candidate ".gradle/" ".gradle/.auto-release-probe" '(?i)(^|/)\.gradle/' "Gradle" "Gradle cache"
    Add-Candidate "build/" "build/.auto-release-probe" '(?i)(^|/)build/' "Build" "Gradle build output" 1.0 $true "build/"
  }
  if ($ProjectTypes -contains "android") {
    Add-Candidate "local.properties" "local.properties" '(?i)(^|/)local\.properties$' "Android" "Machine-specific Android SDK path"
    Add-Candidate ".cxx/" ".cxx/.auto-release-probe" '(?i)(^|/)\.cxx/' "Android" "Android native build output"
  }
  if ($ProjectTypes -contains "cmake") {
    Add-Candidate "cmake-build-*/" "cmake-build-debug/.auto-release-probe" '(?i)(^|/)cmake-build-[^/]+/' "CMake" "CMake IDE build directory"
    Add-Candidate "CMakeFiles/" "CMakeFiles/.auto-release-probe" '(?i)(^|/)CMakeFiles/' "CMake" "CMake generated state"
    Add-Candidate "CMakeCache.txt" "CMakeCache.txt" '(?i)(^|/)CMakeCache\.txt$' "CMake" "CMake generated cache"
  }
  if ($ProjectTypes -contains "flutter") {
    Add-Candidate ".dart_tool/" ".dart_tool/.auto-release-probe" '(?i)(^|/)\.dart_tool/' "Flutter" "Dart tool state"
    Add-Candidate ".flutter-plugins" ".flutter-plugins" '(?i)(^|/)\.flutter-plugins$' "Flutter" "Generated Flutter plugin list"
    Add-Candidate ".flutter-plugins-dependencies" ".flutter-plugins-dependencies" '(?i)(^|/)\.flutter-plugins-dependencies$' "Flutter" "Generated Flutter plugin metadata"
    Add-Candidate "build/" "build/.auto-release-probe" '(?i)(^|/)build/' "Build" "Flutter build output" 1.0 $true "build/"
  }
  if ($ProjectTypes -contains "electron") {
    Add-Candidate "out/" "out/.auto-release-probe" '(?i)(^|/)out/' "Electron" "Electron build output" 1.0 $true "out/"
    Add-Candidate "release/" "release/.auto-release-probe" '(?i)(^|/)release/' "Electron" "Electron package output" 1.0 $true "release/"
  }
}

function Test-PathMatches($Candidate, [string]$Path) {
  return [regex]::IsMatch($Path.Replace("\", "/"), [string]$Candidate.matchRegex)
}

function Test-IsIgnored([string]$Path) {
  $result = Invoke-GitCaptured @("check-ignore", "-v", "--no-index", "--", $Path) $true
  if ($result.ExitCode -notin @(0, 1)) { throw "git check-ignore failed for: $Path" }
  if ($result.ExitCode -eq 1) { return $false }
  $lastLine = @($result.Output -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 1
  if ($lastLine -match '^.*?:\d+:(?<pattern>[^\t]+)\t') {
    return -not $Matches.pattern.StartsWith("!")
  }
  return $true
}

function Test-CandidateReferenced($Candidate) {
  $token = [string]$Candidate.referenceToken
  if ([string]::IsNullOrWhiteSpace($token)) { return $false }
  $result = Invoke-GitCaptured @("grep", "-n", "-I", "-F", "--", $token) $true
  if ($result.ExitCode -eq 1) { return $false }
  if ($result.ExitCode -ne 0) { return $true }
  foreach ($line in @($result.Output -split "`r?`n" | Where-Object { $_ })) {
    $sourcePath = ($line -split ':', 2)[0].Replace("\", "/")
    if ($sourcePath -eq ".gitignore") { continue }
    if (-not (Test-PathMatches $Candidate $sourcePath)) { return $true }
  }
  return $false
}

function Get-ProtectedPaths([string[]]$TrackedPaths) {
  $pattern = '(?i)(^|/)(?:package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|Cargo\.lock|go\.sum|poetry\.lock|uv\.lock|Pipfile\.lock|gradle\.lockfile|\.codex-release\.json)$|(?i)^\.github/workflows/'
  return @($TrackedPaths | Where-Object { $_ -match $pattern } | Sort-Object -Unique)
}

function Get-SensitivePaths([string[]]$Paths) {
  return @($Paths | Where-Object {
    $leaf = [IO.Path]::GetFileName($_)
    $isExample = $leaf -match '(?i)(?:\.example|\.sample|\.template)$'
    -not $isExample -and $_ -match '(?i)(^|/)(?:\.env(?:\..+)?|id_(?:rsa|dsa|ecdsa|ed25519)|[^/]+\.(?:pem|p12|pfx|key|keystore|jks))$'
  } | Sort-Object -Unique)
}

function Get-HistoricalGeneratedPaths($Candidates) {
  $result = Invoke-GitCaptured @("rev-list", "--objects", "--all") $true
  if ($result.ExitCode -ne 0) { return @() }
  $paths = @()
  foreach ($line in @($result.Output -split "`r?`n" | Where-Object { $_ -match '^[0-9a-f]+\s+' })) {
    $path = ($line -replace '^[0-9a-f]+\s+', '').Replace("\", "/")
    foreach ($candidate in $Candidates) {
      if (Test-PathMatches $candidate $path) { $paths += $path; break }
    }
    if ($paths.Count -ge 200) { break }
  }
  return @($paths | Sort-Object -Unique)
}

function New-IgnorePlan {
  $script:Candidates = @()
  $script:CandidatePatterns = @{}
  $projectTypes = @(Get-DetectedProjectTypes)
  Add-CommonCandidates
  Add-ProjectCandidates $projectTypes
  $trackedPaths = @(((Invoke-GitCaptured @("ls-files")).Output -split "`r?`n" | Where-Object { $_ }) | ForEach-Object { $_.Replace("\", "/") })
  $untrackedPaths = @(((Invoke-GitCaptured @("ls-files", "--others", "--exclude-standard")).Output -split "`r?`n" | Where-Object { $_ }) | ForEach-Object { $_.Replace("\", "/") })
  $currentPaths = @($trackedPaths + $untrackedPaths | Sort-Object -Unique)
  $rules = @()
  $alreadyCovered = @()
  $review = @()
  $untrackPaths = @()
  foreach ($candidate in $script:Candidates) {
    $trackedMatches = @($trackedPaths | Where-Object { Test-PathMatches $candidate $_ })
    $untrackedMatches = @($untrackedPaths | Where-Object { Test-PathMatches $candidate $_ })
    $referenced = if ($trackedMatches.Count -gt 0) { Test-CandidateReferenced $candidate } else { $false }
    $classification = if ([double]$candidate.confidence -lt 0.8) {
      "review"
    }
    elseif ($trackedMatches.Count -gt 0 -and (-not [bool]$candidate.allowTrackedIfUnreferenced -or $referenced)) {
      "review"
    }
    else {
      "safe"
    }
    $covered = Test-IsIgnored ([string]$candidate.samplePath)
    $matchedBytes = [long]0
    foreach ($matchPath in @($trackedMatches + $untrackedMatches | Sort-Object -Unique)) {
      $fullPath = Join-Path $script:Root $matchPath
      if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $matchedBytes += (Get-Item -LiteralPath $fullPath).Length }
    }
    $record = [pscustomobject][ordered]@{
      pattern = [string]$candidate.pattern
      samplePath = [string]$candidate.samplePath
      category = [string]$candidate.category
      reason = [string]$candidate.reason
      confidence = [double]$candidate.confidence
      trackedMatches = $trackedMatches
      untrackedMatches = $untrackedMatches
      matchedBytes = $matchedBytes
      referenced = $referenced
    }
    if ($classification -eq "safe") {
      $untrackPaths += $trackedMatches
      if ($covered) { $alreadyCovered += $record } else { $rules += $record }
    }
    else {
      $review += $record
    }
  }
  $ignoreFiles = @($trackedPaths + $untrackedPaths | Where-Object { [IO.Path]::GetFileName($_) -eq ".gitignore" } | Sort-Object -Unique)
  $sensitivePaths = @(Get-SensitivePaths $currentPaths)
  return [pscustomobject][ordered]@{
    schemaVersion = 1
    baseHead = (Invoke-GitCaptured @("rev-parse", "HEAD")).Output
    worktreeFingerprint = Get-WorktreeFingerprint
    repositoryRoot = $script:Root
    ignoreFile = ".gitignore"
    detectedProjectTypes = $projectTypes
    ignoreFiles = $ignoreFiles
    rules = $rules
    alreadyCovered = $alreadyCovered
    review = $review
    untrackPaths = @($untrackPaths | Sort-Object -Unique)
    sensitivePaths = $sensitivePaths
    protectedPaths = @(Get-ProtectedPaths $trackedPaths)
    historicalGeneratedPaths = @(Get-HistoricalGeneratedPaths $script:Candidates)
  }
}

function Write-AtomicText([string]$Path, [string]$Text) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $temporary = Join-Path $directory (".auto-release-" + [guid]::NewGuid().ToString("N") + ".tmp")
  try {
    [IO.File]::WriteAllText($temporary, $Text, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
  }
  finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
  }
}

function Save-Plan($Plan) {
  $path = Get-ResolvedPlanPath
  Write-AtomicText $path (($Plan | ConvertTo-Json -Depth 20) + "`n")
  return $path
}

function Read-Plan {
  $path = Get-ResolvedPlanPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Ignore plan not found; run Ignore Audit first: $path" }
  try { $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json }
  catch { throw "Ignore plan is invalid JSON: $path" }
  if ([int]$plan.schemaVersion -ne 1) { throw "Ignore plan schemaVersion must be 1" }
  if ([string]$plan.baseHead -ne (Invoke-GitCaptured @("rev-parse", "HEAD")).Output) { throw "Ignore plan baseHead is stale; run Audit again" }
  if ([string]$plan.worktreeFingerprint -ne (Get-WorktreeFingerprint)) { throw "Ignore plan worktree fingerprint is stale; run Audit again" }
  return $plan
}

function Backup-Index {
  $indexPath = Join-Path $script:GitDirectory "index"
  return [pscustomobject]@{
    path = $indexPath
    exists = Test-Path -LiteralPath $indexPath -PathType Leaf
    bytes = if (Test-Path -LiteralPath $indexPath -PathType Leaf) { [IO.File]::ReadAllBytes($indexPath) } else { $null }
  }
}

function Restore-Index($Backup) {
  if ($Backup.exists) { [IO.File]::WriteAllBytes([string]$Backup.path, [byte[]]$Backup.bytes) }
  elseif (Test-Path -LiteralPath ([string]$Backup.path) -PathType Leaf) { Remove-Item -LiteralPath ([string]$Backup.path) -Force }
}

function Get-ManagedIgnoreText($Plan, [string]$ExistingText) {
  $beginCount = ([regex]::Matches($ExistingText, [regex]::Escape($script:BeginMarker))).Count
  $endCount = ([regex]::Matches($ExistingText, [regex]::Escape($script:EndMarker))).Count
  if ($beginCount -ne $endCount -or $beginCount -gt 1) { throw "Malformed Auto Release managed ignore markers" }
  $patternsByCategory = [ordered]@{}
  foreach ($rule in @($Plan.rules)) {
    $category = [string]$rule.category
    if (-not $patternsByCategory.Contains($category)) { $patternsByCategory[$category] = @() }
    $patternsByCategory[$category] += [string]$rule.pattern
  }
  $rulePatterns = @($Plan.rules | ForEach-Object { [string]$_.pattern })
  if ($rulePatterns -contains ".env" -or $rulePatterns -contains ".env.*") {
    if (-not $patternsByCategory.Contains("Secrets")) { $patternsByCategory["Secrets"] = @() }
    $patternsByCategory["Secrets"] += "!.env.example"
  }
  $existingLines = @{}
  foreach ($line in @($ExistingText -split "`r?`n")) { $existingLines[$line.Trim()] = $true }
  $addition = @()
  foreach ($category in $patternsByCategory.Keys) {
    $uniquePatterns = @($patternsByCategory[$category] | Sort-Object -Unique)
    $orderedPatterns = @($uniquePatterns | Where-Object { -not $_.StartsWith("!") }) + @($uniquePatterns | Where-Object { $_.StartsWith("!") })
    $missingPatterns = @($orderedPatterns | Where-Object { -not $existingLines.ContainsKey($_) })
    if ($missingPatterns.Count -eq 0) { continue }
    $addition += ""
    $addition += "# $category"
    $addition += $missingPatterns
  }
  if ($beginCount -eq 1) {
    if ($addition.Count -eq 0) { return $ExistingText }
    $replacement = (($addition -join "`n") + "`n" + $script:EndMarker)
    return $ExistingText.Replace($script:EndMarker, $replacement)
  }
  $body = @($script:BeginMarker) + $addition + @($script:EndMarker)
  $block = $body -join "`n"
  $trimmed = $ExistingText.TrimEnd("`r", "`n")
  if ($trimmed) { return "$trimmed`n`n$block`n" }
  return "$block`n"
}

function Get-FileSnapshot([string[]]$Paths) {
  $records = @()
  foreach ($path in @($Paths | Sort-Object -Unique)) {
    $fullPath = Join-Path $script:Root $path
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
      $records += [pscustomobject]@{ path = $path; hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash }
    }
  }
  return $records
}

function Assert-FileSnapshot($Snapshot) {
  foreach ($record in @($Snapshot)) {
    $fullPath = Join-Path $script:Root ([string]$record.path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Local file was removed while untracking: $($record.path)" }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash -ne [string]$record.hash) {
      throw "Local file changed while untracking: $($record.path)"
    }
  }
}

function Apply-Plan($Plan, [bool]$Untrack) {
  if (@($Plan.sensitivePaths).Count -gt 0) {
    throw "Sensitive files require manual review before ignore rules can be applied: $(@($Plan.sensitivePaths) -join ', ')"
  }
  $ignorePath = Join-Path $script:Root ".gitignore"
  $ignoreExists = Test-Path -LiteralPath $ignorePath -PathType Leaf
  $ignoreBytes = if ($ignoreExists) { [IO.File]::ReadAllBytes($ignorePath) } else { $null }
  $existingText = if ($ignoreExists) { [IO.File]::ReadAllText($ignorePath) } else { "" }
  $indexBackup = Backup-Index
  $protectedBefore = @{}
  foreach ($path in @($Plan.protectedPaths)) { $protectedBefore[[string]$path] = Test-IsIgnored ([string]$path) }
  $localSnapshot = Get-FileSnapshot @($Plan.untrackPaths)
  $rulesAdded = @($Plan.rules | ForEach-Object { [string]$_.pattern })
  try {
    if ($rulesAdded.Count -gt 0) {
      $updatedText = Get-ManagedIgnoreText $Plan $existingText
      Write-AtomicText $ignorePath $updatedText
    }
    foreach ($rule in @($Plan.rules)) {
      if (-not (Test-IsIgnored ([string]$rule.samplePath))) {
        throw "Applied ignore rule did not match its probe: $($rule.pattern)"
      }
    }
    foreach ($path in @($Plan.protectedPaths)) {
      $wasIgnored = [bool]$protectedBefore[[string]$path]
      if (-not $wasIgnored -and (Test-IsIgnored ([string]$path))) {
        throw "New ignore rules unexpectedly hide a protected path: $path"
      }
    }
    if ($Untrack) {
      foreach ($path in @($Plan.untrackPaths)) {
        Invoke-GitChecked @("rm", "--cached", "--ignore-unmatch", "--", [string]$path)
      }
      Assert-FileSnapshot $localSnapshot
    }
    $diffCheck = Invoke-GitCaptured @("diff", "--check") $true
    if ($diffCheck.ExitCode -ne 0) { throw "git diff --check failed: $($diffCheck.Output)" }
  }
  catch {
    if ($ignoreExists) { [IO.File]::WriteAllBytes($ignorePath, [byte[]]$ignoreBytes) }
    elseif (Test-Path -LiteralPath $ignorePath -PathType Leaf) { Remove-Item -LiteralPath $ignorePath -Force }
    Restore-Index $indexBackup
    throw
  }
  return [pscustomobject][ordered]@{
    operation = "Ignore"
    status = "succeeded"
    mode = if ($Untrack) { "ApplyAndUntrack" } else { "Apply" }
    planPath = Get-ResolvedPlanPath
    rulesAdded = $rulesAdded
    untrackedPaths = if ($Untrack) { @($Plan.untrackPaths) } else { @() }
    review = @($Plan.review)
  }
}

function Write-HumanPlan($Plan, [string]$Path) {
  Write-Host "Ignore audit: $script:Root"
  Write-Host "Project types: $(@($Plan.detectedProjectTypes) -join ', ')"
  Write-Host "Plan: $Path"
  foreach ($rule in @($Plan.rules)) { Write-Host "Add: $($rule.pattern) - $($rule.reason)" }
  foreach ($item in @($Plan.review)) { Write-Host "Review: $($item.pattern) - $($item.reason)" }
  foreach ($pathValue in @($Plan.untrackPaths)) { Write-Host "Tracked match: $pathValue" }
  foreach ($pathValue in @($Plan.sensitivePaths)) { Write-Host "Sensitive: $pathValue" }
  if (@($Plan.rules).Count -eq 0) { Write-Host "No high-confidence ignore rules are missing" }
}

function Write-Result($Result) {
  if ($OutputFormat -eq "Json") { Write-Output ($Result | ConvertTo-Json -Depth 20 -Compress) }
}

Initialize-Context
if ($Mode -eq "Audit") {
  $plan = New-IgnorePlan
  $resolvedPlanPath = Get-ResolvedPlanPath
  if (-not $NoWritePlan) { $resolvedPlanPath = Save-Plan $plan }
  $result = [pscustomobject][ordered]@{
    operation = "Ignore"
    status = "planned"
    mode = "Audit"
    whatIf = [bool]$NoWritePlan
    planPath = $resolvedPlanPath
    plan = $plan
  }
  if ($OutputFormat -eq "Human") { Write-HumanPlan $plan $resolvedPlanPath }
  Write-Result $result
  return
}

$plan = Read-Plan
$result = Apply-Plan $plan ($Mode -eq "ApplyAndUntrack")
if ($OutputFormat -eq "Human") {
  Write-Host "Ignore $Mode completed"
  Write-Host "Rules added: $(@($result.rulesAdded).Count)"
  Write-Host "Paths untracked: $(@($result.untrackedPaths).Count)"
}
Write-Result $result
