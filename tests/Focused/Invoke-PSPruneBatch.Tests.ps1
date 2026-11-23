BeforeAll {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:sourceProject = Join-Path $root 'tests/fixtures/BatchProject'
    Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop
}

Describe 'Invoke-PSPruneBatch focused dispatch and preflight' {
    BeforeEach {
        $script:project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:sourceProject -Destination $script:project -Recurse -Force
        $script:target = Join-Path $script:project 'Example.ps1'
    }

    It 'dispatches regular batches and detects missing candidate slots' {
        $batch = New-PSPruneBatch -ProjectPath $script:project -Path $script:target -FunctionName Get-Label
        { Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project } |
            Should -Throw '*Incomplete batch*'
    }

    It 'dispatches Split batches and detects missing candidate slots' {
        $batch = New-PSPruneBatch -ProjectPath $script:project -Path $script:target -FunctionName Get-Label -Mode Split
        { Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project } |
            Should -Throw '*Incomplete Split batch*'
    }

    It 'rejects a stale original function before executing candidate tests' {
        $batch = New-PSPruneBatch -ProjectPath $script:project -Path $script:target -FunctionName Get-Label
        Add-Content -LiteralPath $script:target -Value '# external change'
        { Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project } |
            Should -Throw '*source changed*'
    }

    It 'rejects a stale Split batch before executing candidate tests' {
        $batch = New-PSPruneBatch -ProjectPath $script:project -Path $script:target -FunctionName Get-Label -Mode Split
        Add-Content -LiteralPath $script:target -Value '# external change'
        { Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:project } |
            Should -Throw '*source changed*'
    }

    It 'refuses malformed batch identifiers' {
        { Invoke-PSPrune -BatchId 'wrong' -ProjectPath $script:project } |
            Should -Throw '*Batch ID*'
    }
}
