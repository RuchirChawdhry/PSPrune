[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$KeepWorkspace
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop

$workspace = Join-Path ([IO.Path]::GetTempPath()) ('psprune-dogfood-2-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $workspace 'project'
$null = New-Item -ItemType Directory -Path $project -Force
try {
    foreach ($entry in Get-ChildItem -LiteralPath $root -Force) {
        if ($entry.Name -in '.git', '.psprune', 'reports', 'dist') { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $project -Recurse -Force
    }

    $relative = 'src/PSPrune/Batch.Invoke.ps1'
    $target = Join-Path $project $relative
    $before = [IO.File]::ReadAllText($target)
    $outerDigest = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash

    $batch = New-PSPruneBatch -ProjectPath $project -Path $target -FunctionName Invoke-PSPruneBatch -TestPath tests/Focused/Invoke-PSPruneBatch.Tests.ps1 -RegressionTestPath tests -TestTimeoutSeconds 300 -Mode Split
    $submitted = @(foreach ($slot in 1..5) {
        $candidate = Join-Path $root "experiments/dogfood-2-split/candidate-$slot.ps1"
        Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $candidate -ProjectPath $project
    })

    $evaluated = Invoke-PSPrune -BatchId $batch.id -ProjectPath $project -Apply
    $after = [IO.File]::ReadAllText($target)

    $oldTokens = $null
    $oldErrors = $null
    $newTokens = $null
    $newErrors = $null
    $oldAst = [Management.Automation.Language.Parser]::ParseInput($before, [ref]$oldTokens, [ref]$oldErrors)
    $newAst = [Management.Automation.Language.Parser]::ParseInput($after, [ref]$newTokens, [ref]$newErrors)
    $oldFunction = @($oldAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-PSPruneBatch'
    })[0]
    $newFunction = @($newAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-PSPruneBatch'
    })[0]

    $outsideOld = $before.Substring(0, $oldFunction.Extent.StartOffset) +
        $before.Substring($oldFunction.Extent.EndOffset)
    $winnerNames = @()
    if ($evaluated.selected_slot) {
        $winner = @($evaluated.candidates | Where-Object slot -eq $evaluated.selected_slot)[0]
        $winnerNames = @($winner.functions | ForEach-Object name)
    }
    $inserted = @($newAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -in $winnerNames
    })
    $lastEnd = if ($inserted.Count) {
        ($inserted | Sort-Object { $_.Extent.EndOffset } -Descending | Select-Object -First 1).Extent.EndOffset
    } else { $newFunction.Extent.EndOffset }
    $outsideNew = $after.Substring(0, $newFunction.Extent.StartOffset) +
        $after.Substring($lastEnd)

    $history = @(Get-PSPruneHistory -Path $project)
    $scoreEligible = @($evaluated.candidates | Where-Object {
        $_.total_cognitive -lt $batch.original.cognitive -and
        $_.max_cognitive -lt $batch.original.cognitive -and
        $_.adjusted_cyclomatic -le $batch.original.cyclomatic
    })
    $outcome = if ($evaluated.applied -and $evaluated.validation.winner_regression_passed) {
        'Applied'
    }
    elseif (-not $scoreEligible.Count -and $evaluated.status -eq 'rejected') {
        'NoEligible'
    }
    else { 'FailedVerification' }
    $evidence = [pscustomobject]@{
        SchemaVersion = 1
        Mode = 'Split'
        Experiment = 'PSPrune Dogfood 2.0'
        Target = 'Invoke-PSPruneBatch'
        BatchId = $batch.id
        Original = $batch.original
        Submitted = $submitted.Count
        Result = $evaluated
        HistoryCount = $history.Count
        Outcome = $outcome
        ScoreEligibleCount = $scoreEligible.Count
        CandidateTestPath = $batch.test_path
        RegressionTestPath = $batch.regression_test_path
        OutsideGroupUnchanged = $outsideOld -ceq $outsideNew
        ProductionUnchanged = $outerDigest -ceq (
            Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256
        ).Hash
    }
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $destination = [IO.Path]::GetFullPath($OutFile)
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $destination -Encoding utf8
    }
    $summaries = @($evaluated.candidates | Select-Object slot, passed, eligible,
        total_cognitive, max_cognitive, adjusted_cyclomatic, helper_count, error)
    Write-Information -InformationAction Continue -MessageData (
        $summaries | Format-Table -AutoSize | Out-String
    )

    if (-not $evidence.ProductionUnchanged) { throw 'Dogfood 2.0 modified the real repository.' }
    if (-not $evidence.OutsideGroupUnchanged) { throw 'Dogfood 2.0 altered unrelated source.' }
    if ($submitted.Count -ne 5 -or $history.Count -ne 1) {
        throw 'Dogfood 2.0 lost candidate submissions or history.'
    }
    if (-not $evaluated.validation.all_passed) { throw 'Dogfood 2.0: not all five candidates passed focused Pester.' }
    if ($outcome -eq 'FailedVerification') {
        throw 'Dogfood 2.0: an eligible split did not pass the full regression.'
    }
    if ($outcome -eq 'NoEligible') {
        Write-Information -InformationAction Continue -MessageData 'No split improved the complete function group. Correctly rejected all five.'
    }
    $evidence
}
finally {
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $workspace)) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
