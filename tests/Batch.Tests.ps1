BeforeAll {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:sampleProject = Join-Path $root 'tests/fixtures/BatchProject'
    $script:candidateFolder = Join-Path $root 'tests/fixtures/candidates'
    if (-not (Get-Module -ListAvailable PSComplexity | Where-Object Version -ge '0.7.1')) {
        Install-PSResource PSComplexity -Version '0.7.1' -Scope CurrentUser -TrustRepository -ErrorAction Stop
    }
    Import-Module (Join-Path $root 'src/PSPrune/PSPrune.psd1') -Force -ErrorAction Stop
}

Describe 'PSPrune v0.2 batch contract' {
    BeforeEach {
        $script:workingProject = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:sampleProject -Destination $script:workingProject -Recurse -Force
        $script:workingFile = Join-Path $script:workingProject 'Example.ps1'
    }

    It 'creates a permanent master manifest and a separate working batch' {
        $batch = New-PSPruneBatch -Path $script:workingFile -FunctionName Get-Label -ProjectPath $script:workingProject
        ($batch -is [pscustomobject]) | Should -BeTrue
        $batch.id | Should -Match '^[0-9a-f]{32}$'
        $batch.status | Should -BeExactly 'open'
        $batch.slots.Count | Should -Be 5
        $batch.target.function | Should -BeExactly 'Get-Label'
        $batch.target.file | Should -BeExactly 'Example.ps1'
        $batch.target.file_sha256 | Should -Match '^[0-9a-f]{64}$'
        $batch.target.source_sha256 | Should -Match '^[0-9a-f]{64}$'
        $master = Join-Path $script:workingProject '.psprune/manifest.json'
        (Test-Path -LiteralPath $master) | Should -BeTrue
        (Get-Content -LiteralPath $master -Raw | ConvertFrom-Json).batches.Count | Should -Be 0
        (Get-PSPruneBatch -Id $batch.id -Path $script:workingProject).status | Should -Be 'open'
        @((Get-PSPruneHistory -Path $script:workingFile)).Count | Should -Be 0
    }

    It 'submits to independent slots and refuses overwrites or mismatched functions' {
        $batch = New-PSPruneBatch -Path $script:workingFile -FunctionName Get-Label -ProjectPath $script:workingProject
        for ($slot = 1; $slot -le 5; $slot++) {
            $source = Join-Path $script:candidateFolder "$slot-*.txt"
            $file = @(Get-Item -Path $source)[0].FullName
            $submitted = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $file -ProjectPath $script:workingProject
            $submitted.Slot | Should -Be $slot
            $submitted.SHA256 | Should -Match '^[0-9a-f]{64}$'
            (Test-Path -LiteralPath $submitted.Path) | Should -BeTrue
        }
        $first = (Get-ChildItem -LiteralPath $script:candidateFolder -Filter '1-*.txt').FullName
        { Submit-PSPruneCandidate -Id $batch.id -Slot 1 -SourcePath $first -ProjectPath $script:workingProject } |
            Should -Throw '*occupied*'
    }

    It 'rejects a stale batch without modifying the changed file' {
        $batch = New-PSPruneBatch -Path $script:workingFile -FunctionName Get-Label -ProjectPath $script:workingProject
        Add-Content -LiteralPath $script:workingFile -Value '# changed externally'
        $before = [IO.File]::ReadAllText($script:workingFile)
        { Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:workingProject -Apply } |
            Should -Throw '*source changed*'
        [IO.File]::ReadAllText($script:workingFile) | Should -BeExactly $before
        (Get-PSPruneBatch -Id $batch.id -Path $script:workingProject).status | Should -Be 'open'
    }

    It 'runs real isolated Pester tests, selects a winner and archives metadata' {
        $original = [IO.File]::ReadAllText($script:workingFile)
        $batch = New-PSPruneBatch -Path $script:workingFile -FunctionName Get-Label -ProjectPath $script:workingProject
        for ($slot = 1; $slot -le 5; $slot++) {
            $file = @(Get-Item -Path (Join-Path $script:candidateFolder "$slot-*.txt"))[0].FullName
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $file -ProjectPath $script:workingProject
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:workingProject -Apply
        ($result -is [pscustomobject]) | Should -BeTrue
        $result.status | Should -BeExactly 'applied'
        $result.validation.all_passed | Should -BeTrue
        $result.improved | Should -BeTrue
        $result.applied | Should -BeTrue
        $result.candidates.Count | Should -Be 5
        $result.selected_slot | Should -BeGreaterThan 0
        $after = [IO.File]::ReadAllText($script:workingFile)
        $after | Should -Not -BeExactly $original
        $after.Substring($after.IndexOf('# after sentinel')) |
            Should -BeExactly $original.Substring($original.IndexOf('# after sentinel'))
        $history = @(Get-PSPruneHistory -Path $script:workingProject)
        $history.Count | Should -Be 1
        $history[0].id | Should -BeExactly $batch.id
        (($history[0] | ConvertTo-Json -Depth 12 | ConvertFrom-Json).candidates.Count) | Should -Be 5
        $master = Join-Path $script:workingProject '.psprune/manifest.json'
        $masterBefore = [IO.File]::ReadAllText($master)
        $dryRun = @(Clear-PSPruneArtifacts -Path $script:workingProject -WhatIf)
        $dryRun.Count | Should -Be 1
        $dryRun[0].Removed | Should -BeFalse
        $deleted = @(Clear-PSPruneArtifacts -Path $script:workingProject -BatchId $batch.id -Confirm:$false)
        $deleted[0].Removed | Should -BeTrue
        [IO.File]::ReadAllText($master) | Should -BeExactly $masterBefore
        (Get-PSPruneBatch -Id $batch.id -Path $script:workingProject).status | Should -BeExactly 'applied'
    }

    It 'archives a failed candidate batch and leaves the source unchanged' {
        $original = [IO.File]::ReadAllText($script:workingFile)
        $batch = New-PSPruneBatch -Path $script:workingFile -FunctionName Get-Label -ProjectPath $script:workingProject
        for ($slot = 1; $slot -le 5; $slot++) {
            $file = @(Get-Item -Path (Join-Path $script:candidateFolder "$slot-*.txt"))[0].FullName
            if ($slot -eq 1) {
                $wrong = Join-Path $TestDrive 'wrong.ps1'
                [IO.File]::WriteAllText($wrong, ([IO.File]::ReadAllText($file)).Replace("return 'zero'", "return 'wrong'"))
                $file = $wrong
            }
            $null = Submit-PSPruneCandidate -Id $batch.id -Slot $slot -SourcePath $file -ProjectPath $script:workingProject
        }
        $result = Invoke-PSPrune -BatchId $batch.id -ProjectPath $script:workingProject -Apply
        $result.status | Should -BeExactly 'rejected'
        $result.validation.all_passed | Should -BeFalse
        $result.applied | Should -BeFalse
        $result.candidates[0].passed | Should -BeFalse
        [IO.File]::ReadAllText($script:workingFile) | Should -BeExactly $original
        @((Get-PSPruneHistory -Path $script:workingProject)).Count | Should -Be 1
    }

    It 'protects the unfinished batch directory when pruning' {
        $batch = New-PSPruneBatch -Path $script:workingFile -FunctionName Get-Label -ProjectPath $script:workingProject
        $result = @(Clear-PSPruneArtifacts -Path $script:workingProject -BatchId $batch.id -Confirm:$false)
        $result[0].Status | Should -BeExactly 'protected'
        (Test-Path -LiteralPath (Join-Path $script:workingProject ".psprune/batches/$($batch.id)/manifest.json")) | Should -BeTrue
    }
}
