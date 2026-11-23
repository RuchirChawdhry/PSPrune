Set-StrictMode -Version Latest

function Get-PSPruneAst {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FunctionName,
        [switch]$SingleFunction
    )

    $tokens = $null
    $parseErrors = $null
    $root = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source, [ref]$tokens, [ref]$parseErrors
    )
    if ($parseErrors.Count) {
        throw "Invalid PowerShell syntax: $($parseErrors[0].Message)"
    }

    $statements = @($root.EndBlock.Statements)
    $definitions = @($statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -eq $FunctionName
    })

    if ($definitions.Count -ne 1) {
        throw "Expected one top-level function named '$FunctionName'; found $($definitions.Count)."
    }
    if ($SingleFunction -and $statements.Count -ne 1) {
        throw 'Each candidate must contain exactly one top-level function and no other statements.'
    }

    return $definitions[0]
}

function Get-PSPruneReport {
    <#
    .SYNOPSIS
    Return per-function complexity measurements for a PowerShell file or directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 100000)][int]$Top,
        [ValidateSet('Cognitive', 'Cyclomatic')][string]$Metric = 'Cognitive'
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $isDirectory = (Get-Item -LiteralPath $resolved).PSIsContainer
    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop

    $records = @(Measure-PSComplexity -Path $resolved -Recurse:$isDirectory -ErrorAction Stop |
        Where-Object { $_.Unit -ne '<script-body>' })

    $functions = @($records | ForEach-Object {
        $absoluteFile = [IO.Path]::GetFullPath([string]$_.File, (Get-Location).ProviderPath)
        [pscustomobject]@{
            Name          = [string]$_.Unit
            File          = $absoluteFile
            Directory     = [IO.Path]::GetDirectoryName($absoluteFile)
            Line          = [int]$_.Line
            Cyclomatic    = [int]$_.Cyclomatic
            Cognitive     = [int]$_.Cognitive
            MetricVersion = [int]$_.MetricVersion
        }
    })

    $ordered = @(
        if ($Metric -eq 'Cyclomatic') {
            $functions | Sort-Object Cyclomatic, Cognitive -Descending
        }
        else {
            $functions | Sort-Object Cognitive, Cyclomatic -Descending
        }
    )
    $selected = @(
        if ($PSBoundParameters.ContainsKey('Top')) {
            $ordered | Select-Object -First $Top
        }
        else { $ordered }
    )

    [pscustomobject]@{
        SchemaVersion = 1
        Scope         = $resolved
        Metric        = $Metric
        FunctionCount = $ordered.Count
        ReturnedCount = $selected.Count
        Functions     = $selected
    }
}

function Invoke-PSPrune {
    <#
    .SYNOPSIS
    Verify five function replacements, choose the least complex, and optionally apply it.
    .DESCRIPTION
    Candidate tests execute in separate PowerShell processes, NOT a security sandbox.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Legacy')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Legacy')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Legacy')][string]$FunctionName,
        [Parameter(Mandatory, ParameterSetName = 'Legacy')][string[]]$Candidates,
        [Parameter(Mandatory, ParameterSetName = 'Legacy')][string]$TestScript,
        [Parameter(Mandatory, ParameterSetName = 'Batch')][string]$BatchId,
        [Parameter(ParameterSetName = 'Batch')][string]$ProjectPath = '.',
        [switch]$Apply
    )

    if ($PSCmdlet.ParameterSetName -eq 'Batch') {
        return Invoke-PSPruneBatch -Id $BatchId -ProjectPath $ProjectPath -Apply:$Apply
    }

    if ($Candidates.Count -ne 5) {
        throw 'Exactly five candidate functions are required.'
    }

    $scriptFile = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $testFile = (Resolve-Path -LiteralPath $TestScript -ErrorAction Stop).ProviderPath
    if ((Get-Item -LiteralPath $scriptFile).PSIsContainer) {
        throw 'Path must be a PowerShell script file.'
    }

    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop
    $originalSource = [IO.File]::ReadAllText($scriptFile)
    $originalAst = Get-PSPruneAst -Source $originalSource -FunctionName $FunctionName
    $originalScore = @(Measure-PSComplexity -Path $scriptFile -ErrorAction Stop |
        Where-Object Unit -eq $FunctionName)
    if ($originalScore.Count -ne 1) {
        throw "Cannot uniquely measure original function '$FunctionName'."
    }

    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("psprune-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch -Force
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $results = [Collections.Generic.List[object]]::new()

    try {
        for ($index = 0; $index -lt 5; $index++) {
            $passed = $false
            $reason = $null
            $score = $null
            $proposed = [string]$Candidates[$index]

            try {
                $null = Get-PSPruneAst -Source $proposed -FunctionName $FunctionName -SingleFunction
                $patched = $originalSource.Substring(0, $originalAst.Extent.StartOffset) +
                    $proposed.TrimEnd() +
                    $originalSource.Substring($originalAst.Extent.EndOffset)
                $candidatePath = Join-Path $scratch "candidate-$($index + 1).ps1"
                [IO.File]::WriteAllText($candidatePath, $patched, [text.UTF8Encoding]::new($false))

                $measurements = @(Measure-PSComplexity -Path $candidatePath -ErrorAction Stop |
                    Where-Object Unit -eq $FunctionName)
                if ($measurements.Count -ne 1) {
                    throw "Cannot uniquely measure candidate $($index + 1)."
                }
                $score = $measurements[0]

                $testOutput = & $pwsh -NoProfile -NonInteractive -File $testFile -CandidatePath $candidatePath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Behavior tests failed (exit $LASTEXITCODE): $($testOutput -join ' ')"
                }
                $passed = $true
            }
            catch {
                $reason = $_.Exception.Message
            }

            $results.Add([pscustomobject]@{
                Index      = $index + 1
                Passed     = $passed
                Cyclomatic = if ($null -ne $score) { [int]$score.Cyclomatic } else { $null }
                Cognitive  = if ($null -ne $score) { [int]$score.Cognitive } else { $null }
                Error      = $reason
            })
        }

        $allPassed = @($results | Where-Object Passed).Count -eq 5
        $winner = if ($allPassed) {
            $results | Sort-Object Cognitive, Cyclomatic, Index | Select-Object -First 1
        } else { $null }

        $improved = $null -ne $winner -and (
            $winner.Cognitive -lt $originalScore[0].Cognitive -or (
                $winner.Cognitive -eq $originalScore[0].Cognitive -and
                $winner.Cyclomatic -lt $originalScore[0].Cyclomatic
            )
        )

        $applied = $false
        if ($Apply -and $improved) {
            $proposed = [string]$Candidates[$winner.Index - 1]
            $patched = $originalSource.Substring(0, $originalAst.Extent.StartOffset) +
                $proposed.TrimEnd() +
                $originalSource.Substring($originalAst.Extent.EndOffset)
            [IO.File]::WriteAllText($scriptFile, $patched, [text.UTF8Encoding]::new($false))
            $applied = $true
        }

        [pscustomobject]@{
            SchemaVersion    = 1
            File             = $scriptFile
            Function         = $FunctionName
            AllPassed        = $allPassed
            Original         = [pscustomobject]@{
                Cyclomatic = [int]$originalScore[0].Cyclomatic
                Cognitive  = [int]$originalScore[0].Cognitive
            }
            Candidates       = $results.ToArray()
            SelectedIndex    = if ($null -ne $winner) { $winner.Index } else { $null }
            Improved         = [bool]$improved
            Applied          = $applied
        }
    }
    finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}

. (Join-Path $PSScriptRoot 'Batch.Storage.ps1')
. (Join-Path $PSScriptRoot 'Batch.Invoke.ps1')
. (Join-Path $PSScriptRoot 'Batch.Clean.ps1')
. (Join-Path $PSScriptRoot 'Selection.ps1')
. (Join-Path $PSScriptRoot 'Group.Parse.ps1')
. (Join-Path $PSScriptRoot 'Group.Invoke.ps1')
. (Join-Path $PSScriptRoot 'Git.Report.ps1')

Export-ModuleMember -Function @(
    'Get-PSPruneReport',
    'Get-PSPruneCommitReport',
    'Invoke-PSPrune',
    'New-PSPruneBatch',
    'Get-PSPruneBatch',
    'Get-PSPruneHistory',
    'Submit-PSPruneCandidate',
    'Clear-PSPruneArtifacts'
)
