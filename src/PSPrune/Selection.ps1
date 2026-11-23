function Get-PSPruneConcentrationScore {
    param(
        [Parameter(Mandatory)][int[]]$CognitiveScores,
        [ValidateRange(0, 100000)][int]$HelperPenalty = 25
    )
    if (-not $CognitiveScores.Count) { throw 'At least one cognitive score is required.' }
    $squared = 0L
    foreach ($score in $CognitiveScores) {
        $squared += [long]$score * $score
    }
    $squared + [long]$HelperPenalty * ($CognitiveScores.Count - 1)
}

function Get-PSPruneProjectIndex {
    param([Parameter(Mandatory)][string]$Root)

    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $exports = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $unguarded = [Collections.Generic.List[string]]::new()

    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse |
        Where-Object { $_.Extension -in '.ps1', '.psm1' })
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        if ($relative -match '(^|/)(\.git|\.psprune|tests|experiments|node_modules|dist)(/|$)') {
            continue
        }

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$tokens, [ref]$errors
        )
        if (-not $errors.Count) {
            foreach ($definition in $ast.EndBlock.Statements) {
                if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
                    $null = $names.Add($definition.Name)
                }
            }
        }

        if ($file.Extension -ne '.psm1') { continue }
        $manifestPath = [IO.Path]::ChangeExtension($file.FullName, '.psd1')
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $unguarded.Add($relative)
            continue
        }
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
        $declared = @($manifest.FunctionsToExport)
        if (-not $declared.Count -or @($declared | Where-Object { $_ -match '[*?]' }).Count) {
            $unguarded.Add($relative)
            continue
        }
        foreach ($name in $declared) { $null = $exports.Add($name) }
    }

    [pscustomobject]@{
        names = @($names | Sort-Object)
        exports = @($exports | Sort-Object)
        unguarded_modules = @($unguarded)
    }
}

function Resolve-PSPruneTestPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FunctionName,
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $path = [IO.Path]::GetFullPath($ExplicitPath, $Root)
        if (-not (Test-Path -LiteralPath $path)) { throw "TestPath does not exist: $path" }
        return [pscustomobject]@{
            Path = [IO.Path]::GetRelativePath($Root, $path)
            Discovery = 'explicit'
        }
    }

    $testsRoot = Join-Path $Root 'tests'
    if (-not (Test-Path -LiteralPath $testsRoot -PathType Container)) {
        throw "Cannot discover Pester tests: no tests directory in '$Root'."
    }

    $tests = @(Get-ChildItem -LiteralPath $testsRoot -Recurse -File -Filter '*.Tests.ps1' |
        Where-Object { $_.FullName -notmatch '[/\\]fixtures[/\\]' })
    if (-not $tests.Count) {
        throw "Cannot discover Pester tests in '$testsRoot'."
    }

    $exact = @($tests | Where-Object Name -eq "$FunctionName.Tests.ps1" |
        Sort-Object FullName)
    if ($exact.Count) {
        return [pscustomobject]@{
            Path = [IO.Path]::GetRelativePath($Root, $exact[0].FullName)
            Discovery = 'function-name'
        }
    }

    $escaped = [regex]::Escape($FunctionName)
    $referenced = @($tests | Where-Object {
        [IO.File]::ReadAllText($_.FullName) -match "(?i)(?<![\w-])$escaped(?![\w-])"
    } | Sort-Object FullName)
    if ($referenced.Count) {
        return [pscustomobject]@{
            Path = [IO.Path]::GetRelativePath($Root, $referenced[0].FullName)
            Discovery = 'function-reference'
        }
    }

    [pscustomobject]@{
        Path = 'tests'
        Discovery = 'project-fallback'
    }
}
