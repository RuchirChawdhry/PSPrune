function Get-PSPruneGitText {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$File
    )

    $revisionPath = '{0}:{1}' -f $Commit, $File
    $lines = @(& git -C $Repository show $revisionPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read '$File' from Git commit '$Commit': $($lines -join ' ')"
    }
    $lines -join [Environment]::NewLine
}

function Get-PSPruneGitFunctions {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$File
    )

    $tokens = $null
    $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseInput(
        $Source, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count) {
        throw "Cannot score '$File': PowerShell parse error: $($errors[0].Message)"
    }
    @($tree.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst]
    })
}

function Get-PSPruneCommitReport {
    <#
    .SYNOPSIS
    Score functions newly introduced between two Git commits.
    .DESCRIPTION
    Reads committed PowerShell files from Git objects, not from the working tree.
    Existing function names in the same file are not classified as new functions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaselineCommit,
        [Parameter(Mandatory)][string]$CurrentCommit,
        [string]$Path = '.',
        [ValidateRange(1, 100000)][int]$Top,
        [ValidateSet('Cognitive', 'Cyclomatic')][string]$Metric = 'Cognitive'
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $directory = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
    $repoText = @(& git -C $directory rev-parse --show-toplevel 2>&1)
    if ($LASTEXITCODE -ne 0 -or $repoText.Count -ne 1) {
        throw "'$Path' is not inside a Git repository."
    }
    $repository = [string]$repoText[0]
    $scope = [IO.Path]::GetRelativePath($repository, $item.FullName).Replace('\', '/')
    $baseline = @(& git -C $repository rev-parse --verify --end-of-options "$BaselineCommit^{commit}" 2>&1)
    if ($LASTEXITCODE -ne 0 -or $baseline.Count -ne 1) {
        throw "Invalid baseline Git commit '$BaselineCommit'."
    }
    $current = @(& git -C $repository rev-parse --verify --end-of-options "$CurrentCommit^{commit}" 2>&1)
    if ($LASTEXITCODE -ne 0 -or $current.Count -ne 1) {
        throw "Invalid current Git commit '$CurrentCommit'."
    }
    $baselineSha = [string]$baseline[0]
    $currentSha = [string]$current[0]

    $changedPaths = @(& git -C $repository -c core.quotePath=false diff --no-renames --name-only --diff-filter=AM $baselineSha $currentSha -- $scope)
    if ($LASTEXITCODE -ne 0) { throw 'Git could not compare the requested commits.' }
    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop

    $records = [Collections.Generic.List[object]]::new()
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('psprune-git-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch -Force
    try {
        $fileIndex = 0
        foreach ($file in $changedPaths) {
            if ([IO.Path]::GetExtension($file) -notin '.ps1', '.psm1') { continue }
            $text = Get-PSPruneGitText -Repository $repository -Commit $currentSha -File $file
            $currentFunctions = @(Get-PSPruneGitFunctions -Source $text -File $file)
            if (-not $currentFunctions.Count) { continue }

            $oldPaths = @(& git -C $repository -c core.quotePath=false ls-tree -r --name-only $baselineSha -- $file)
            if ($LASTEXITCODE -ne 0) { throw "Cannot inspect baseline tree for '$file'." }
            $baselineNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($oldPaths.Count -gt 0) {
                $oldText = Get-PSPruneGitText -Repository $repository -Commit $baselineSha -File $file
                $oldFunctions = @(Get-PSPruneGitFunctions -Source $oldText -File $file)
                foreach ($definition in $oldFunctions) {
                    $null = $baselineNames.Add($definition.Name)
                }
            }

            $added = @($currentFunctions | Where-Object { -not $baselineNames.Contains($_.Name) })
            if (-not $added.Count) { continue }
            $fileIndex++
            $snapshot = Join-Path $scratch "$fileIndex$([IO.Path]::GetExtension($file))"
            [IO.File]::WriteAllText($snapshot, $text, [Text.UTF8Encoding]::new($false))
            $measurements = @(Measure-PSComplexity -Path $snapshot -ErrorAction Stop)
            foreach ($definition in $added) {
                $scores = @($measurements | Where-Object Unit -eq $definition.Name)
                if ($scores.Count -ne 1) {
                    throw "Expected exactly one complexity measurement for '$($definition.Name)' in '$file'."
                }
                $records.Add([pscustomobject]@{
                    Name = [string]$definition.Name
                    File = [string]$file
                    Directory = [IO.Path]::GetDirectoryName($file)
                    Line = [int]$definition.Extent.StartLineNumber
                    ChangeType = 'Added'
                    Cyclomatic = [int]$scores[0].Cyclomatic
                    Cognitive = [int]$scores[0].Cognitive
                    MetricVersion = [int]$scores[0].MetricVersion
                })
            }
        }
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force }

    $ordered = if ($Metric -eq 'Cyclomatic') {
        @($records | Sort-Object Cyclomatic, Cognitive -Descending)
    }
    else {
        @($records | Sort-Object Cognitive, Cyclomatic -Descending)
    }
    $selected = if ($PSBoundParameters.ContainsKey('Top')) {
        @($ordered | Select-Object -First $Top)
    }
    else { $ordered }

    [pscustomobject]@{
        SchemaVersion = 1
        Repository = $repository
        Scope = $scope
        BaselineCommit = $baselineSha
        CurrentCommit = $currentSha
        Metric = $Metric
        FunctionCount = $ordered.Count
        ReturnedCount = $selected.Count
        Functions = $selected
    }
}
