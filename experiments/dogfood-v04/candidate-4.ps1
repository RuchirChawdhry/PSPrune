function Invoke-PSPruneBatch {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$ProjectPath = '.',
        [switch]$Apply
    )
    Assert-PSPruneId -Id $Id
    $root = Get-PSPruneRoot -Path $ProjectPath
    $store = Get-PSPruneStore -Root $root
    $batchDir = Get-PSPruneBatchPath -Root $root -Id $Id
    $batchManifest = Join-Path $batchDir 'manifest.json'
    $batch = Get-PSPruneJson -Path $batchManifest
    if ($batch.mode -eq 'Split') {
        return Invoke-PSPruneSplitBatch -Id $Id -ProjectPath $root -Apply:$Apply
    }
    $context = Get-PSPruneSingleContext -Id $Id -Root $root -Store $store -BatchDir $batchDir -BatchManifest $batchManifest -Batch $batch
    $evaluation = Test-PSPruneSingleEvaluation -Context $context
    Complete-PSPruneSingleBatch -Context $context -Scored $evaluation -Selected $evaluation -Apply:$Apply
}

function Get-PSPruneSingleContext {
    param([string]$Id, [string]$Root, [string]$Store, [string]$BatchDir, [string]$BatchManifest, $Batch)
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
    foreach ($candidatePath in $paths) {
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            throw "Incomplete batch: missing $candidatePath"
        }
    }

    [pscustomobject]@{
        Id = $Id
        Root = $Root
        Store = $Store
        BatchDir = $BatchDir
        BatchManifest = $BatchManifest
        Batch = $Batch
        Target = $target
        Source = $source
        Definition = $definition
        Paths = $paths
    }
}

function Test-PSPruneSingleEvaluation {
    param([Parameter(Mandatory)]$Context)
    $root = $Context.Root
    $batch = $Context.Batch
    $source = $Context.Source
    $definition = $Context.Definition
    $paths = $Context.Paths
    $timeout = if ($batch.test_timeout_seconds) { [int]$batch.test_timeout_seconds } else { 300 }
    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop

    $results = [Collections.Generic.List[object]]::new()
    $replacements = @{}
    for ($index = 1; $index -le 5; $index++) {
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

    $winner = $null
    $improved = $false
    $eligibleCandidates = @($results | Where-Object eligible |
        Sort-Object cognitive, cyclomatic, slot)
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
        $improved = $true
        break
    }

    $testedCandidates = @($results | Where-Object tested)
    [pscustomobject]@{
        Results = $results.ToArray()
        Replacements = $replacements
        Timeout = $timeout
        Winner = $winner
        Improved = $improved
        TestedCandidates = $testedCandidates
    }
}

function Complete-PSPruneSingleBatch {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Scored, [Parameter(Mandatory)]$Selected, [switch]$Apply)
    $Id = $Context.Id
    $root = $Context.Root
    $store = $Context.Store
    $batchManifest = $Context.BatchManifest
    $batch = $Context.Batch
    $target = $Context.Target
    $replacements = $Scored.Replacements
    $winner = $Selected.Winner
    $improved = $Selected.Improved
    $record = Get-PSPruneSingleRecord -Context $Context -Scored $Scored -Selected $Selected -Apply:$Apply
    $lock = Enter-PSPruneLock -Store $store
    try {
        $working = Get-PSPruneJson -Path $batchManifest
        if ($working.status -ne 'open') { throw "Batch '$Id' has already been finalized." }
        if ((Get-PSPruneFileDigest -Path $target) -cne $batch.target.file_sha256) {
            throw 'Source changed during candidate evaluation.'
        }
        $masterPath = Get-PSPruneMasterPath -Root $root
        $master = Get-PSPruneJson -Path $masterPath
        if (@($master.batches | Where-Object Id -eq $Id).Count) {
            throw "Batch '$Id' already exists in master history."
        }
        if ($Apply -and $improved) {
            $temporary = Join-Path (Split-Path $target -Parent) ('.psprune-apply-' + [guid]::NewGuid().ToString('N'))
            try {
                [IO.File]::WriteAllText($temporary, $replacements[$winner.slot], [Text.UTF8Encoding]::new($false))
                [IO.File]::Move($temporary, $target, $true)
            }
            finally {
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
            }
            $record.applied = $true
        }
        $master.batches = @($master.batches) + @([pscustomobject]$record)
        Save-PSPruneJson -Path $masterPath -Value $master
        $working.status = $record.status
        $working | Add-Member -NotePropertyName completed_at -NotePropertyValue $record.completed_at -Force
        $working | Add-Member -NotePropertyName selected_slot -NotePropertyValue $record.selected_slot -Force
        $working | Add-Member -NotePropertyName applied -NotePropertyValue $record.applied -Force
        Save-PSPruneJson -Path $batchManifest -Value $working
        Get-PSPruneHistory -Path $root | Where-Object Id -eq $Id
    }
    finally { $lock.Dispose() }
}

function Get-PSPruneSingleRecord {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Scored, [Parameter(Mandatory)]$Selected, [switch]$Apply)
    $Id = $Context.Id
    $batch = $Context.Batch
    $results = $Scored.Results
    $winner = $Selected.Winner
    $improved = $Selected.Improved
    $testedCandidates = $Selected.TestedCandidates
    $record = [ordered]@{
        id = $Id
        created_at = $batch.created_at
        completed_at = [DateTime]::UtcNow.ToString('o')
        status = if (-not $improved) { 'rejected' } elseif ($Apply) { 'applied' } else { 'evaluated' }
        target = [ordered]@{
            file = $batch.target.file
            function = $batch.target.function
            source_sha256 = $batch.target.source_sha256
            file_sha256 = $batch.target.file_sha256
        }
        original = $batch.original
        validation = [ordered]@{
            runner = 'Pester'
            test_path = $batch.test_path
            regression_test_path = $batch.regression_test_path
            baseline_passed = $null
            all_passed = $null
            tested_count = $testedCandidates.Count
            winner_passed = [bool]$winner
            test_discovery = $batch.test_discovery
            winner_regression_passed = if ($batch.regression_test_path) { [bool]$winner } else { $null }
            regression_attempt_count = @($results | Where-Object { $null -ne $_.regression_passed }).Count
        }
        candidates = @($results)
        selected_slot = if ($null -ne $winner) { $winner.slot } else { $null }
        improved = [bool]$improved
        applied = $false
    }

    $record
}
