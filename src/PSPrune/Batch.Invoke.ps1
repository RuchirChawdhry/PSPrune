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
    $store = Get-PSPruneStore -Root $root
    $batchDir = Get-PSPruneBatchPath -Root $root -Id $Id
    $batchManifest = Join-Path $batchDir 'manifest.json'
    $batch = Get-PSPruneJson -Path $batchManifest
    if ($batch.mode -eq 'Split') {
        return Invoke-PSPruneSplitBatch -Id $Id -ProjectPath $root -Apply:$Apply
    }
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

    $baseline = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.test_path -RelativeTargetPath $batch.target.file
    if (-not $baseline.Passed) {
        throw "Original project tests failed. No candidates evaluated: $($baseline.Error)"
    }

    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop
    $results = [Collections.Generic.List[object]]::new()
    $replacements = @{}
    for ($index = 1; $index -le 5; $index++) {
        $candidatePath = $paths[$index - 1]
        $passed = $false
        $reason = $null
        $cognitive = $null
        $cyclomatic = $null
        $candidateSource = [IO.File]::ReadAllText($candidatePath)
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
            $tested = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.test_path -RelativeTargetPath $batch.target.file -Replacement $replacement
            if (-not $tested.Passed) { throw "Pester failed: $($tested.Error)" }
            $passed = $true
            $replacements[$index] = $replacement
        }
        catch { $reason = $_.Exception.Message }
        $results.Add([pscustomobject]@{
            slot = $index
            sha256 = Get-PSPruneFileDigest -Path $candidatePath
            passed = $passed
            cyclomatic = $cyclomatic
            cognitive = $cognitive
            error = $reason
        })
    }

    $allPassed = @($results | Where-Object passed).Count -eq 5
    $winner = if ($allPassed) {
        $results | Sort-Object cognitive, cyclomatic, slot | Select-Object -First 1
    } else { $null }
    $improved = $null -ne $winner -and (
        $winner.cognitive -lt $batch.original.cognitive -or (
            $winner.cognitive -eq $batch.original.cognitive -and
            $winner.cyclomatic -lt $batch.original.cyclomatic
        )
    )

    $record = [ordered]@{
        id = $Id
        created_at = $batch.created_at
        completed_at = [DateTime]::UtcNow.ToString('o')
        status = if (-not $allPassed -or -not $improved) { 'rejected' } elseif ($Apply) { 'applied' } else { 'evaluated' }
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
            baseline_passed = $true
            all_passed = $allPassed
        }
        candidates = $results.ToArray()
        selected_slot = if ($null -ne $winner) { $winner.slot } else { $null }
        improved = [bool]$improved
        applied = $false
    }

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
