BeforeAll {
    . (Join-Path $PSScriptRoot '../Category.ps1')
}

Describe 'focused Get-Category behavior' {
    It 'preserves commonly used categories' {
        (Get-Category -Number -1) | Should -BeExactly 'negative'
        (Get-Category -Number 0) | Should -BeExactly 'zero'
        (Get-Category -Number 8) | Should -BeExactly 'positive'
        (Get-Category -Number 150) | Should -BeExactly 'large'
    }
}
