# PSPrune

**PSPrune** is a PowerShell-first tool for reducing the complexity of agent-generated PowerShell code without changing its tested behavior.

It uses [PSComplexity](https://github.com/Fortigi/PSComplexity) for cyclomatic and cognitive scoring, and **does not replace PSScriptAnalyzer**.

## Current bootstrap

This repository begins with a small, testable contract:

- `Get-PSPruneReport` returns per-function complexity scores, file paths, directories, and line numbers for a script or project.
- `Invoke-PSPrune` accepts **exactly five** proposed replacements for one named top-level function.
- Each candidate must parse as exactly one function, is spliced into a temporary copy of the original file, and must pass an independent PowerShell test subprocess.
- PSComplexity scores each passing candidate. The least cognitively complex candidate wins; cyclomatic complexity breaks ties.
- **No file is changed by default.** `-Apply` changes the selected function only, and only if all five candidates pass their tests.
- A live model provider is **not yet implemented**. Candidate sources are injected, so CI runs deterministic end-to-end tests without inference, credentials, or a network model API.

This is a functional initial seam, not a complete autonomous agent implementation.

## Requirements

- PowerShell 7.4+
- [PSComplexity](https://github.com/Fortigi/PSComplexity), version 0.7.1 or newer, for measurement/refactoring
- Pester 6.2.0 and PSScriptAnalyzer for development/CI

```powershell
Install-PSResource PSComplexity -Version 0.7.1 -Scope CurrentUser -TrustRepository
Import-Module ./src/PSPrune/PSPrune.psd1

# Default: native PowerShell object, including a Functions object array
$report = Get-PSPruneReport -Path ./src
$report.Functions | Sort-Object Cognitive -Descending | Select-Object -First 10

# Opt-in JSON: standard PowerShell serialization
Get-PSPruneReport -Path ./src | ConvertTo-Json -Depth 8
```

Both `Get-PSPruneReport` and `Invoke-PSPrune` emit native `[pscustomobject]` values.
Nested functions, candidate results, and scores remain PowerShell objects and arrays.
The commands do not emit JSON strings, implement a custom JSON serializer, or expose a
JSON output switch. Use `| ConvertTo-Json -Depth 8` when an agent or other consumer
needs JSON. This makes sorting, filtering, and `Select-Object` work normally.

## Deterministic smoke test

```powershell
# The smoke harness also returns one native PowerShell object
./scripts/smoke.ps1

# Optional JSON artifact for CI
./scripts/smoke.ps1 -OutFile reports/smoke.json

# Or serialize the returned object directly
./scripts/smoke.ps1 | ConvertTo-Json -Depth 12
```

This loads five local candidate fixtures, runs real behavior checks in child PowerShell processes, measures actual complexity, verifies that the source file stays unchanged in dry-run mode, and returns a structured native PowerShell object. JSON is written only when requested with `-OutFile` or PowerShell's `ConvertTo-Json` command. It deliberately exercises production code rather than simulating a green result.

## CI

[GitHub Actions](.github/workflows/ci.yml) uses GitHub's `ubuntu-slim` runner, with PowerShell 7 installed on the image. It reuses the pinned [ci-workflows PowerShell module pipeline](https://github.com/RuchirChawdhry/ci-workflows/blob/main/.github/workflows/powershell-module.yml) for parsing, PSScriptAnalyzer, Pester, and independently validated ZIP packaging. A second job runs the smoke test with fixed candidate files and uploads the JSON report. **Neither job calls an LLM.**

The test script contract is `param([string]$CandidatePath)`: it dotsources the temporary candidate file, asserts behavior, and exits nonzero on failure. Candidate execution is not a security sandbox; only use trusted proposals until process/container isolation is implemented.

## v0.2 — Agent-owned candidate generation

PSPrune never invokes an LLM. One or more coding agents generate five alternatives
for a single function, and PSPrune validates their ownership, signature, behavior
and complexity. Each batch has five numbered slots. Slots identify proposals, not
agents; one agent can generate all five or five agents can generate one each.

The complete lifecycle:

```powershell
$batch = New-PSPruneBatch -Path ./src/Network.psm1 -FunctionName Get-NetworkInfo -ProjectPath . -TestPath tests

# Each agent writes its own proposal to a temporary file.
Submit-PSPruneCandidate -Id $batch.id -Slot 1 -SourcePath ./proposal-1.ps1
Submit-PSPruneCandidate -Id $batch.id -Slot 2 -SourcePath ./proposal-2.ps1
Submit-PSPruneCandidate -Id $batch.id -Slot 3 -SourcePath ./proposal-3.ps1
Submit-PSPruneCandidate -Id $batch.id -Slot 4 -SourcePath ./proposal-4.ps1
Submit-PSPruneCandidate -Id $batch.id -Slot 5 -SourcePath ./proposal-5.ps1

# PSPrune runs the existing Pester suite in separate project copies.
$result = Invoke-PSPrune -BatchId $batch.id -ProjectPath . -Apply

# Native objects by default; opt into JSON through the usual pipeline.
$result.candidates | Sort-Object cognitive
Get-PSPruneHistory -Path ./src | Sort-Object CompletedAt -Descending
$result | ConvertTo-Json -Depth 12

# Manual cleanup never deletes permanent history.
Clear-PSPruneArtifacts -Path . -WhatIf
Clear-PSPruneArtifacts -Path . -Completed -Confirm:$false
```

### Storage

```text
.psprune/
  manifest.json                 # Permanent batch history; never pruned
  batches/
    <uuid>/
      manifest.json             # Disposable working status
      candidate-1.ps1 ... candidate-5.ps1
```

PSPrune owns the metadata. Candidate submission is an exclusive, atomic move
into the assigned slot. Completed batches are copied to permanent history;
manual pruning removes only batch directories already recorded in that history.
The master manifest is updated using a cross-process lock and same-directory
atomic replacement. Function/file SHA-256 fingerprints prevent stale application.
Git remains the source of truth for changes to code. Never run untrusted
candidate code or tests: subprocess isolation is **not** a security sandbox.

To reproduce the v0.2 offline end-to-end test without inference:

```powershell
./scripts/batch-smoke.ps1
./scripts/batch-smoke.ps1 | ConvertTo-Json -Depth 16
```

## Highest-complexity functions

Rank a complete script or project by **cognitive complexity** (the default),
with cyclomatic complexity as a tie-breaker. The report remains one native
PowerShell object with a Functions array and an unfiltered FunctionCount.

```powershell
# Highest-scoring functions; use any positive limit
(Get-PSPruneReport -Path ./src -Top 3).Functions
(Get-PSPruneReport -Path ./src -Top 5).Functions
(Get-PSPruneReport -Path ./src -Top 10).Functions

# Prioritize by cyclomatic instead
(Get-PSPruneReport -Path ./src -Top 5 -Metric Cyclomatic).Functions

# Existing pipeline and JSON behavior still work
Get-PSPruneReport -Path ./src -Top 10 | ConvertTo-Json -Depth 8
```

## Functions created between Git commits

Use a baseline and a current commit to find **new top-level functions**
introduced in the interval. The comparison scans the committed file contents,
not the local working tree; uncommitted edits never affect these scores.
Functions with names that already existed in the same path at the baseline
are excluded, even when their implementations changed.

```powershell
$report = Get-PSPruneCommitReport -Path ./src -BaselineCommit HEAD~1 -CurrentCommit HEAD

$report.Functions | Sort-Object Cognitive -Descending

# Focus on the ten most complex newly introduced functions
(Get-PSPruneCommitReport -Path . -BaselineCommit v0.2.0 -CurrentCommit HEAD -Top 10).Functions

# Export explicitly when an agent requires JSON
$report | ConvertTo-Json -Depth 8
```

Each function result includes its name, repository-relative file, line number,
cognitive/cyclomatic scores, and ChangeType = Added. The report also contains
the resolved full baseline/current commit SHA values, total FunctionCount, and
ReturnedCount after applying -Top. A file rename is treated as a newly created
path for this initial implementation. Functions only edited between commits
are not classified as newly introduced.

## v0.3 — Same-file function group refactoring

Use `-Mode Split` when a large function needs to be divided into smaller helpers.
PSPrune still accepts exactly five candidate files, but each file contains one
original entry-point function plus one or more **top-level helper functions**.
Helpers are inserted adjacent to the entry point, in the **same source file**.
No unrelated files are modified, and the existing single-function mode is unchanged.

```powershell
$batch = New-PSPruneBatch -ProjectPath . -Path ./src/Module.psm1 -FunctionName Get-Data -Mode Split

1..5 | ForEach-Object {
    Submit-PSPruneCandidate -Id $batch.id -Slot $_ -SourcePath "./proposals/candidate-$_.ps1"
}

$result = Invoke-PSPrune -BatchId $batch.id -ProjectPath . -Apply
$result.candidates | Sort-Object total_cognitive, adjusted_cyclomatic
Get-PSPruneHistory | Sort-Object CompletedAt -Descending
```

A split candidate contains only function definitions. It must preserve the
entry-point signature and command attributes. Helper names must be unique and
must not collide with existing project functions. For script modules, PSPrune
requires explicit, non-wildcard `FunctionsToExport` in the module manifest so
new helpers cannot silently become exported commands.

The candidate ranking uses **group-level** measurements. A split is eligible
only when its total cognitive complexity **and** highest individual cognitive
complexity decrease, while its *adjusted cyclomatic complexity* does not
increase. Adjusted cyclomatic is the sum of every function's cyclomatic score
minus the number of extracted helpers (accounting for the extra base point
per function). Candidates that satisfy all gates are sorted by total cognitive,
adjusted cyclomatic, maximum cognitive, helper count, and slot. All five
candidates must pass the project Pester suite before selection; candidates also
receive PowerShell syntax, collision, and PSScriptAnalyzer error checks.

The durable master manifest stores each function's hash and complexity values
along with the group metrics. Candidate source remains disposable and stays on
disk until manually cleared with `Clear-PSPruneArtifacts`. A batch rejected
for failing tests or failing to improve the group is retained in history, too.

```powershell
# End-to-end split-mode test, using real Pester cases and an isolated project
./scripts/split-smoke.ps1
```

PSPrune executes submitted code and project tests in subprocesses, which are
**not security sandboxes**. Only submit trusted project code. For now, Split
mode supports same-file extraction only, not new imports or helper files.

## Fast candidate validation (v0.3.1)

Use **function-focused Pester tests** for the five proposals and optionally
verify only the winning proposal against the complete project suite:

```powershell
$batch = New-PSPruneBatch -Path ./src/Batch.ps1 -FunctionName Invoke-Batch -TestPath tests/Focused/Invoke-Batch.Tests.ps1 -RegressionTestPath tests -TestTimeoutSeconds 300 -Mode Split
# Submit five proposals through Submit-PSPruneCandidate
$result = Invoke-PSPrune -BatchId $batch.id -Apply
$result.candidates | Select-Object slot, passed, score_duration_ms, test_duration_ms, regression_passed, regression_duration_ms
```

PSPrune runs the focused Pester tests on the original function and all five
proposals. If every proposal passes, eligible proposals are ranked. Only
the best eligible candidate runs the full regression suite. If that candidate
fails, the next eligible candidate gets a turn. The master manifest retains
all scores and timing measurements. Pester subprocesses have a bounded
runtime and their process trees are terminated on timeout.

For **multi-function refactoring**, omit `-RegressionTestPath` while working
through individual batches and run the complete suite **once** in CI after
all refactoring changes are ready. This avoids a full project-suite run per
function. Focused tests still need adequate behavior coverage.

When `-TestPath` is left at the default `tests`, PSPrune retains its original
all-candidates-full-suite behavior. Choose a focused Pester test file or
directory explicitly; PSPrune does not silently guess which tests to skip.
