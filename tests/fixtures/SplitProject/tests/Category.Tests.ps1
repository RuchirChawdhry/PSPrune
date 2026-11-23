BeforeAll {
    . (Join-Path $PSScriptRoot '../Category.ps1')
}

Describe 'split function group behavior' {
    It 'preserves negative boundary conditions' {
        (Get-Category -Number -501) | Should -BeExactly 'extreme-negative'
        (Get-Category -Number -401) | Should -BeExactly 'severe-negative'
        (Get-Category -Number -301) | Should -BeExactly 'moderately-negative'
        (Get-Category -Number -201) | Should -BeExactly 'strong-negative'
        (Get-Category -Number -101) | Should -BeExactly 'very-negative'
        (Get-Category -Number -100) | Should -BeExactly 'very-negative'
        (Get-Category -Number -99) | Should -BeExactly 'negative'
        (Get-Category -Number -1) | Should -BeExactly 'negative'
    }
    It 'preserves zero and positive behavior' {
        (Get-Category -Number 0) | Should -BeExactly 'zero'
        (Get-Category -Number 1) | Should -BeExactly 'positive'
        (Get-Category -Number 99) | Should -BeExactly 'positive'
        (Get-Category -Number 100) | Should -BeExactly 'large'
    }
    It 'preserves unrelated definitions' {
        (Get-Unchanged) | Should -BeExactly 'unchanged'
    }
}
