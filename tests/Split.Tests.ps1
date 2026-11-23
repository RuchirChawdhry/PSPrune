BeforeAll {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:sourceProject = Join-Path $root 'tests/fixtures/SplitProject'
    $script:sourceCandidates = Join-Path $root 'tests/fixtures/SplitCandidates'
    if (-not (Get-Module -ListAvailable PSComplexity | Where-Object Version -ge '0.7.1')) {
        Install-PSResource PSComplexity -Version '0.7.1' -Scope CurrentUser -TrustRepository -ErrorAction Stop
    }
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Install-PSResource PSScriptAnalyzer -Version '1.24.0' -Scope CurrentUser -TrustRepository -ErrorAction Stop
    }
    Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop
}

Describe 'PSPrune v0.3 same-file function groups' {
    BeforeEach {
        $script:project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:sourceProject -Destination $script:project -Recurse -Force
        $script:target = Join-Path $script:project 'Category.ps1'
        $script:original = [IO.File]::ReadAllText($script:target)
    }

    It 'creates Split batches and accepts distinct candidate slots' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split
        $batch.mode | Should -BeExactly 'Split'
        $batch.target.function | Should -BeExactly 'Get-Category'
        $batch.original.cognitive | Should -BeGreaterThan 0
        $candidate = Join-Path $script:sourceCandidates 'candidate-1.txt'
        $submitted = Submit-PSPruneCandidate -Id $batch.id -Slot 1 -SourcePath $candidate -ProjectPath $script:project
        $submitted.SHA256 | Should -Match '^[0-9a-f]{64}$'
        { Submit-PSPruneCandidate -Id $batch.id -Slot 1 -SourcePath $candidate -ProjectPath $script:project } |
            Should -Throw '*occupied*'
    }

    It 'refuses unrelated executable statements and helper name collisions' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split
        $source = [IO.File]::ReadAllText((Join-Path $script:sourceCandidates 'candidate-1.txt'))
        $file = Join-Path $TestDrive 'invalid-split.ps1'
        [IO.File]::WriteAllText($file, $source + "Write-Output 'unexpected'")
        { Submit-PSPruneCandidate -Id $batch.id -Slot 1 -SourcePath $file -ProjectPath $script:project } |
            Should -Throw '*top-level*'
        [IO.File]::WriteAllText($file, $source.Replace('Get-NegativeCategory', 'Get-Unchanged'))
        { Submit-PSPruneCandidate -Id $batch.id -Slot 1 -SourcePath $file -ProjectPath $script:project } |
            Should -Throw '*collides*'
        (Test-Path -LiteralPath (Join-Path $script:project ".psprune/batches/$($batch.id)/candidate-1.ps1")) | Should -BeFalse
    }

    It 'passes real Pester tests and applies the lowest-scoring function group' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split
        foreach ($slot in 1..5) {
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath (Join-Path $script:sourceCandidates "candidate-$slot.txt") -ProjectPath $script:project
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project -Apply
        $result.mode | Should -BeExactly 'Split'
        $result.status | Should -BeExactly 'applied'
        $result.validation.winner_passed | Should -BeTrue
        $result.applied | Should -BeTrue
        $result.candidates.Count | Should -Be 5
        $winner = @($result.candidates | Where-Object slot -eq $result.selected_slot)[0]
        $winner.eligible | Should -BeTrue
        $winner.helper_count | Should -Be 1
        $winner.functions.Count | Should -Be 2
        $winner.concentration_score | Should -BeLessThan $batch.original.concentration_score
        $winner.max_cognitive | Should -BeLessThan $batch.original.cognitive
        $winner.concentration_score | Should -BeGreaterThan 0

        $revised = [IO.File]::ReadAllText($script:target)
        $revised | Should -Match ([regex]::Escape($winner.functions[1].name))
        $revised.Substring($revised.IndexOf('# untouched-after')) |
            Should -BeExactly $script:original.Substring($script:original.IndexOf('# untouched-after'))
        $revised.Substring(0, $revised.IndexOf('function Get-Category')) |
            Should -BeExactly $script:original.Substring(0, $script:original.IndexOf('function Get-Category'))
        $history = @(Get-PSPruneHistory -Path $script:project)
        $history.Count | Should -Be 1
        $history[0].mode | Should -BeExactly 'Split'
        $history[0].validation.baseline_passed | Should -BeTrue
        $history[0].candidates[0].functions[1].sha256 | Should -Match '^[0-9a-f]{64}$'
        $master = Join-Path $script:project '.psprune/manifest.json'
        $manifest = [IO.File]::ReadAllText($master)
        (Test-Path -LiteralPath (Join-Path $script:project ".psprune/batches/$($batch.id)/candidate-1.ps1")) | Should -BeTrue
        @(Clear-PSPruneArtifacts -Path $script:project -BatchId $batch.id -Confirm:$false)[0].Removed | Should -BeTrue
        [IO.File]::ReadAllText($master) | Should -BeExactly $manifest
    }

    It 'records a Split-mode dry-run without modifying the source' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split
        foreach ($slot in 1..5) {
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath (Join-Path $script:sourceCandidates "candidate-$slot.txt") -ProjectPath $script:project
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project
        $result.status | Should -BeExactly 'evaluated'
        $result.mode | Should -BeExactly 'Split'
        $result.applied | Should -BeFalse
        $result.validation.winner_passed | Should -BeTrue
        $result.validation.baseline_passed | Should -BeTrue
        [IO.File]::ReadAllText($script:target) | Should -BeExactly $script:original
        @((Get-PSPruneHistory -Path $script:project)).Count | Should -Be 1
    }

    It 'rejects a behavior-changing helper while preserving original source' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split
        foreach ($slot in 1..5) {
            $file = Join-Path $script:sourceCandidates "candidate-$slot.txt"
            if ($slot -eq 1) {
                $wrong = Join-Path $TestDrive 'wrong-split.ps1'
                $text = [IO.File]::ReadAllText($file)
                [IO.File]::WriteAllText($wrong, $text.Replace("'negative'", "'incorrect'"))
                $file = $wrong
            }
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $file -ProjectPath $script:project
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project -Apply
        $result.status | Should -BeExactly 'applied'
        $result.validation.winner_passed | Should -BeTrue
        $result.candidates[0].passed | Should -BeFalse
        $result.candidates[1].passed | Should -BeTrue
        $result.candidates[2].tested | Should -BeFalse
        $result.applied | Should -BeTrue
    }

    It 'rejects score gaming by adding unused helpers without reducing the original function' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split
        $entry = $script:original.Substring($script:original.IndexOf('function Get-Category'),
            $script:original.IndexOf('# untouched-after') - $script:original.IndexOf('function Get-Category')).TrimEnd()
        foreach ($slot in 1..5) {
            $text = $entry + [Environment]::NewLine + [Environment]::NewLine +
                "function Get-NoOpHelper$slot { return 1 }"
            $file = Join-Path $TestDrive "noop-$slot.ps1"
            [IO.File]::WriteAllText($file, $text)
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $file -ProjectPath $script:project
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project -Apply
        $result.validation.winner_passed | Should -BeFalse
        $result.improved | Should -BeFalse
        $result.applied | Should -BeFalse
        @($result.candidates | Where-Object eligible).Count | Should -Be 0
        $result.validation.tested_count | Should -Be 0
        [IO.File]::ReadAllText($script:target) | Should -BeExactly $script:original
    }

    It 'rejects a stale source fingerprint before evaluating candidates' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split
        Add-Content -LiteralPath $script:target -Value '# outside edit'
        { Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project -Apply } |
            Should -Throw '*source changed*'
        (Get-PSPruneBatch -Id $batch.id -Path $script:project).status | Should -Be 'open'
    }

    It 'runs focused tests for all proposals and the full suite only for the winner' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split -TestPath 'tests/Focused.Tests.ps1' -RegressionTestPath 'tests'
        foreach ($slot in 1..5) {
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath (Join-Path $script:sourceCandidates "candidate-$slot.txt") -ProjectPath $script:project
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project -Apply
        $result.applied | Should -BeTrue
        $result.validation.winner_passed | Should -BeTrue
        $result.validation.winner_regression_passed | Should -BeTrue
        $result.validation.regression_test_path | Should -BeExactly 'tests'
        @($result.candidates | Where-Object passed).Count | Should -Be 1
        @($result.candidates | Where-Object { $null -ne $_.test_duration_ms }).Count | Should -Be 1
        @($result.candidates | Where-Object { $_.regression_passed -eq $true }).Count | Should -Be 1
        @($result.candidates | Where-Object { $null -ne $_.regression_duration_ms }).Count | Should -Be 1
    }

    It 'falls back to the next eligible candidate after a full-regression failure' {
        $batch = New-PSPruneBatch -Path $script:target -FunctionName Get-Category -ProjectPath $script:project -Mode Split -TestPath 'tests/Focused.Tests.ps1' -RegressionTestPath 'tests' -MaxRegressionCandidates 2
        foreach ($slot in 1..5) {
            $file = Join-Path $script:sourceCandidates "candidate-$slot.txt"
            if ($slot -eq 1) {
                $wrong = Join-Path $TestDrive 'miss-boundary.ps1'
                $text = [IO.File]::ReadAllText($file)
                [IO.File]::WriteAllText($wrong, $text.Replace('-le -100', '-lt -100'))
                $file = $wrong
            }
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $file -ProjectPath $script:project
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project -Apply
        $result.applied | Should -BeTrue
        $result.selected_slot | Should -Be 2
        $result.validation.winner_passed | Should -BeTrue
        $result.validation.winner_regression_passed | Should -BeTrue
        $result.candidates[0].regression_passed | Should -BeFalse
        $result.candidates[0].eligible | Should -BeFalse
        $result.candidates[1].regression_passed | Should -BeTrue
        $result.candidates[0].error | Should -Match 'Full regression failed'
    }

}
