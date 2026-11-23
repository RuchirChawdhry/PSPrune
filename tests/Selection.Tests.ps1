BeforeAll {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:fixture = Join-Path $root 'tests/fixtures/SplitProject'
    $script:selection = Join-Path $root 'src/PSPrune/Selection.ps1'
    . $script:selection
}

Describe 'squared cognitive concentration' {
    It 'distinguishes one score of 40 from two scores of 20' {
        (Get-PSPruneConcentrationScore -CognitiveScores @(40)) | Should -Be 1600
        (Get-PSPruneConcentrationScore -CognitiveScores @(20, 20)) | Should -Be 825
        (Get-PSPruneConcentrationScore -CognitiveScores @(10, 10, 10, 10)) | Should -Be 475
    }

    It 'penalizes splitting already-simple code into helpers' {
        (Get-PSPruneConcentrationScore -CognitiveScores @(5)) | Should -Be 25
        (Get-PSPruneConcentrationScore -CognitiveScores @(3, 1)) | Should -Be 35
    }

    It 'does not treat an extra helper as free' {
        (Get-PSPruneConcentrationScore -CognitiveScores @(0, 0)) | Should -Be 25
        (Get-PSPruneConcentrationScore -CognitiveScores @(0, 0, 0)) | Should -Be 50
    }
}

Describe 'automatic Pester selection and reusable project inventory' {
    It 'discovers the target function without a manual test path' {
        $selection = Resolve-PSPruneTestPath -Root $script:fixture -FunctionName Get-Category
        $selection.Discovery | Should -BeExactly 'function-reference'
        $selection.Path.Replace('\', '/') | Should -BeExactly 'tests/Category.Tests.ps1'
    }

    It 'uses the project suite when no function reference exists' {
        $selection = Resolve-PSPruneTestPath -Root $script:fixture -FunctionName Invoke-NotPresent
        $selection.Discovery | Should -BeExactly 'project-fallback'
        $selection.Path | Should -BeExactly 'tests'
    }

    It 'uses explicitly provided test paths as an override' {
        $selection = Resolve-PSPruneTestPath -Root $script:fixture -FunctionName Get-Category -ExplicitPath 'tests/Focused.Tests.ps1'
        $selection.Discovery | Should -BeExactly 'explicit'
        $selection.Path.Replace('\', '/') | Should -BeExactly 'tests/Focused.Tests.ps1'
    }

    It 'indexes project function definitions once for a batch' {
        $index = Get-PSPruneProjectIndex -Root $script:fixture
        $index.names | Should -Contain 'Get-Category'
        $index.names | Should -Contain 'Get-Unchanged'
        $index.unguarded_modules.Count | Should -Be 0
    }
}
