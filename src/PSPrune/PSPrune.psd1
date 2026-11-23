@{
    RootModule        = 'PSPrune.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7f56aa55-cd59-46f0-a31b-ed9947dddc92'
    Author            = 'Ruchir Chawdhry'
    Description       = 'Complexity reporting and test-gated function pruning for PowerShell.'
    CompatiblePSEditions = @('Core')
    PowerShellVersion = '7.4'
    FunctionsToExport = @('Get-PSPruneReport', 'Invoke-PSPrune')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
