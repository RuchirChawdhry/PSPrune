BeforeAll {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:fixture = Join-Path $root 'tests/fixtures/Example.ps1'
    $script:contract = Join-Path $root 'tests/fixtures/Verify-Candidate.ps1'
    $candidateDir = Join-Path $root 'tests/fixtures/candidates'
    $script:candidates = @(Get-ChildItem -LiteralPath $candidateDir -Filter '*.txt' -File |
        Sort-Object Name | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    if (-not (Test-Path -LiteralPath $script:fixture) -or
        -not (Test-Path -LiteralPath $script:contract) -or $script:candidates.Count -ne 5) {
        throw 'Required PSPrune fixtures are missing or incomplete.'
    }
    if (-not (Get-Module -ListAvailable PSComplexity | Where-Object Version -ge '0.7.1')) {
        Install-PSResource PSComplexity -Version '0.7.1' -Scope CurrentUser -TrustRepository -ErrorAction Stop
    }
    Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop
}

Describe 'PSPrune reporting contract' {
    It 'reports actual per-function scores and locations for one file' {
        $report = Get-PSPruneReport -Path $script:fixture
        $report.SchemaVersion | Should -Be 1
        $report.FunctionCount | Should -Be 2
        $function = $report.Functions | Where-Object Name -eq 'Get-Label'
        $function.File | Should -Be $script:fixture
        $function.Directory | Should -Be (Split-Path $script:fixture -Parent)
        $function.Line | Should -BeGreaterThan 0
        $function.Cyclomatic | Should -BeGreaterThan 1
        $function.Cognitive | Should -BeGreaterThan 0
        $function.MetricVersion | Should -BeGreaterThan 0
    }

    It 'returns a native PowerShell object with structured child objects' {
        $report = Get-PSPruneReport -Path $script:fixture
        ($report -is [pscustomobject]) | Should -BeTrue
        ($report.Functions -is [array]) | Should -BeTrue
        @($report.Functions | Where-Object { $_ -isnot [pscustomobject] }).Count | Should -Be 0

        $top = $report.Functions | Sort-Object Cognitive -Descending | Select-Object -First 1
        $top.PSObject.Properties.Name | Should -Contain 'Name'
        $top.PSObject.Properties.Name | Should -Contain 'Cognitive'
    }

    It 'serializes to JSON only through the standard PowerShell pipeline' {
        $report = Get-PSPruneReport -Path $script:fixture
        $json = $report | ConvertTo-Json -Depth 8
        ($json -is [string]) | Should -BeTrue
        $parsed = $json | ConvertFrom-Json
        $parsed.FunctionCount | Should -Be $report.FunctionCount
        $parsed.Functions.Count | Should -Be $report.Functions.Count
    }

    It 'scans a project directory without generating extra files' {
        $report = Get-PSPruneReport -Path (Split-Path $script:fixture -Parent)
        $report.FunctionCount | Should -BeGreaterOrEqual 2
        $report.Functions.Name | Should -Contain 'Get-Label'
    }
}

Describe 'PSPrune deterministic agent seam' {
    It 'returns native nested objects instead of JSON text' {
        $result = Invoke-PSPrune -Path $script:fixture -FunctionName Get-Label -Candidates $script:candidates -TestScript $script:contract
        ($result -is [pscustomobject]) | Should -BeTrue
        ($result.Original -is [pscustomobject]) | Should -BeTrue
        ($result.Candidates -is [array]) | Should -BeTrue
        @($result.Candidates | Where-Object { $_ -isnot [pscustomobject] }).Count | Should -Be 0
        $json = $result | ConvertTo-Json -Depth 8
        ($json | ConvertFrom-Json).Candidates.Count | Should -Be 5
    }

    It 'requires exactly five candidates' {
        { Invoke-PSPrune -Path $script:fixture -FunctionName Get-Label -Candidates $script:candidates[0..3] -TestScript $script:contract } |
            Should -Throw '*Exactly five*'
    }

    It 'tests five candidates, selects a genuine improvement, and preserves dry-run source' {
        $original = [IO.File]::ReadAllText($script:fixture)
        $result = Invoke-PSPrune -Path $script:fixture -FunctionName Get-Label -Candidates $script:candidates -TestScript $script:contract
        $result.AllPassed | Should -BeTrue
        $result.Candidates.Count | Should -Be 5
        @($result.Candidates | Where-Object Passed).Count | Should -Be 5
        $result.SelectedIndex | Should -BeGreaterThan 0
        $result.Improved | Should -BeTrue
        $result.Applied | Should -BeFalse
        [IO.File]::ReadAllText($script:fixture) | Should -BeExactly $original
        $winner = $result.Candidates[$result.SelectedIndex - 1]
        $winner.Cognitive | Should -BeLessOrEqual $result.Original.Cognitive
    }

    It 'rejects a syntactically invalid candidate without applying anything' {
        $target = Join-Path $TestDrive 'syntax.ps1'
        Copy-Item -LiteralPath $script:fixture -Destination $target
        $bad = @($script:candidates)
        $bad[1] = 'function Get-Label {'
        $result = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $bad -TestScript $script:contract -Apply
        $result.AllPassed | Should -BeFalse
        $result.Applied | Should -BeFalse
        $result.SelectedIndex | Should -BeNullOrEmpty
        @($result.Candidates | Where-Object { -not $_.Passed }).Count | Should -Be 1
        [IO.File]::ReadAllText($target) | Should -BeExactly ([IO.File]::ReadAllText($script:fixture))
    }

    It 'rejects a behavior-changing candidate even when it parses' {
        $target = Join-Path $TestDrive 'behavior.ps1'
        Copy-Item -LiteralPath $script:fixture -Destination $target
        $bad = @($script:candidates)
        $bad[0] = $bad[0].Replace("return 'zero'", "return 'wrong'")
        $result = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $bad -TestScript $script:contract -Apply
        $result.AllPassed | Should -BeFalse
        $result.Applied | Should -BeFalse
        $result.Candidates[0].Passed | Should -BeFalse
        [IO.File]::ReadAllText($target) | Should -BeExactly ([IO.File]::ReadAllText($script:fixture))
    }

    It 'rejects candidates that inject an additional top-level statement' {
        $bad = @($script:candidates)
        $bad[0] = $bad[0] + [Environment]::NewLine + "function Get-Surprise { 'unexpected' }"
        $result = Invoke-PSPrune -Path $script:fixture -FunctionName Get-Label -Candidates $bad -TestScript $script:contract
        $result.AllPassed | Should -BeFalse
        $result.Candidates[0].Passed | Should -BeFalse
    }

    It 'applies only the selected function after all five pass' {
        $target = Join-Path $TestDrive 'apply.ps1'
        Copy-Item -LiteralPath $script:fixture -Destination $target
        $before = [IO.File]::ReadAllText($target)
        $result = Invoke-PSPrune -Path $target -FunctionName Get-Label -Candidates $script:candidates -TestScript $script:contract -Apply
        $after = [IO.File]::ReadAllText($target)
        $result.AllPassed | Should -BeTrue
        $result.Improved | Should -BeTrue
        $result.Applied | Should -BeTrue
        $after | Should -Not -BeExactly $before
        $before.Substring(0, $before.IndexOf('function Get-Label')) |
            Should -BeExactly $after.Substring(0, $after.IndexOf('function Get-Label'))
        $before.Substring($before.IndexOf('# sentinel-after')) |
            Should -BeExactly $after.Substring($after.IndexOf('# sentinel-after'))
        & pwsh -NoProfile -NonInteractive -File $script:contract -CandidatePath $target
        $LASTEXITCODE | Should -Be 0
    }
}
