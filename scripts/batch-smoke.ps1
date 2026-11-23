param([string]$OutFile)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('psprune-batch-smoke-' + [guid]::NewGuid().ToString('N'))
$sourceProject = Join-Path $root 'tests/fixtures/BatchProject'
$sourceCandidates = Join-Path $root 'tests/fixtures/candidates'
try {
    Copy-Item -LiteralPath $sourceProject -Destination $temporary -Recurse -Force
    $target = Join-Path $temporary 'Example.ps1'
    $before = [IO.File]::ReadAllText($target)
    $batch = New-PSPruneBatch -Path $target -FunctionName Get-Label -ProjectPath $temporary
    for ($slot = 1; $slot -le 5; $slot++) {
        $file = @(Get-Item -Path (Join-Path $sourceCandidates "$slot-*.txt"))[0].FullName
        $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $file -ProjectPath $temporary
    }
    $selected = Invoke-PSPrune -BatchId $batch.id -ProjectPath $temporary -Apply
    if ($selected.status -ne 'applied' -or -not $selected.improved -or
        -not $selected.validation.winner_passed -or $selected.candidates.Count -ne 5) {
        throw "Batch evaluation failed: $($selected | ConvertTo-Json -Depth 12 -Compress)"
    }
    $after = [IO.File]::ReadAllText($target)
    if ($after -ceq $before -or
        $after.Substring($after.IndexOf('# after sentinel')) -cne
        $before.Substring($before.IndexOf('# after sentinel'))) {
        throw 'Function-only replacement contract failed.'
    }
    $master = Join-Path $temporary '.psprune/manifest.json'
    $manifestBefore = [IO.File]::ReadAllText($master)
    $clean = @(Clear-PSPruneArtifacts -Path $temporary -BatchId $batch.id -Confirm:$false)
    if (-not $clean[0].Removed -or
        [IO.File]::ReadAllText($master) -cne $manifestBefore) {
        throw 'Manual artifact pruning damaged permanent history.'
    }
    $history = @(Get-PSPruneHistory -Path $temporary)
    if ($history.Count -ne 1 -or $history[0].id -cne $batch.id) {
        throw 'Permanent history does not contain the finalized batch.'
    }
    $output = [pscustomobject]@{
        SchemaVersion = 1
        Mode = 'offline-batch-pester'
        Result = $selected
        HistoryCount = $history.Count
        Pruned = [bool]$clean[0].Removed
    }
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $destination = [IO.Path]::GetFullPath($OutFile)
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        $output | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $destination -Encoding utf8
    }
    $output
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
