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
        [Parameter(Mandatory)][string]$Root
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

function Measure-PSPruneSplitCandidate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Slot,
        [Parameter(Mandatory)]$Batch,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)]$Definition
    )

    $text = [IO.File]::ReadAllText($Path)
    $result = [ordered]@{
        slot = $Slot
        sha256 = Get-PSPruneFileDigest -Path $Path
        passed = $null
        tested = $false
        eligible = $false
        total_cognitive = $null
        concentration_score = $null
        max_cognitive = $null
        adjusted_cyclomatic = $null
        helper_count = $null
        functions = @()
        score_duration_ms = $null
        test_duration_ms = $null
        regression_passed = $null
        regression_duration_ms = $null
        error = $null
    }

    try {
        $scoreWatch = [Diagnostics.Stopwatch]::StartNew()
        $group = Get-PSPruneGroup -Source $text -FunctionName $Batch.target.function
        Assert-PSPruneSplitBoundary -Group $group -Batch $Batch -Root $Root
        $replacement = $Source.Substring(0, $Definition.Extent.StartOffset) +
            $text.TrimEnd() +
            $Source.Substring($Definition.Extent.EndOffset)
        $temporary = Join-Path ([IO.Path]::GetTempPath()) (
            'psprune-split-score-' + [guid]::NewGuid().ToString('N') +
            [IO.Path]::GetExtension($Batch.target.file)
        )
        try {
            [IO.File]::WriteAllText($temporary, $replacement, [Text.UTF8Encoding]::new($false))
            $issues = @(Invoke-ScriptAnalyzer -Path $temporary -Severity Error -ErrorAction Stop)
            if ($issues.Count) {
                throw "PSScriptAnalyzer rejected candidate: $($issues[0].Message)"
            }
            $score = Get-PSPruneSplitScore -Group $group -File $temporary
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        }

        $scoreWatch.Stop()
        $result.score_duration_ms = $scoreWatch.ElapsedMilliseconds
        $result.total_cognitive = $score.total_cognitive
        $result.concentration_score = $score.concentration_score
        $result.max_cognitive = $score.max_cognitive
        $result.adjusted_cyclomatic = $score.adjusted_cyclomatic
        $result.helper_count = $score.helper_count
        $result.functions = $score.functions

        $result.eligible = $score.concentration_score -lt $Batch.original.concentration_score
        [pscustomobject]@{
            Result = [pscustomobject]$result
            Replacement = $replacement
        }
    }
    catch {
        $result.error = $_.Exception.Message
        [pscustomobject]@{
            Result = [pscustomobject]$result
            Replacement = $null
        }
    }
}

function Invoke-PSPruneSplitBatch {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ProjectPath,
        [switch]$Apply
    )

    $root = Get-PSPruneRoot -Path $ProjectPath
    $directory = Get-PSPruneBatchPath -Root $root -Id $Id
    $batch = Get-PSPruneJson -Path (Join-Path $directory 'manifest.json')
    if ($batch.mode -ne 'Split' -or $batch.status -ne 'open') {
        throw "Batch '$Id' is not an open Split batch."
    }

    $target = Join-Path $root $batch.target.file
    if ((Get-PSPruneFileDigest -Path $target) -cne $batch.target.file_sha256) {
        throw 'Original source changed after batch creation. Refusing stale batch.'
    }
    $source = [IO.File]::ReadAllText($target)
    $definition = Get-PSPruneAst -Source $source -FunctionName $batch.target.function
    if ((Get-PSPruneDigest -Text $definition.Extent.Text) -cne $batch.target.source_sha256) {
        throw 'Original function fingerprint changed after batch creation.'
    }

    $paths = @(1..5 | ForEach-Object { Join-Path $directory "candidate-$_.ps1" })
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Incomplete Split batch: missing $path"
        }
    }

    $timeout = if ($batch.test_timeout_seconds) { [int]$batch.test_timeout_seconds } else { 300 }
    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    # Rank candidates without running any of them.
    $evaluations = @(for ($slot = 1; $slot -le 5; $slot++) {
        Measure-PSPruneSplitCandidate -Path $paths[$slot - 1] -Slot $slot -Batch $batch -Root $root -Source $source -Definition $definition
    })
    $candidates = @($evaluations | ForEach-Object Result)
    $ranked = @($candidates | Where-Object eligible |
        Sort-Object concentration_score, max_cognitive, helper_count, slot)

    $winner = $null
    $replacement = $null
    foreach ($proposal in $ranked) {
        $candidateReplacement = @($evaluations |
            Where-Object { $_.Result.slot -eq $proposal.slot })[0].Replacement

        $test = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.test_path -RelativeTargetPath $batch.target.file -Replacement $candidateReplacement -TimeoutSeconds $timeout
        $proposal.tested = $true
        $proposal.passed = $test.Passed
        $proposal.test_duration_ms = $test.DurationMs
        if (-not $test.Passed) {
            $proposal.eligible = $false
            $proposal.error = "Focused Pester failed: $($test.Error)"
            continue
        }

        if ($batch.regression_test_path) {
            $verified = Invoke-PSPrunePester -ProjectRoot $root -RelativeTestPath $batch.regression_test_path -RelativeTargetPath $batch.target.file -Replacement $candidateReplacement -TimeoutSeconds $timeout
            $proposal.regression_passed = $verified.Passed
            $proposal.regression_duration_ms = $verified.DurationMs
            if (-not $verified.Passed) {
                $proposal.eligible = $false
                $proposal.error = "Full regression failed: $($verified.Error)"
                continue
            }
        }

        $winner = $proposal
        $replacement = $candidateReplacement
        break
    }

    Complete-PSPruneBatch -Batch $batch -Root $root -Candidates $candidates -Winner $winner -Replacement $replacement -Apply:$Apply
}
