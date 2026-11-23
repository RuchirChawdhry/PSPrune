function Invoke-PSPrunePester {
    param(
        [string]$ProjectRoot,
        [string]$RelativeTestPath,
        [string]$RelativeTargetPath,
        [string]$Replacement,
        [ValidateRange(5, 3600)][int]$TimeoutSeconds = 300
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('psprune-suite-' + [guid]::NewGuid().ToString('N'))
    $isolated = Join-Path $scratch 'project'
    $null = New-Item -ItemType Directory -Path $isolated -Force
    try {
        foreach ($entry in Get-ChildItem -LiteralPath $ProjectRoot -Force) {
            if ($entry.Name -in '.git', '.psprune') { continue }
            Copy-Item -LiteralPath $entry.FullName -Destination $isolated -Recurse -Force
        }
        $target = Join-Path $isolated $RelativeTargetPath
        if ($PSBoundParameters.ContainsKey('Replacement')) {
            [IO.File]::WriteAllText($target, $Replacement, [Text.UTF8Encoding]::new($false))
        }
        $tests = Join-Path $isolated $RelativeTestPath
        $runner = Join-Path $scratch 'run-tests.ps1'
        [IO.File]::WriteAllText($runner, @'
param([Parameter(Mandatory)][string]$TestPath)
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion '6.2.0' -ErrorAction Stop
$config = New-PesterConfiguration
$config.Run.Path = $TestPath
$config.Run.PassThru = $true
$config.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $config
if ($result.Result -ne 'Passed' -or $result.PassedCount -eq 0) { exit 1 }
'@, [Text.UTF8Encoding]::new($false))
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop |
            Select-Object -First 1).Source
        $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $runner, '-TestPath', $tests)) {
            $start.ArgumentList.Add($argument)
        }
        $start.WorkingDirectory = $isolated
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
            if ($timedOut) {
                if (-not $process.HasExited) { $process.Kill($true) }
                $process.WaitForExit()
            }
            $exitCode = $process.ExitCode
            $output = @($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) -join [Environment]::NewLine
            $watch.Stop()
            [pscustomobject]@{
                Passed = -not $timedOut -and $exitCode -eq 0
                Error = if ($timedOut) {
                    "Pester exceeded $TimeoutSeconds seconds and its process tree was terminated."
                }
                elseif ($exitCode -ne 0) { $output.Substring(0, [Math]::Min(4000, $output.Length)) }
                else { $null }
                DurationMs = $watch.ElapsedMilliseconds
                TimedOut = $timedOut
            }
        }
        finally { $process.Dispose() }
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

function Invoke-PSPruneBatch {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$ProjectPath = '.',
        [switch]$Apply
    )
    Assert-PSPruneId -Id $Id
    $root = Get-PSPruneRoot -Path $ProjectPath
    $batchDir = Get-PSPruneBatchPath -Root $root -Id $Id
    $batchManifest = Join-Path $batchDir 'manifest.json'
    $batch = Get-PSPruneJson -Path $batchManifest
    if ($batch.status -ne 'open') { throw "Batch '$Id' is already finalized." }

    $target = Join-Path $root $batch.target.file
    if ((Get-PSPruneFileDigest -Path $target) -cne $batch.target.file_sha256) {
        throw 'Original source changed after batch creation. Refusing stale batch.'
    }
    $source = [IO.File]::ReadAllText($target)
    $definition = Get-PSPruneAst -Source $source -FunctionName $batch.target.function
    if ((Get-PSPruneDigest -Text $definition.Extent.Text) -cne $batch.target.source_sha256) {
        throw 'Original function fingerprint changed after batch creation.'
    }
    $paths = @(1..5 | ForEach-Object { Join-Path $batchDir "candidate-$_.ps1" })
    $modeLabel = if ($batch.mode -eq 'Split') { 'Split ' } else { '' }
    foreach ($candidatePath in $paths) {
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            throw "Incomplete ${modeLabel}batch: missing $candidatePath"
        }
    }

    $timeout = if ($batch.test_timeout_seconds) { [int]$batch.test_timeout_seconds } else { 300 }
    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop

    $results = [Collections.Generic.List[object]]::new()
    $replacements = @{}
    if ($batch.mode -eq 'Split') { Import-Module PSScriptAnalyzer -ErrorAction Stop }

    for ($index = 1; $index -le 5; $index++) {
        if ($batch.mode -eq 'Split') {
            $evaluation = Measure-PSPruneSplitCandidate -Path $paths[$index - 1] -Slot $index -Batch $batch -Root $root -Source $source -Definition $definition
            $results.Add($evaluation.Result)
            $replacements[$index] = $evaluation.Replacement
            continue
        }
        $candidatePath = $paths[$index - 1]
        $candidateSource = [IO.File]::ReadAllText($candidatePath)
        $cognitive = $null
        $cyclomatic = $null
        $errorMessage = $null
        $scoreWatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $candidateAst = Get-PSPruneAst -Source $candidateSource -FunctionName $batch.target.function -SingleFunction
            if ((Get-PSPruneSignature -FunctionAst $candidateAst) -cne $batch.target.signature) {
                throw 'Candidate signature does not match original.'
            }
            $replacement = $source.Substring(0, $definition.Extent.StartOffset) +
                $candidateSource.TrimEnd() +
                $source.Substring($definition.Extent.EndOffset)
            $scoring = Join-Path ([IO.Path]::GetTempPath()) ('psprune-score-' + [guid]::NewGuid().ToString('N') + '.ps1')
            try {
                [IO.File]::WriteAllText($scoring, $replacement, [Text.UTF8Encoding]::new($false))
                $scores = @(Measure-PSComplexity -Path $scoring -ErrorAction Stop |
                    Where-Object Unit -eq $batch.target.function)
                if ($scores.Count -ne 1) { throw 'Could not measure candidate uniquely.' }
                $cognitive = [int]$scores[0].Cognitive
                $cyclomatic = [int]$scores[0].Cyclomatic
            }
            finally {
                if (Test-Path -LiteralPath $scoring) { Remove-Item -LiteralPath $scoring -Force }
            }
            $replacements[$index] = $replacement
        }
        catch { $errorMessage = $_.Exception.Message }
        $scoreWatch.Stop()
        $eligible = $null -eq $errorMessage -and (
            $cognitive -lt $batch.original.cognitive -or (
                $cognitive -eq $batch.original.cognitive -and
                $cyclomatic -lt $batch.original.cyclomatic
            )
        )
        $results.Add([pscustomobject]@{
            slot = $index
            sha256 = Get-PSPruneFileDigest -Path $candidatePath
            passed = $null
            tested = $false
            eligible = [bool]$eligible
            cyclomatic = $cyclomatic
            cognitive = $cognitive
            score_duration_ms = $scoreWatch.ElapsedMilliseconds
            test_duration_ms = $null
            regression_passed = $null
            regression_duration_ms = $null
            error = $errorMessage
        })
    }

    $sortBy = @('cognitive', 'cyclomatic', 'slot')
    if ($batch.mode -eq 'Split') {
        $sortBy = @('concentration_score', 'max_cognitive', 'helper_count', 'slot')
    }

    $winner = $null
    $eligibleCandidates = @($results | Where-Object eligible |
        Sort-Object -Property $sortBy)
    foreach ($proposal in $eligibleCandidates) {
        $test = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.test_path -RelativeTargetPath $batch.target.file -Replacement $replacements[$proposal.slot] -TimeoutSeconds $timeout
        $proposal.tested = $true
        $proposal.passed = $test.Passed
        $proposal.test_duration_ms = $test.DurationMs
        if (-not $test.Passed) {
            $proposal.eligible = $false
            $proposal.error = "Focused Pester failed: $($test.Error)"
            continue
        }

        if ($batch.regression_test_path) {
            $verified = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.regression_test_path -RelativeTargetPath $batch.target.file -Replacement $replacements[$proposal.slot] -TimeoutSeconds $timeout
            $proposal.regression_passed = $verified.Passed
            $proposal.regression_duration_ms = $verified.DurationMs
            if (-not $verified.Passed) {
                $proposal.eligible = $false
                $proposal.error = "Full regression failed: $($verified.Error)"
                continue
            }
        }
        $winner = $proposal
        break
    }
    $replacement = if ($winner) { $replacements[$winner.slot] } else { $null }
    Complete-PSPruneBatch -Batch $batch -Root $root -Candidates $results.ToArray() -Winner $winner -Replacement $replacement -Apply:$Apply
}

function Complete-PSPruneBatch {
    param(
        [Parameter(Mandatory)]$Batch,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Candidates,
        $Winner,
        [string]$Replacement,
        [switch]$Apply
    )

    $id = $Batch.id
    $store = Get-PSPruneStore -Root $Root
    $target = Join-Path $Root $Batch.target.file
    $workingManifest = Join-Path (Get-PSPruneBatchPath -Root $Root -Id $id) 'manifest.json'
    $tested = @($Candidates | Where-Object tested)
    $improved = $null -ne $Winner

    $record = [ordered]@{
        id = $id
        created_at = $Batch.created_at
        completed_at = [DateTime]::UtcNow.ToString('o')
        status = if (-not $improved) { 'rejected' } elseif ($Apply) { 'applied' } else { 'evaluated' }
        target = [ordered]@{
            file = $Batch.target.file
            function = $Batch.target.function
            source_sha256 = $Batch.target.source_sha256
            file_sha256 = $Batch.target.file_sha256
        }
        original = $Batch.original
        validation = [ordered]@{
            runner = 'Pester'
            test_path = $Batch.test_path
            regression_test_path = $Batch.regression_test_path
            baseline_passed = if ($Batch.mode -eq 'Split') { $true } else { $null }
            all_passed = $null
            tested_count = $tested.Count
            winner_passed = [bool]$Winner
            test_discovery = $Batch.test_discovery
            winner_regression_passed = if ($Batch.regression_test_path) { [bool]$Winner } else { $null }
            regression_attempt_count = @($Candidates | Where-Object { $null -ne $_.regression_passed }).Count
        }
        candidates = @($Candidates)
        selected_slot = if ($improved) { $Winner.slot } else { $null }
        improved = [bool]$improved
        applied = $false
    }

    if ($Batch.mode -eq 'Split') { $record.Insert(1, 'mode', 'Split') }

    $lock = Enter-PSPruneLock -Store $store
    try {
        $working = Get-PSPruneJson -Path $workingManifest
        if ($working.status -ne 'open') { throw "Batch '$id' has already been finalized." }
        if ((Get-PSPruneFileDigest -Path $target) -cne $Batch.target.file_sha256) {
            throw 'Source changed during candidate evaluation.'
        }
        $masterPath = Get-PSPruneMasterPath -Root $Root
        $master = Get-PSPruneJson -Path $masterPath
        if ($master.batches -and $master.batches.id -contains $id) {
            throw "Batch '$id' already exists in master history."
        }

        if ($Apply -and $improved) {
            $temp = Join-Path (Split-Path $target -Parent) (
                '.psprune-apply-' + [guid]::NewGuid().ToString('N')
            )
            try {
                [IO.File]::WriteAllText($temp, $Replacement, [Text.UTF8Encoding]::new($false))
                [IO.File]::Move($temp, $target, $true)
            }
            finally {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
            }
            $record.applied = $true
        }

        $master.batches = @($master.batches) + @([pscustomobject]$record)
        Save-PSPruneJson -Path $masterPath -Value $master
        $working.status = $record.status
        $working | Add-Member -NotePropertyName completed_at -NotePropertyValue $record.completed_at -Force
        $working | Add-Member -NotePropertyName selected_slot -NotePropertyValue $record.selected_slot -Force
        $working | Add-Member -NotePropertyName applied -NotePropertyValue $record.applied -Force
        Save-PSPruneJson -Path $workingManifest -Value $working
        Get-PSPruneHistory -Path $Root | Where-Object Id -eq $id
    }
    finally { $lock.Dispose() }
}
