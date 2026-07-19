$ErrorActionPreference = "Stop"

function Select-WorkflowRun {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Json,

    [Parameter(Mandatory)]
    [string]$Tag,

    [Parameter(Mandatory)]
    [string]$HeadSha
  )

  $parsed = ConvertFrom-Json -InputObject $Json
  foreach ($candidate in $parsed) {
    if ($candidate.headBranch -eq $Tag -and $candidate.headSha -eq $HeadSha) {
      return $candidate
    }
  }
  return $null
}

function Get-WorkflowRunSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Run
  )

  $jobs = @($Run.jobs)
  $failedJobs = @(
    $jobs | Where-Object {
      $_.status -eq "completed" -and
      $_.conclusion -notin @("success", "skipped")
    }
  )
  $jobSignature = @(
    $jobs | Sort-Object name | ForEach-Object {
      "$($_.name):$($_.status):$($_.conclusion)"
    }
  ) -join "|"
  $signature = "$($Run.status):$($Run.conclusion):$jobSignature"

  if ($failedJobs.Count -gt 0) {
    $failed = $failedJobs[0]
    return [pscustomobject]@{
      State = "Failed"
      Signature = $signature
      Message = "Workflow failed: $($failed.name) ($($failed.conclusion))"
    }
  }
  if ($Run.status -eq "completed" -and $Run.conclusion -eq "success") {
    return [pscustomobject]@{
      State = "Succeeded"
      Signature = $signature
      Message = "Workflow completed successfully"
    }
  }
  if ($Run.status -eq "completed") {
    return [pscustomobject]@{
      State = "Failed"
      Signature = $signature
      Message = "Workflow completed with conclusion $($Run.conclusion)"
    }
  }

  $activeJobs = @(
    $jobs |
      Where-Object { $_.status -ne "completed" } |
      ForEach-Object { $_.name }
  )
  return [pscustomobject]@{
    State = "Waiting"
    Signature = $signature
    Message = "Workflow $($Run.status): $($activeJobs -join ', ')"
  }
}

function Test-WorkflowSnapshotChanged {
  [CmdletBinding()]
  param(
    [AllowNull()]
    [string]$PreviousSignature,

    [Parameter(Mandatory)]
    [object]$Snapshot
  )

  return $PreviousSignature -ne $Snapshot.Signature
}

function Assert-ReleaseNotes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ReleaseNotes,

    [Parameter(Mandatory)]
    [string]$Heading,

    [int]$MinItems = 2,

    [int]$MaxItems = 6,

    [bool]$RequireChinese = $false
  )

  if ($MinItems -lt 1 -or $MaxItems -lt $MinItems) {
    throw "Invalid release-note item limits"
  }
  $headingPattern = '(?m)^' + [regex]::Escape($Heading) + '\s*$'
  if ($ReleaseNotes -notmatch $headingPattern) {
    throw "Release notes must contain heading: $Heading"
  }
  if ($RequireChinese -and $ReleaseNotes -notmatch '[\u4e00-\u9fff]') {
    throw "Release notes must contain Chinese content"
  }
  $items = [regex]::Matches($ReleaseNotes, '(?m)^-\s+\S.*$')
  if ($items.Count -lt $MinItems -or $items.Count -gt $MaxItems) {
    throw "Release notes must contain $MinItems to $MaxItems key points"
  }
  if ($RequireChinese) {
    foreach ($item in $items) {
      if ($item.Value -notmatch '[\u4e00-\u9fff]') {
        throw "Each release-note key point must contain Chinese"
      }
    }
  }
}

function Stop-ReleaseProcessTree([Diagnostics.Process]$Process) {
  if (-not $Process -or $Process.HasExited) {
    return
  }
  try {
    $taskkillOutput = & "$env:SystemRoot\System32\taskkill.exe" /PID $Process.Id /T /F 2>&1
    if ($LASTEXITCODE -ne 0) {
      $Process.Refresh()
      if (-not $Process.HasExited) {
        throw "taskkill failed for PID $($Process.Id): $($taskkillOutput -join ' ')"
      }
    }
  }
  catch {
    $Process.Refresh()
    if (-not $Process.HasExited) {
      $Process.Kill()
    }
  }
  if (-not $Process.HasExited) {
    if (-not $Process.WaitForExit(5000)) {
      throw "Timed out stopping release process PID $($Process.Id)"
    }
  }
}

function Start-ReleaseProcess($Command, [string]$WorkingDirectory) {
  if (-not $env:ComSpec) {
    throw "Parallel release commands require Windows cmd.exe"
  }

  $commandBytes = [Text.Encoding]::UTF8.GetBytes([string]$Command.command)
  $commandBase64 = [Convert]::ToBase64String($commandBytes)
  $runner =
    '$command = [Text.Encoding]::UTF8.GetString(' +
    '[Convert]::FromBase64String("' + $commandBase64 + '")); ' +
    '& $env:ComSpec /d /s /c $command; exit $LASTEXITCODE'
  $encodedRunner = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runner))

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = (Get-Process -Id $PID).Path
  $startInfo.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encodedRunner"
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Failed to start $($Command.name)"
  }
  return [pscustomobject]@{
    Name = [string]$Command.name
    Process = $process
    Stdout = $process.StandardOutput.ReadToEndAsync()
    Stderr = $process.StandardError.ReadToEndAsync()
  }
}

function Invoke-ParallelShellChecked {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Commands,

    [Parameter(Mandatory)]
    [string]$WorkingDirectory
  )

  $entries = @()
  $failedEntry = $null

  try {
    foreach ($command in $Commands) {
      $entries += Start-ReleaseProcess -Command $command -WorkingDirectory $WorkingDirectory
    }

    while ($true) {
      foreach ($entry in $entries) {
        if ($entry.Process.HasExited) {
          $entry.Process.WaitForExit()
          if ($entry.Process.ExitCode -ne 0) {
            $failedEntry = $entry
            break
          }
        }
      }
      if ($failedEntry) {
        foreach ($entry in $entries) {
          if ($entry -ne $failedEntry) {
            Stop-ReleaseProcessTree $entry.Process
          }
        }
        break
      }
      if (@($entries | Where-Object { -not $_.Process.HasExited }).Count -eq 0) {
        break
      }
      Start-Sleep -Milliseconds 100
    }

    foreach ($entry in $entries) {
      $entry.Process.WaitForExit()
    }
    if ($failedEntry) {
      $out = $failedEntry.Stdout.Result
      $err = $failedEntry.Stderr.Result
      $separator = [Environment]::NewLine
      throw "$($failedEntry.Name) failed with exit code $($failedEntry.Process.ExitCode):$separator$out$separator$err"
    }
    foreach ($entry in $entries) {
      Write-Host "$($entry.Name) completed"
    }
  }
  finally {
    foreach ($entry in $entries) {
      Stop-ReleaseProcessTree $entry.Process
      $entry.Process.Dispose()
    }
  }
}

function Invoke-SequentialShellChecked {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Commands,

    [Parameter(Mandatory)]
    [string]$WorkingDirectory
  )

  if (-not $env:ComSpec) {
    throw "Release commands require Windows cmd.exe"
  }

  $previousLocation = Get-Location
  try {
    Set-Location -LiteralPath $WorkingDirectory
    foreach ($command in $Commands) {
      Write-Host "Running $($command.name)"
      & $env:ComSpec /d /s /c ([string]$command.command)
      if ($LASTEXITCODE -ne 0) {
        throw "$($command.name) failed with exit code $LASTEXITCODE"
      }
    }
  }
  finally {
    Set-Location -LiteralPath $previousLocation
  }
}
