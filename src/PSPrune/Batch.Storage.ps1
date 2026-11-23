function Get-PSPruneRoot {
    param([string]$Path = '.')
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $cursor = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
    while ($cursor) {
        if (Test-Path -LiteralPath (Join-Path $cursor '.psprune/manifest.json')) {
            return $cursor
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    throw "No PSPrune master manifest found above '$Path'."
}

function Get-PSPruneStore {
    param([string]$Root)
    Join-Path $Root '.psprune'
}

function Get-PSPruneDigest {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text)
    )).ToLowerInvariant()
}

function Get-PSPruneFileDigest {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-PSPruneSignature {
    param($FunctionAst)
    $parameters = if ($FunctionAst.Parameters) {
        @($FunctionAst.Parameters)
    }
    elseif ($FunctionAst.Body.ParamBlock) {
        @($FunctionAst.Body.ParamBlock.Parameters)
    }
    else { @() }
    $parts = foreach ($parameter in $parameters) {
        $attributes = @($parameter.Attributes | ForEach-Object {
            ($_.Extent.Text -replace '\s+', '').ToLowerInvariant()
        })
        $default = if ($parameter.DefaultValue) {
            ($parameter.DefaultValue.Extent.Text -replace '\s+', '').ToLowerInvariant()
        } else { '' }
        "$($parameter.Name.VariablePath.UserPath.ToLowerInvariant()):$($attributes -join ','):$default"
    }
    @($parts) -join ';'
}

function Assert-PSPruneId {
    param([string]$Id)
    if ($Id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Batch ID must be a lowercase 32-character UUID.'
    }
}

function Get-PSPruneJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing PSPrune manifest: $Path"
    }
    Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Save-PSPruneJson {
    param([string]$Path, $Value)
    $parent = [IO.Path]::GetDirectoryName($Path)
    $temporary = Join-Path $parent ('.psprune-write-' + [guid]::NewGuid().ToString('N'))
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 20
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Enter-PSPruneLock {
    param([string]$Store)
    $path = Join-Path $Store '.lock'
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        try {
            return [IO.FileStream]::new(
                $path, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            Start-Sleep -Milliseconds 50
        }
    }
    throw 'Timed out waiting for the PSPrune workspace lock.'
}

function Get-PSPruneMasterPath {
    param([string]$Root)
    Join-Path (Get-PSPruneStore -Root $Root) 'manifest.json'
}

function Get-PSPruneBatchPath {
    param([string]$Root, [string]$Id)
    Assert-PSPruneId -Id $Id
    Join-Path (Get-PSPruneStore -Root $Root) "batches/$Id"
}

function New-PSPruneBatch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$FunctionName,
        [string]$ProjectPath = '.',
        [string]$TestPath = 'tests'
    )
    $root = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).ProviderPath
    if (-not (Get-Item -LiteralPath $root).PSIsContainer) {
        throw 'ProjectPath must be a directory.'
    }
    $target = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if ((Get-Item -LiteralPath $target).PSIsContainer) { throw 'Path must identify a script file.' }
    $relative = [IO.Path]::GetRelativePath($root, $target)
    if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or
        $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
        throw 'Target file must belong to ProjectPath.'
    }
    if ([IO.Path]::GetExtension($target) -notin '.ps1', '.psm1') {
        throw 'Only .ps1 and .psm1 targets are supported.'
    }
    $tests = [IO.Path]::GetFullPath($TestPath, $root)
    $relativeTests = [IO.Path]::GetRelativePath($root, $tests)
    if ($relativeTests -eq '..' -or
        $relativeTests.StartsWith("..$([IO.Path]::DirectorySeparatorChar)") -or
        [IO.Path]::IsPathRooted($relativeTests) -or
        -not (Test-Path -LiteralPath $tests)) {
        throw 'TestPath must exist inside the project.'
    }
    $source = [IO.File]::ReadAllText($target)
    $definition = Get-PSPruneAst -Source $source -FunctionName $FunctionName
    Import-Module PSComplexity -MinimumVersion '0.7.1' -ErrorAction Stop
    $measurements = @(Measure-PSComplexity -Path $target -ErrorAction Stop |
        Where-Object Unit -eq $FunctionName)
    if ($measurements.Count -ne 1) { throw "Cannot measure function '$FunctionName' uniquely." }

    if (-not $PSCmdlet.ShouldProcess($root, "Create a PSPrune batch for $FunctionName")) { return }
    $store = Get-PSPruneStore -Root $root
    $null = New-Item -ItemType Directory -Path $store -Force
    $lock = Enter-PSPruneLock -Store $store
    try {
        $master = Get-PSPruneMasterPath -Root $root
        if (-not (Test-Path -LiteralPath $master)) {
            Save-PSPruneJson -Path $master -Value ([ordered]@{
                schema_version = 1
                batches = @()
            })
        }
        $id = [guid]::NewGuid().ToString('N')
        $batchDir = Get-PSPruneBatchPath -Root $root -Id $id
        $null = New-Item -ItemType Directory -Path $batchDir -Force
        $record = [ordered]@{
            schema_version = 1
            id = $id
            status = 'open'
            created_at = [DateTime]::UtcNow.ToString('o')
            completed_at = $null
            selected_slot = $null
            applied = $false
            project_root = $root
            test_path = $relativeTests
            target = [ordered]@{
                file = $relative
                function = $FunctionName
                file_sha256 = Get-PSPruneFileDigest -Path $target
                source_sha256 = Get-PSPruneDigest -Text $definition.Extent.Text
                signature = Get-PSPruneSignature -FunctionAst $definition
            }
            original = [ordered]@{
                cyclomatic = [int]$measurements[0].Cyclomatic
                cognitive = [int]$measurements[0].Cognitive
            }
            slots = @(1..5)
        }
        $pathToManifest = Join-Path $batchDir 'manifest.json'
        Save-PSPruneJson -Path $pathToManifest -Value $record
        Get-PSPruneJson -Path $pathToManifest
    }
    finally { $lock.Dispose() }
}

function Get-PSPruneHistory {
    [CmdletBinding()]
    param([string]$Path = '.')
    $root = Get-PSPruneRoot -Path $Path
    $master = Get-PSPruneJson -Path (Get-PSPruneMasterPath -Root $root)
    foreach ($record in $master.batches) { $record }
}

function Get-PSPruneBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$Path = '.')
    Assert-PSPruneId -Id $Id
    $root = Get-PSPruneRoot -Path $Path
    $manifest = Join-Path (Get-PSPruneBatchPath -Root $root -Id $Id) 'manifest.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        return Get-PSPruneJson -Path $manifest
    }
    $records = @(Get-PSPruneHistory -Path $root | Where-Object Id -eq $Id)
    if ($records.Count -ne 1) { throw "Unknown batch '$Id'." }
    $records[0]
}

function Submit-PSPruneCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateRange(1, 5)][int]$Slot,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$ProjectPath = '.'
    )
    Assert-PSPruneId -Id $Id
    $root = Get-PSPruneRoot -Path $ProjectPath
    $source = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).ProviderPath
    $text = [IO.File]::ReadAllText($source)
    $batchDir = Get-PSPruneBatchPath -Root $root -Id $Id
    $lock = Enter-PSPruneLock -Store (Get-PSPruneStore -Root $root)
    try {
        $batch = Get-PSPruneJson -Path (Join-Path $batchDir 'manifest.json')
        if ($batch.status -ne 'open') { throw "Batch '$Id' is not open." }
        $ast = Get-PSPruneAst -Source $text -FunctionName $batch.target.function -SingleFunction
        if ((Get-PSPruneSignature -FunctionAst $ast) -cne $batch.target.signature) {
            throw 'Candidate signature differs from the target function.'
        }
        $destination = Join-Path $batchDir "candidate-$Slot.ps1"
        if (Test-Path -LiteralPath $destination) { throw "Slot $Slot is occupied." }
        $temporary = Join-Path $batchDir ('.submission-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllText($temporary, $text, [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporary, $destination)
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
        [pscustomobject]@{
            BatchId = $Id
            Slot = $Slot
            Path = $destination
            SHA256 = Get-PSPruneFileDigest -Path $destination
        }
    }
    finally { $lock.Dispose() }
}
