[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$KeepWorkspace
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$module = Join-Path $root 'src/PSPrune/PSPrune.psd1'
Import-Module $module -Force -ErrorAction Stop

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('psprune-self-refactor-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $scratch 'project'
$null = New-Item -Path $project -ItemType Directory -Force
try {
    foreach ($entry in Get-ChildItem -LiteralPath $root -Force) {
        if ($entry.Name -in '.git', '.psprune', 'reports', 'dist') { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $project -Recurse -Force
    }
    $relativeTarget = 'src/PSPrune/Batch.Invoke.ps1'
    $target = Join-Path $project $relativeTarget
    $initial = [IO.File]::ReadAllText($target)
    $outerHash = (Get-FileHash -LiteralPath (Join-Path $root $relativeTarget) -Algorithm SHA256).Hash

    $batch = New-PSPruneBatch -ProjectPath $project -Path $target -FunctionName Invoke-PSPruneBatch -TestPath tests

    $submissions = @(foreach ($slot in 1..5) {
        $candidate = Join-Path $root "experiments/self-refactor/candidate-$slot.ps1"
        Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $candidate -ProjectPath $project
    })

    $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $project -Apply
    $revised = [IO.File]::ReadAllText($target)
    $currentOuterHash = (Get-FileHash -LiteralPath (Join-Path $root $relativeTarget) -Algorithm SHA256).Hash

    $initialTokens = $null
    $initialErrors = $null
    $revisedTokens = $null
    $revisedErrors = $null
    $initialAst = [Management.Automation.Language.Parser]::ParseInput($initial, [ref]$initialTokens, [ref]$initialErrors)
    $revisedAst = [Management.Automation.Language.Parser]::ParseInput($revised, [ref]$revisedTokens, [ref]$revisedErrors)
    $initialFunction = @($initialAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -eq 'Invoke-PSPruneBatch'
    })[0]
    $revisedFunction = @($revisedAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -eq 'Invoke-PSPruneBatch'
    })[0]

    $beforeOutside = $initial.Substring(0, $initialFunction.Extent.StartOffset) +
        $initial.Substring($initialFunction.Extent.EndOffset)
    $afterOutside = $revised.Substring(0, $revisedFunction.Extent.StartOffset) +
        $revised.Substring($revisedFunction.Extent.EndOffset)

    $history = @(Get-PSPruneHistory -Path $project)
    $observations = [pscustomobject]@{
        SchemaVersion = 1
        Experiment = 'PSPrune self-refactor'
        Target = 'Invoke-PSPruneBatch'
        BatchId = $batch.id
        Original = $batch.original
        Submitted = $submissions.Count
        Result = $result
        HistoryCount = $history.Count
        OnlyTargetChanged = $beforeOutside -ceq $afterOutside
        OuterProjectUnchanged = $outerHash -ceq $currentOuterHash
    }

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $dest = [IO.Path]::GetFullPath($OutFile)
        $null = New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force
        $observations | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $dest -Encoding utf8
    }

    if ($result.validation.all_passed) {
        $selected = $result.candidates[$result.selected_slot - 1]
        $message = 'All candidates passed; selected slot {0}; cognitive {1} -> {2}; cyclomatic {3} -> {4}.' -f
            $result.selected_slot, $batch.original.cognitive, $selected.cognitive, $batch.original.cyclomatic, $selected.cyclomatic
        Write-Information -MessageData $message -InformationAction Continue
    }
    else {
        $failed = @($result.candidates | Where-Object { -not $_.passed } |
            ForEach-Object { "slot $($_.slot): $($_.error)" })
        Write-Information -MessageData ("Candidate failures: " + ($failed -join '; ')) -InformationAction Continue
    }

    if ($submissions.Count -ne 5) { throw 'Expected five atomic candidate submissions.' }
    if (-not $observations.OuterProjectUnchanged) { throw 'Experiment modified original project source.' }
    if (-not $observations.OnlyTargetChanged) { throw 'Experiment changed unrelated source text.' }
    if ($history.Count -ne 1) { throw 'Experiment failed to archive its batch history.' }
    if (-not $result.validation.all_passed) { throw 'Experiment: at least one candidate failed the full Pester suite.' }
    if (-not $result.improved -or -not $result.applied) { throw 'Experiment: no verified improved function was applied.' }
    $observations
}
finally {
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $scratch)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
