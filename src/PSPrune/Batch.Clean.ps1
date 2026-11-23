function Clear-PSPruneArtifacts {
    <#
    .SYNOPSIS
    Manually remove disposable batch directories, never the permanent manifest.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Intentional collection-wide command name established in PSPrune API')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string]$Path = '.',
        [string]$BatchId,
        [switch]$Completed
    )
    $root = Get-PSPruneRoot -Path $Path
    $store = Get-PSPruneStore -Root $root
    if ($PSBoundParameters.ContainsKey('BatchId')) {
        Assert-PSPruneId -Id $BatchId
    }
    $lock = Enter-PSPruneLock -Store $store
    try {
        $history = @(Get-PSPruneHistory -Path $root)
        $batchRoot = Join-Path $store 'batches'
        if (-not (Test-Path -LiteralPath $batchRoot)) { return }
        $directories = @(Get-ChildItem -LiteralPath $batchRoot -Directory -Force |
            Where-Object { -not $BatchId -or $_.Name -ceq $BatchId })
        foreach ($directory in $directories) {
            $records = @($history | Where-Object Id -eq $directory.Name)
            if ($records.Count -ne 1 -or
                $directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                [pscustomobject]@{
                    Id = $directory.Name
                    Status = 'protected'
                    Removed = $false
                }
                continue
            }
            $removed = $PSCmdlet.ShouldProcess($directory.FullName, 'Delete disposable batch directory')
            if ($removed) {
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
            }
            [pscustomobject]@{
                Id = $directory.Name
                Status = if ($removed) { 'removed' } elseif ($WhatIfPreference) { 'whatif' } else { 'skipped' }
                Removed = [bool]$removed
            }
        }
    }
    finally { $lock.Dispose() }
}
