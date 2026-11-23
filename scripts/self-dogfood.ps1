[CmdletBinding()]
param(
    [string]$BaselineCommit = 'HEAD~1',
    [string]$CurrentCommit = 'HEAD',
    [ValidateRange(1, 100000)][int]$Top = 10,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop

$sourceRoot = Join-Path $root 'src/PSPrune'
$project = Get-PSPruneReport -Path $sourceRoot -Top $Top
$introduced = Get-PSPruneCommitReport -Path $sourceRoot -BaselineCommit $BaselineCommit -CurrentCommit $CurrentCommit -Top $Top

if ($project.FunctionCount -lt 1 -or $project.ReturnedCount -lt 1) {
    throw 'Self-dogfood failed: PSPrune did not discover its own functions.'
}
if ($project.ReturnedCount -gt $Top -or $introduced.ReturnedCount -gt $Top) {
    throw 'Self-dogfood failed: top-N constraint was ignored.'
}
if (@($project.Functions | Where-Object { $_.Cyclomatic -lt 1 }).Count) {
    throw 'Self-dogfood failed: invalid complexity score in source report.'
}
if (@($introduced.Functions | Where-Object ChangeType -ne 'Added').Count) {
    throw 'Self-dogfood failed: commit report contains functions not classified as newly added.'
}

Write-Host 'PSPrune self-analysis — top current functions:'
$project.Functions |
    Select-Object Name, Cognitive, Cyclomatic, Line, File |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Host 'PSPrune self-analysis — top newly introduced functions:'
$introduced.Functions |
    Select-Object Name, Cognitive, Cyclomatic, Line, File |
    Format-Table -AutoSize | Out-String | Write-Host

$result = [pscustomobject]@{
    SchemaVersion = 1
    Mode = 'self-dogfood'
    Project = $project
    Introduced = $introduced
}
if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $target = [IO.Path]::GetFullPath($OutFile)
    $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
    $result | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $target -Encoding utf8
}
$result
