BeforeAll {
    . (Join-Path $PSScriptRoot '../Example.ps1')
}

Describe 'focused Get-Label behavior' {
    It 'returns the expected category for representative inputs' {
        (Get-Label -Number -1) | Should -BeExactly 'negative'
        (Get-Label -Number 0) | Should -BeExactly 'zero'
        (Get-Label -Number 3) | Should -BeExactly 'positive'
        (Get-Label -Number 120) | Should -BeExactly 'large'
    }
}
