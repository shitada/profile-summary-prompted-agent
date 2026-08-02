[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourcePath,
    [Parameter(Mandatory)]
    [string]$BaselineManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw 'The source directory does not exist.'
}
if (-not (Test-Path -LiteralPath $BaselineManifestPath -PathType Leaf)) {
    throw 'The baseline manifest does not exist.'
}

$baseline = Get-Content -LiteralPath $BaselineManifestPath -Raw | ConvertFrom-Json -Depth 10
$baselineMap = @{}
foreach ($file in $baseline.Files) {
    $relativePath = ([string]$file.RelativePath).Replace('\', '/')
    $baselineMap[$relativePath] = [pscustomobject]@{
        Length = [long]$file.Length
        SHA256 = [string]$file.SHA256
    }
}

$currentMap = @{}
Get-ChildItem -LiteralPath $SourcePath -File -Recurse -Force |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
    ForEach-Object {
        $relativePath = $_.FullName.Substring($SourcePath.Length + 1).Replace('\', '/')
        $currentMap[$relativePath] = [pscustomobject]@{
            Length = $_.Length
            SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }

$added = @($currentMap.Keys | Where-Object { -not $baselineMap.ContainsKey($_) } | Sort-Object)
$removed = @($baselineMap.Keys | Where-Object { -not $currentMap.ContainsKey($_) } | Sort-Object)
$changed = @($baselineMap.Keys | Where-Object {
    $currentMap.ContainsKey($_) -and (
        $currentMap[$_].Length -ne $baselineMap[$_].Length -or
        $currentMap[$_].SHA256 -ne $baselineMap[$_].SHA256
    )
} | Sort-Object)

$result = [pscustomobject]@{
    Status = if ($added.Count + $removed.Count + $changed.Count -eq 0) { 'unchanged' } else { 'changed' }
    BaselineFileCount = $baselineMap.Count
    CurrentFileCount = $currentMap.Count
    AddedCount = $added.Count
    RemovedCount = $removed.Count
    ChangedCount = $changed.Count
    Added = $added
    Removed = $removed
    Changed = $changed
}
$result | ConvertTo-Json -Depth 4

if ($result.Status -ne 'unchanged') {
    throw 'The source tree differs from the baseline manifest.'
}
