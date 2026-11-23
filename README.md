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
