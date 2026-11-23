BeforeAll {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $fixture = Join-Path $root 'tests/fixtures/Example.ps1'
    $contract = Join-Path $root 'tests/fixtures/Verify-Candidate.ps1'
    $candidateDir = Join-Path $root 'tests/fixtures/candidates'
    $candidates = @(Get-ChildItem -LiteralPath $candidateDir -Filter '*.txt' -File |
        Sort-Object Name | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    if (-not (Get-Module -ListAvailable PSComplexity | Where-Object Version -ge '0.7.1')) {
        Install-PSResource PSComplexity -Version '0.7.1' -Scope CurrentUser -TrustRepository -ErrorAction Stop
    }
    Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop
}

Describe 'PSPrune reporting contract' {
    It 'reports actual per-function scores and locations for one file' {
        $report = Get-PSPruneReport -Path $fixture
        $report.SchemaVersion | Should -Be 1
        $report.FunctionCount | Should -Be 2
        $function = $report.Functions | Where-Object Name -eq 'Get-Label'
        $function.File | Should -Be $fixture
        $function.Directory | Should -Be (Split-Path $fixture -Parent)
        $function.Line | Should -BeGreaterThan 0
        $function.Cyclomatic | Should -BeGreaterThan 1
        $function.Cognitive | Should -BeGreaterThan 0
        $function.MetricVersion | Should -BeGreaterThan 0
    }

    It 'scans a project directory without generating extra files' {
        $report = Get-PSPruneReport -Path (Split-Path $fixture -Parent)
        $report.FunctionCount | Should -BeGreaterOrEqual 2
        $report.Functions.Name | Should -Contain 'Get-Label'
    }
}

Describe 'PSPrune deterministic agent seam' {
    It 'requires exactly five candidates' {
        { Invoke-PSPrune -Path $fixture -FunctionName Get-Label -Candidates $candidates[0..3] -TestScript $contract } |
            Should -Throw '*Exactly five*'
    }

    It 'tests five candidates, selects a genuine improvement, and preserves dry-run source' {
        $original = [IO.File]::ReadAllText($fixture)
        $result = Invoke-PSPrune -Path $fixture -FunctionName Get-Label -Candidates $candidates -TestScript $contract
        $result.AllPassed | Should -BeTrue
        $result.Candidates.Count | Should -Be 5
        @($result.Candidates | Where-Object Passed).Count | Should -Be 5
        $result.SelectedIndex | Should -BeGreaterThan 0
        $result.Improved | Should -BeTrue
        $result.Applied | Should -BeFalse
        [IO.File]::ReadAllText($fixture) | Should -BeExactly $original
        $winner = $result.Candidates[$result.SelectedIndex - 1]
        $winner.Cognitive | Should -BeLessOrEqual $result.Original.Cognitive
    }

    It 'rejects a syntactically invalid candidate without applying anything' {
        $target = Join-Path $TestDrive 'syntax.ps1'
        Copy-Item -LiteralPath $fixture -Destination $target
        $bad = @($candidates)
        $bad[1] = 'function Get-Label {'
        $result = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $bad -TestScript $contract -Apply
        $result.AllPassed | Should -BeFalse
        $result.Applied | Should -BeFalse
        $result.SelectedIndex | Should -BeNullOrEmpty
        @($result.Candidates | Where-Object { -not $_.Passed }).Count | Should -Be 1
        [IO.File]::ReadAllText($target) | Should -BeExactly ([IO.File]::ReadAllText($fixture))
    }

    It 'rejects a behavior-changing candidate even when it parses' {
        $target = Join-Path $TestDrive 'behavior.ps1'
        Copy-Item -LiteralPath $fixture -Destination $target
        $bad = @($candidates)
        $bad[0] = $bad[0].Replace("return 'zero'", "return 'wrong'")
        $result = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $bad -TestScript $contract -Apply
        $result.AllPassed | Should -BeFalse
        $result.Applied | Should -BeFalse
        $result.Candidates[0].Passed | Should -BeFalse
        [IO.File]::ReadAllText($target) | Should -BeExactly ([IO.File]::ReadAllText($fixture))
    }

    It 'rejects candidates that inject an additional top-level statement' {
        $bad = @($candidates)
        $bad[0] = $bad[0] + [Environment]::NewLine + "function Get-Surprise { 'unexpected' }"
        $result = Invoke-PSPrune -Path $fixture -FunctionName Get-Label -Candidates $bad -TestScript $contract
        $result.AllPassed | Should -BeFalse
        $result.Candidates[0].Passed | Should -BeFalse
    }

    It 'applies only the selected function after all five pass' {
        $target = Join-Path $TestDrive 'apply.ps1'
        Copy-Item -LiteralPath $fixture -Destination $target
        $before = [IO.File]::ReadAllText($target)
        $result = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $candidates -TestScript $contract -Apply
        $after = [IO.File]::ReadAllText($target)
        $result.AllPassed | Should -BeTrue
        $result.Improved | Should -BeTrue
        $result.Applied | Should -BeTrue
        $after | Should -Not -BeExactly $before
        $before.Substring(0, $before.IndexOf('function Get-Label')) |
            Should -BeExactly $after.Substring(0, $after.IndexOf('function Get-Label'))
        $before.Substring($before.IndexOf('# sentinel-after')) |
            Should -BeExactly $after.Substring($after.IndexOf('# sentinel-after'))
        & pwsh -NoProfile -NonInteractive -File $contract -CandidatePath $target
        $LASTEXITCODE | Should -Be 0
    }
}
