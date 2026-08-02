[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$RequireDenylist
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    Write-Host "[$Name] starting"
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "[$Name] failed with exit code $LASTEXITCODE."
    }
    Write-Host "[$Name] passed"
}

$pythonCandidates = @(
    (Join-Path $RepoRoot '.venv\Scripts\python.exe'),
    (Join-Path $RepoRoot '.venv/bin/python')
)
$python = $pythonCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $python) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        throw 'Python is unavailable. Create .venv with Python 3.13 and install both requirements files.'
    }
    $python = $pythonCommand.Source
}

Push-Location $RepoRoot
try {
    Invoke-Checked -Name 'Python compile' -Action {
        & $python -m compileall -q src tests scripts
    }

    Invoke-Checked -Name 'Unit tests' -Action {
        & $python -m unittest discover -s tests -p 'test_*.py'
    }

    Invoke-Checked -Name 'Function metadata' -Action {
        & $python scripts/validate-function-metadata.py
    }

    Invoke-Checked -Name 'Documentation' -Action {
        & $python scripts/validate-docs.py
    }

    $parseErrors = [System.Collections.Generic.List[object]]::new()
    foreach ($script in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -Filter '*.ps1' -File) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        foreach ($error in $errors) {
            $parseErrors.Add([pscustomobject]@{ File = $script.Name; Message = $error.Message })
        }
    }
    if ($parseErrors.Count -gt 0) {
        $parseErrors | Format-Table -AutoSize | Out-String | Write-Error
        throw 'PowerShell parser validation failed.'
    }
    Write-Host '[PowerShell parser] passed'

    $templatePath = Join-Path ([System.IO.Path]::GetTempPath()) "profile-summary-$([guid]::NewGuid().ToString('N')).json"
    try {
        Invoke-Checked -Name 'Bicep build' -Action {
            az bicep build --file infra/main.bicep --outfile $templatePath --only-show-errors
        }
    }
    finally {
        Remove-Item -LiteralPath $templatePath -Force -ErrorAction SilentlyContinue
    }

    $scanArguments = @('-NoProfile', '-File', 'scripts/scan-sensitive-data.ps1', '-RootPath', $RepoRoot)
    if ($RequireDenylist) {
        $scanArguments += '-RequireDenylist'
    }
    Invoke-Checked -Name 'Sensitive-data scan' -Action {
        & pwsh @scanArguments
    }

    $imageDirectory = Join-Path $RepoRoot 'docs\images\authentication'
    if (Test-Path -LiteralPath $imageDirectory -PathType Container) {
        $ocrArguments = @('scripts/scan-image-text.py', $imageDirectory)
        if ($RequireDenylist) {
            $ocrArguments += '--require-denylist'
        }
        Invoke-Checked -Name 'Image OCR scan' -Action {
            & $python @ocrArguments
        }
    }
}
finally {
    Pop-Location
}

[pscustomobject]@{
    Status = 'passed'
    Repository = Split-Path -Leaf $RepoRoot
} | ConvertTo-Json -Compress
