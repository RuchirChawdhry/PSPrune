[CmdletBinding()]
param([string]$OutFile, [switch]$KeepWorkspace)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop

$workspace = Join-Path ([IO.Path]::GetTempPath()) ('psprune-dogfood-v04-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $workspace 'project'
$null = New-Item -ItemType Directory -Path $project -Force
try {
    foreach ($entry in Get-ChildItem -LiteralPath $root -Force) {
        if ($entry.Name -in '.git', '.psprune', 'reports', 'dist') { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $project -Recurse -Force
    }

    $relative = 'src/PSPrune/Batch.Invoke.ps1'
    $originalTarget = Join-Path $root $relative
    $target = Join-Path $project $relative
    $before = [IO.File]::ReadAllText($target)
    $outsideHash = (Get-FileHash -LiteralPath $originalTarget -Algorithm SHA256).Hash

    # No explicit root or test path: exercise the new automatic selection.
    $batch = New-PSPruneBatch -Path $target -FunctionName Invoke-PSPruneBatch -Mode Split

    $submissions = @(foreach ($slot in 1..5) {
        $candidate = Join-Path $root "experiments/dogfood-v04/candidate-$slot.ps1"
        Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $candidate -ProjectPath $project
    })
    $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $project -Apply
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

    $beforeOutside = $before.Substring(0, $oldFunction.Extent.StartOffset) +
        $before.Substring($oldFunction.Extent.EndOffset)

    $lastEnd = $newFunction.Extent.EndOffset
    if ($result.selected_slot) {
        $winner = @($result.candidates | Where-Object slot -eq $result.selected_slot)[0]
        $names = @($winner.functions | ForEach-Object name)
        $lastEnd = (@($newAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $_.Name -in $names
        }) | Sort-Object { $_.Extent.EndOffset } -Descending | Select-Object -First 1).Extent.EndOffset
    }
    $afterOutside = $after.Substring(0, $newFunction.Extent.StartOffset) +
        $after.Substring($lastEnd)

    $history = @(Get-PSPruneHistory -Path $project)
    $evidence = [pscustomobject]@{
        SchemaVersion = 2
        Experiment = 'PSPrune Dogfood 2.0 (v0.4)'
        BatchId = $batch.id
        Target = 'Invoke-PSPruneBatch'
        TestDiscovery = $batch.test_discovery
        TestPath = $batch.test_path
        Original = $batch.original
        Submitted = $submissions.Count
        Result = $result
        HistoryCount = $history.Count
        OutsideGroupUnchanged = $beforeOutside -ceq $afterOutside
        ProductionUnchanged = $outsideHash -ceq (
            Get-FileHash -LiteralPath $originalTarget -Algorithm SHA256
        ).Hash
    }

    if ($OutFile) {
        $destination = [IO.Path]::GetFullPath($OutFile)
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $destination -Encoding utf8
    }

    Write-Information -InformationAction Continue -MessageData (
        $result.candidates |
        Select-Object slot, concentration_score, helper_count, tested,
            passed, score_duration_ms, test_duration_ms, error |
        Format-Table -AutoSize | Out-String
    )

    if (-not $evidence.ProductionUnchanged -or -not $evidence.OutsideGroupUnchanged) {
        throw 'Dogfood experiment changed unrelated source.'
    }
    if ($submissions.Count -ne 5 -or $history.Count -ne 1) {
        throw 'Dogfood experiment lost candidate submissions or history.'
    }
    if (-not $result.applied -or -not $result.validation.winner_passed) {
        throw 'Dogfood v0.4: no passing lower-concentration Split group was applied.'
    }
    $evidence
}
finally {
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $workspace)) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
