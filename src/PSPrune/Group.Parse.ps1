function Get-PSPruneGroup {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$FunctionName
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Source, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count) { throw "Invalid candidate syntax: $($errors[0].Message)" }
    if ($ast.UsingStatements.Count -or $ast.ParamBlock -or
        $Source -match '(?m)^\s*#requires\b') {
        throw 'A split candidate must not contain using statements, script parameters, or #requires.'
    }

    $functions = @($ast.EndBlock.Statements)
    if ($functions.Count -lt 2) {
        throw 'Split candidates require an entry point and at least one helper.'
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($function in $functions) {
        if ($function -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
            throw 'Split candidates may contain only top-level function definitions.'
        }
        if (-not $names.Add($function.Name)) {
            throw "Duplicate candidate function: '$($function.Name)'."
        }
        if ($function.Name.Contains(':') -or $function.Name.Contains('\')) {
            throw 'Scoped or provider-qualified function names are not supported in Split mode.'
        }
        $nested = @($function.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object { $_ -ne $function })
        if ($nested.Count) {
            throw "Nested functions are not supported in Split mode: '$($function.Name)'."
        }
    }
    $entry = @($functions | Where-Object Name -eq $FunctionName)
    if ($entry.Count -ne 1) {
        throw "A split candidate must contain exactly one '$FunctionName' entry point."
    }
    [pscustomobject]@{
        Entry = $entry[0]
        Helpers = @($functions | Where-Object Name -ne $FunctionName)
        Functions = $functions
    }
}

function Get-PSPruneFunctionAttribute {
    param([Parameter(Mandatory)]$FunctionAst)
    if (-not $FunctionAst.Body.ParamBlock) { return '' }
    @($FunctionAst.Body.ParamBlock.Attributes | ForEach-Object {
        ($_.Extent.Text -replace '\s+', '').ToLowerInvariant()
    }) -join ';'
}

function Assert-PSPruneSplitBoundary {
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)]$Batch,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Source
    )

    if ((Get-PSPruneSignature -FunctionAst $Group.Entry) -cne $Batch.target.signature -or
        (Get-PSPruneFunctionAttribute -FunctionAst $Group.Entry) -cne $Batch.target.attributes -or
        [bool]$Group.Entry.IsFilter -ne [bool]$Batch.target.is_filter) {
        throw 'Split entry point changed its parameter or command contract.'
    }

    $index = $Batch.project_index
    if ($null -eq $index) {
        $index = Get-PSPruneProjectIndex -Root $Root
    }
    if (@($index.unguarded_modules).Count) {
        throw "Split mode requires explicit module exports: $(@($index.unguarded_modules) -join ', ')"
    }
    foreach ($helper in $Group.Helpers) {
        if ($helper.Name -in @($index.names)) {
            throw "Helper '$($helper.Name)' collides with an existing project function."
        }
        if ($helper.Name -in @($index.exports)) {
            throw "Helper '$($helper.Name)' conflicts with a module export."
        }
    }
}

function Get-PSPruneSplitScore {
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][string]$File
    )

    $measurements = @(Measure-PSComplexity -Path $File -ErrorAction Stop)
    $scores = @(
        foreach ($definition in $Group.Functions) {
            $match = @($measurements | Where-Object Unit -eq $definition.Name)
            if ($match.Count -ne 1) {
                throw "Expected exactly one complexity score for '$($definition.Name)'."
            }
            [pscustomobject]@{
                name = [string]$definition.Name
                cognitive = [int]$match[0].Cognitive
                cyclomatic = [int]$match[0].Cyclomatic
                sha256 = Get-PSPruneDigest -Text $definition.Extent.Text
            }
        }
    )
    $totalCognitive = [int](($scores | Measure-Object cognitive -Sum).Sum)
    $totalCyclomatic = [int](($scores | Measure-Object cyclomatic -Sum).Sum)
    $maxCognitive = [int](($scores | Measure-Object cognitive -Maximum).Maximum)
    [pscustomobject]@{
        total_cognitive = $totalCognitive
        max_cognitive = $maxCognitive
        adjusted_cyclomatic = $totalCyclomatic - ($scores.Count - 1)
        helper_count = $scores.Count - 1
        concentration_score = Get-PSPruneConcentrationScore -CognitiveScores @($scores | ForEach-Object cognitive)
        helper_penalty = 25
        functions = $scores
    }
}
