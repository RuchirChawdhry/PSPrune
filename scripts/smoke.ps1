param([string]$OutFile = 'reports/smoke.json')

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$fixture = Join-Path $root 'tests/fixtures/Example.ps1'
$contract = Join-Path $root 'tests/fixtures/Verify-Candidate.ps1'
$candidateDir = Join-Path $root 'tests/fixtures/candidates'

if (-not (Get-Module -ListAvailable PSComplexity | Where-Object Version -ge '0.7.1')) {
    Install-PSResource PSComplexity -Version '0.7.1' -Scope CurrentUser -TrustRepository -ErrorAction Stop
}
Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop

$candidates = @(Get-ChildItem -LiteralPath $candidateDir -Filter '*.txt' -File |
    Sort-Object Name | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
if ($candidates.Count -ne 5) {
    throw "Smoke test expected five mock candidates; found $($candidates.Count)."
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("psprune-smoke-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
try {
    $target = Join-Path $work 'Example.ps1'
    Copy-Item -LiteralPath $fixture -Destination $target
    $before = [IO.File]::ReadAllText($target)
    $report = Get-PSPruneReport -Path $target
    if ($report.FunctionCount -ne 2) {
        throw 'Complexity reporting did not discover both functions.'
    }

    $dryRun = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $candidates -TestScript $contract
    if (-not $dryRun.AllPassed -or -not $dryRun.Improved -or $dryRun.Applied) {
        throw "Dry-run candidate-selection contract failed: $($dryRun | ConvertTo-Json -Depth 7 -Compress)"
    }
    if ([IO.File]::ReadAllText($target) -cne $before) {
        throw 'Dry run unexpectedly modified the source.'
    }

    $applied = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $candidates -TestScript $contract -Apply
    if (-not $applied.AllPassed -or -not $applied.Applied) {
        throw 'Test-gated apply contract failed.'
    }
    & pwsh -NoProfile -NonInteractive -File $contract -CandidatePath $target
    if ($LASTEXITCODE -ne 0) {
        throw 'Applied candidate did not preserve behavior.'
    }
    $after = [IO.File]::ReadAllText($target)
    if ($before.Substring($before.IndexOf('# sentinel-after')) -cne
        $after.Substring($after.IndexOf('# sentinel-after'))) {
        throw 'Source outside the selected function changed.'
    }

    Copy-Item -LiteralPath $fixture -Destination $target -Force
    $bad = @($candidates)
    $bad[0] = $bad[0].Replace("return 'zero'", "return 'wrong'")
    $rejected = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $bad -TestScript $contract -Apply
    if ($rejected.AllPassed -or $rejected.Applied -or
        [IO.File]::ReadAllText($target) -cne $before) {
        throw 'Fail-closed guard allowed a faulty candidate.'
    }

    $output = [pscustomobject]@{
        SchemaVersion = 1
        Mode          = 'offline-fixtures'
        Report        = $report
        DryRun        = $dryRun
        Applied       = $applied
        Rejected      = $rejected
    }
    $destination = [IO.Path]::GetFullPath($OutFile)
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    $output | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $destination -Encoding utf8
    Write-Output "PSPrune smoke test passed; JSON written to $destination"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
