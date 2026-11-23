BeforeAll {
    . (Join-Path $PSScriptRoot '../Example.ps1')
}

Describe 'Get-Label project behavior' {
    It 'categorizes negative values' {
        (Get-Label -Number -1) | Should -BeExactly 'negative'
    }
    It 'categorizes zero' {
        (Get-Label -Number 0) | Should -BeExactly 'zero'
    }
    It 'categorizes positive values' {
        (Get-Label -Number 8) | Should -BeExactly 'positive'
    }
    It 'categorizes large values' {
        (Get-Label -Number 150) | Should -BeExactly 'large'
    }
    It 'preserves unrelated functions' {
        (Get-Other) | Should -BeExactly 'unchanged'
    }
}
