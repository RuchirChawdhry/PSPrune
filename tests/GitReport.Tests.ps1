BeforeAll {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:fixture = Join-Path $root 'tests/fixtures/Example.ps1'
    if (-not (Get-Module -ListAvailable PSComplexity | Where-Object Version -ge '0.7.1')) {
        Install-PSResource PSComplexity -Version '0.7.1' -Scope CurrentUser -TrustRepository -ErrorAction Stop
    }
    Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop
}

Describe 'Get-PSPruneReport top-complexity selection' {
    It 'returns the three, five, or ten most complex available functions' {
        foreach ($limit in 3, 5, 10) {
            $report = Get-PSPruneReport -Path $script:fixture -Top $limit
            ($report -is [pscustomobject]) | Should -BeTrue
            $report.FunctionCount | Should -Be 2
            $report.ReturnedCount | Should -Be 2
            $report.Functions[0].Name | Should -BeExactly 'Get-Label'
        }
    }

    It 'supports a smaller limit and both complexity metrics' {
        $report = Get-PSPruneReport -Path $script:fixture -Top 1
        $report.FunctionCount | Should -Be 2
        $report.ReturnedCount | Should -Be 1
        $report.Functions.Count | Should -Be 1
        $report.Functions[0].Name | Should -BeExactly 'Get-Label'

        $cyclomatic = Get-PSPruneReport -Path $script:fixture -Top 1 -Metric Cyclomatic
        $cyclomatic.Metric | Should -BeExactly 'Cyclomatic'
        $cyclomatic.Functions[0].Name | Should -BeExactly 'Get-Label'
        { Get-PSPruneReport -Path $script:fixture -Top 0 } | Should -Throw
    }
}

Describe 'Git baseline/current new-function complexity report' {
    BeforeEach {
        $script:gitRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:gitRepo -Force
        $null = & git -C $script:gitRepo init -q
        $null = & git -C $script:gitRepo config user.email 'psprune-ci@example.invalid'
        $null = & git -C $script:gitRepo config user.name 'PSPrune CI'
        $src = Join-Path $script:gitRepo 'src'
        $null = New-Item -ItemType Directory -Path $src -Force
        $baselineText = @'
function Get-Existing {
    param([int]$Value)
    return $Value
}
'@
        Set-Content -LiteralPath (Join-Path $src 'One.ps1') -Value $baselineText -Encoding utf8
        $null = & git -C $script:gitRepo add .
        $null = & git -C $script:gitRepo commit -qm baseline
        if ($LASTEXITCODE -ne 0) { throw 'Could not create baseline test commit.' }
        $script:baselineCommit = (& git -C $script:gitRepo rev-parse HEAD).Trim()

        $currentText = @'
function Get-Existing {
    param([int]$Value)
    return ($Value + 1)
}

function Get-NewSimple {
    return 42
}

function Get-NewComplex {
    param([int]$Value)
    if ($Value -lt 0) { return 'negative' }
    if ($Value -eq 0) { return 'zero' }
    if ($Value -lt 10) { return 'small' }
    return 'large'
}
'@
        Set-Content -LiteralPath (Join-Path $src 'One.ps1') -Value $currentText -Encoding utf8
        Set-Content -LiteralPath (Join-Path $src 'Two.psm1') -Value @'
function Get-NewModule {
    param([int]$Value)
    if ($Value) { return $Value }
    return 0
}
'@ -Encoding utf8
        $misc = Join-Path $script:gitRepo 'misc'
        $null = New-Item -ItemType Directory -Path $misc -Force
        Set-Content -LiteralPath (Join-Path $misc 'Outside.ps1') -Value "function Get-Outside { return 1 }" -Encoding utf8
        $null = & git -C $script:gitRepo add .
        $null = & git -C $script:gitRepo commit -qm current
        if ($LASTEXITCODE -ne 0) { throw 'Could not create current test commit.' }
        $script:currentCommit = (& git -C $script:gitRepo rev-parse HEAD).Trim()
    }

    It 'scores newly added functions, not existing functions edited in the same commit' {
        $report = Get-PSPruneCommitReport -Path (Join-Path $script:gitRepo 'src') -BaselineCommit $script:baselineCommit -CurrentCommit $script:currentCommit
        ($report -is [pscustomobject]) | Should -BeTrue
        $report.BaselineCommit | Should -BeExactly $script:baselineCommit
        $report.CurrentCommit | Should -BeExactly $script:currentCommit
        $report.FunctionCount | Should -Be 3
        $report.ReturnedCount | Should -Be 3
        $report.Functions.Name | Should -Contain 'Get-NewSimple'
        $report.Functions.Name | Should -Contain 'Get-NewComplex'
        $report.Functions.Name | Should -Contain 'Get-NewModule'
        $report.Functions.Name | Should -Not -Contain 'Get-Existing'
        $report.Functions.Name | Should -Not -Contain 'Get-Outside'
        @($report.Functions | Where-Object ChangeType -ne 'Added').Count | Should -Be 0
        @($report.Functions | Where-Object { $_.Cyclomatic -lt 1 }).Count | Should -Be 0
        $report.Functions[0].Name | Should -BeExactly 'Get-NewComplex'
        ($report | ConvertTo-Json -Depth 8 | ConvertFrom-Json).Functions.Count | Should -Be 3
    }

    It 'supports top 3/5/10 and cyclomatic ranking against committed snapshots' {
        foreach ($limit in 3, 5, 10) {
            $result = Get-PSPruneCommitReport -Path (Join-Path $script:gitRepo 'src') -BaselineCommit $script:baselineCommit -CurrentCommit $script:currentCommit -Top $limit
            $result.FunctionCount | Should -Be 3
            $result.ReturnedCount | Should -Be 3
        }
        $best = Get-PSPruneCommitReport -Path $script:gitRepo -BaselineCommit HEAD~1 -CurrentCommit HEAD -Top 1 -Metric Cyclomatic
        $best.FunctionCount | Should -Be 4
        $best.ReturnedCount | Should -Be 1
        $best.Metric | Should -BeExactly 'Cyclomatic'
        $best.Functions[0].Name | Should -BeExactly 'Get-NewComplex'
    }

    It 'ignores uncommitted changes and returns zero for identical commits' {
        Add-Content -LiteralPath (Join-Path $script:gitRepo 'src/One.ps1') -Value 'function Get-Uncommitted { return 9 }'
        $report = Get-PSPruneCommitReport -Path (Join-Path $script:gitRepo 'src') -BaselineCommit $script:baselineCommit -CurrentCommit $script:currentCommit
        $report.Functions.Name | Should -Not -Contain 'Get-Uncommitted'
        $empty = Get-PSPruneCommitReport -Path $script:gitRepo -BaselineCommit $script:currentCommit -CurrentCommit $script:currentCommit
        $empty.FunctionCount | Should -Be 0
        $empty.ReturnedCount | Should -Be 0
        $empty.Functions.Count | Should -Be 0
    }

    It 'rejects missing Git refs instead of comparing against the working tree' {
        { Get-PSPruneCommitReport -Path $script:gitRepo -BaselineCommit does-not-exist -CurrentCommit $script:currentCommit } | Should -Throw '*Invalid baseline*'
        { Get-PSPruneCommitReport -Path $script:gitRepo -BaselineCommit $script:baselineCommit -CurrentCommit does-not-exist } | Should -Throw '*Invalid current*'
    }
}
