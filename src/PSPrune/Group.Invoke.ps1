function Measure-PSPruneSplitCandidate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Slot,
        [Parameter(Mandatory)]$Batch,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)]$Definition
    )

    $text = [IO.File]::ReadAllText($Path)
    $result = [ordered]@{
        slot = $Slot
        sha256 = Get-PSPruneFileDigest -Path $Path
        passed = $null
        tested = $false
        eligible = $false
        total_cognitive = $null
        concentration_score = $null
        max_cognitive = $null
        adjusted_cyclomatic = $null
        helper_count = $null
        functions = @()
        score_duration_ms = $null
        test_duration_ms = $null
        regression_passed = $null
        regression_duration_ms = $null
        error = $null
    }

    try {
        $scoreWatch = [Diagnostics.Stopwatch]::StartNew()
        $group = Get-PSPruneGroup -Source $text -FunctionName $Batch.target.function
        Assert-PSPruneSplitBoundary -Group $group -Batch $Batch -Root $Root -Source $Source
        $replacement = $Source.Substring(0, $Definition.Extent.StartOffset) +
            $text.TrimEnd() +
            $Source.Substring($Definition.Extent.EndOffset)
        $temporary = Join-Path ([IO.Path]::GetTempPath()) (
            'psprune-split-score-' + [guid]::NewGuid().ToString('N') +
            [IO.Path]::GetExtension($Batch.target.file)
        )
        try {
            [IO.File]::WriteAllText($temporary, $replacement, [Text.UTF8Encoding]::new($false))
            $issues = @(Invoke-ScriptAnalyzer -Path $temporary -Severity Error -ErrorAction Stop)
            if ($issues.Count) {
                throw "PSScriptAnalyzer rejected candidate: $($issues[0].Message)"
            }
            $score = Get-PSPruneSplitScore -Group $group -File $temporary
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        }

        $scoreWatch.Stop()
        $result.score_duration_ms = $scoreWatch.ElapsedMilliseconds
        $result.total_cognitive = $score.total_cognitive
        $result.concentration_score = $score.concentration_score
        $result.max_cognitive = $score.max_cognitive
        $result.adjusted_cyclomatic = $score.adjusted_cyclomatic
        $result.helper_count = $score.helper_count
        $result.functions = $score.functions

        $result.eligible = $score.concentration_score -lt $Batch.original.concentration_score
        [pscustomobject]@{
            Result = [pscustomobject]$result
            Replacement = $replacement
        }
    }
    catch {
        $result.error = $_.Exception.Message
        [pscustomobject]@{
            Result = [pscustomobject]$result
            Replacement = $null
        }
    }
}

function Complete-PSPruneSplitBatch {
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
        mode = 'Split'
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
            baseline_passed = $true
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

    $lock = Enter-PSPruneLock -Store $store
    try {
        $working = Get-PSPruneJson -Path $workingManifest
        if ($working.status -ne 'open') { throw "Batch '$id' has already been finalized." }
        if ((Get-PSPruneFileDigest -Path $target) -cne $Batch.target.file_sha256) {
            throw 'Source changed during split evaluation. Refusing stale batch.'
        }
        $masterPath = Get-PSPruneMasterPath -Root $Root
        $master = Get-PSPruneJson -Path $masterPath
        if (@($master.batches | Where-Object Id -eq $id).Count) {
            throw "Batch '$id' already exists in permanent history."
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

function Invoke-PSPruneSplitBatch {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ProjectPath,
        [switch]$Apply
    )

    $root = Get-PSPruneRoot -Path $ProjectPath
    $directory = Get-PSPruneBatchPath -Root $root -Id $Id
    $batch = Get-PSPruneJson -Path (Join-Path $directory 'manifest.json')
    if ($batch.mode -ne 'Split' -or $batch.status -ne 'open') {
        throw "Batch '$Id' is not an open Split batch."
    }

    $target = Join-Path $root $batch.target.file
    if ((Get-PSPruneFileDigest -Path $target) -cne $batch.target.file_sha256) {
        throw 'Original source changed after batch creation. Refusing stale batch.'
    }
    $source = [IO.File]::ReadAllText($target)
    $definition = Get-PSPruneAst -Source $source -FunctionName $batch.target.function
    if ((Get-PSPruneDigest -Text $definition.Extent.Text) -cne $batch.target.source_sha256) {
        throw 'Original function fingerprint changed after batch creation.'
    }

    $paths = @(1..5 | ForEach-Object { Join-Path $directory "candidate-$_.ps1" })
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Incomplete Split batch: missing $path"
        }
    }

    $timeout = if ($batch.test_timeout_seconds) { [int]$batch.test_timeout_seconds } else { 300 }
    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    # Rank candidates without running any of them.
    $evaluations = @(for ($slot = 1; $slot -le 5; $slot++) {
        Measure-PSPruneSplitCandidate -Path $paths[$slot - 1] -Slot $slot -Batch $batch -Root $root -Source $source -Definition $definition
    })
    $candidates = @($evaluations | ForEach-Object Result)
    $ranked = @($candidates | Where-Object eligible |
        Sort-Object concentration_score, max_cognitive, helper_count, slot)

    $winner = $null
    $replacement = $null
    foreach ($proposal in $ranked) {
        $candidateReplacement = @($evaluations |
            Where-Object { $_.Result.slot -eq $proposal.slot })[0].Replacement

        $test = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.test_path -RelativeTargetPath $batch.target.file -Replacement $candidateReplacement -TimeoutSeconds $timeout
        $proposal.tested = $true
        $proposal.passed = $test.Passed
        $proposal.test_duration_ms = $test.DurationMs
        if (-not $test.Passed) {
            $proposal.eligible = $false
            $proposal.error = "Focused Pester failed: $($test.Error)"
            continue
        }

        if ($batch.regression_test_path) {
            $verified = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.regression_test_path -RelativeTargetPath $batch.target.file -Replacement $candidateReplacement -TimeoutSeconds $timeout
            $proposal.regression_passed = $verified.Passed
            $proposal.regression_duration_ms = $verified.DurationMs
            if (-not $verified.Passed) {
                $proposal.eligible = $false
                $proposal.error = "Full regression failed: $($verified.Error)"
                continue
            }
        }

        $winner = $proposal
        $replacement = $candidateReplacement
        break
    }

    Complete-PSPruneSplitBatch -Batch $batch -Root $root -Candidates $candidates -Winner $winner -Replacement $replacement -Apply:$Apply
}
