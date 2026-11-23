param([string]$OutFile)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('psprune-split-smoke-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'tests/fixtures/SplitProject'
$candidates = Join-Path $root 'tests/fixtures/SplitCandidates'

try {
    Copy-Item -LiteralPath $source -Destination $workspace -Recurse -Force
    $target = Join-Path $workspace 'Category.ps1'
    $original = [IO.File]::ReadAllText($target)
    $batch = New-PSPruneBatch -Path $target -FunctionName Get-Category -Mode Split -ProjectPath $workspace
    $submitted = @(foreach ($slot in 1..5) {
        Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath (Join-Path $candidates "candidate-$slot.txt") -ProjectPath $workspace
    })
    $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $workspace -Apply
    $modified = [IO.File]::ReadAllText($target)
    $master = Join-Path $workspace '.psprune/manifest.json'
    $history = @(Get-PSPruneHistory -Path $workspace)
    $recordBefore = [IO.File]::ReadAllText($master)
    $workingCandidate = Join-Path $workspace ".psprune/batches/$($batch.id)/candidate-1.ps1"
    $candidatePreserved = Test-Path -LiteralPath $workingCandidate -PathType Leaf
    $winner = @($result.candidates | Where-Object slot -eq $result.selected_slot)[0]

    $evidence = [pscustomobject]@{
        SchemaVersion = 1
        Mode = 'Split'
        BatchId = $batch.id
        Submitted = $submitted.Count
        Original = $batch.original
        Result = $result
        HistoryCount = $history.Count
        CandidatePreserved = $candidatePreserved
        OutsideFunctionPreserved = (
            $modified.Substring($modified.IndexOf('# untouched-after')) -ceq
            $original.Substring($original.IndexOf('# untouched-after'))
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $destination = [IO.Path]::GetFullPath($OutFile)
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        $evidence | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $destination -Encoding utf8
    }

    if ($submitted.Count -ne 5 -or $result.status -ne 'applied' -or
        -not $result.validation.winner_passed -or -not $result.improved -or
        $result.candidates.Count -ne 5 -or $history.Count -ne 1 -or
        -not $candidatePreserved -or -not $evidence.OutsideFunctionPreserved -or
        $winner.concentration_score -ge $batch.original.concentration_score -or
        $winner.max_cognitive -ge $batch.original.cognitive) {
        throw 'Split-mode self-check failed.'
    }
    $cleanup = @(Clear-PSPruneArtifacts -Path $workspace -BatchId $batch.id -Confirm:$false)
    if (-not $cleanup[0].Removed -or [IO.File]::ReadAllText($master) -cne $recordBefore) {
        throw 'Split-mode pruning changed permanent history.'
    }
    $evidence
}
finally {
    if (Test-Path -LiteralPath $workspace) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
