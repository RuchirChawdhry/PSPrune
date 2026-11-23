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

    $existing = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $target = Join-Path $Root $Batch.target.file
    foreach ($path in Get-ChildItem -LiteralPath $Root -File -Recurse |
        Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
        $relative = [IO.Path]::GetRelativePath($Root, $path.FullName).Replace('\', '/')
        if ($relative -match '(^|/)(\.git|\.psprune|tests|experiments|node_modules)(/|$)') {
            continue
        }
        $text = if ($path.FullName -eq $target) { $Source } else {
            [IO.File]::ReadAllText($path.FullName)
        }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput(
            $text, [ref]$tokens, [ref]$errors
        )
        if ($errors.Count) { continue }
        foreach ($definition in $ast.EndBlock.Statements) {
            if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
                $null = $existing.Add($definition.Name)
            }
        }
    }
    foreach ($helper in $Group.Helpers) {
        if ($existing.Contains($helper.Name)) {
            throw "Helper '$($helper.Name)' collides with an existing project function."
        }
    }

    # Refuse modules with implicit or wildcard public function exports.
    foreach ($module in Get-ChildItem -LiteralPath $Root -Filter '*.psm1' -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($Root, $module.FullName).Replace('\', '/')
        if ($relative -match '(^|/)(\.git|\.psprune|tests|experiments|node_modules)(/|$)') {
            continue
        }
        $manifestPath = [IO.Path]::ChangeExtension($module.FullName, '.psd1')
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Split mode requires an explicit module export manifest for '$relative'."
        }
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
        $exports = @($manifest.FunctionsToExport)
        if (-not $exports.Count -or @($exports | Where-Object { $_ -match '[*?]' }).Count) {
            throw "Module '$relative' must declare an explicit, non-wildcard FunctionsToExport list."
        }
        foreach ($helper in $Group.Helpers) {
            if ($helper.Name -in $exports) {
                throw "Helper '$($helper.Name)' conflicts with a module export."
            }
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
        functions = $scores
    }
}
