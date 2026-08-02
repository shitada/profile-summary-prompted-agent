Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AzdValue {
    [CmdletBinding()]
    param(
        [string]$Value,
        [Parameter(Mandatory)]
        [string]$Name,
        [switch]$Optional
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }

    $resolved = & azd env get-value $Name --no-prompt 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) {
        return $resolved.Trim()
    }

    if ($Optional) {
        return ''
    }
    throw "Missing $Name. Pass it explicitly or set it in the active azd environment."
}

function Invoke-AzJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: $($output -join [Environment]::NewLine)"
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    if (-not $text) {
        return $null
    }
    return $text | ConvertFrom-Json -Depth 100
}

function Assert-Condition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExplicitAzureWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Confirmed,
        [Parameter(Mandatory)]
        [string]$Operation
    )

    if (-not $Confirmed) {
        throw "$Operation modifies Azure or Microsoft Entra. Re-run with -ConfirmAzureWrite after reviewing the target context."
    }
}
