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

    $output = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $output = & az @Arguments 2>&1
        if ($LASTEXITCODE -eq 0) {
            break
        }

        $errorText = $output -join [Environment]::NewLine
        $isTransientNetworkFailure = $errorText -match (
            'RemoteDisconnected|Connection aborted|Connection reset by peer|' +
            'temporarily unavailable|timed out|TimeoutError'
        )
        if (-not $isTransientNetworkFailure -or $attempt -eq 3) {
            throw "Azure CLI command failed: $errorText"
        }
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    if (-not $text) {
        return $null
    }
    return $text | ConvertFrom-Json -Depth 100
}

function Resolve-AzureCliPrincipalId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    $principalIdOutput = & az ad signed-in-user show --query id --output tsv --only-show-errors 2>$null
    $principalId = ($principalIdOutput -join [Environment]::NewLine).Trim()
    if (-not [string]::IsNullOrWhiteSpace($principalId)) {
        return $principalId
    }

    $tokenResponse = Invoke-AzJson -Arguments @(
        'account', 'get-access-token', '--subscription', $SubscriptionId,
        '--resource', 'https://management.azure.com/',
        '--only-show-errors', '--output', 'json'
    )
    $token = [string]$tokenResponse.accessToken
    try {
        $parts = @($token -split '\.')
        Assert-Condition ($parts.Count -ge 2) 'The ARM access token does not contain readable claims.'
        $payload = [string]$parts[1]
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($payload)) `
            'The ARM access token contains an empty claims segment.'
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - ($payload.Length % 4)) % 4)
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json
        Assert-Condition ($claims.tid -eq $TenantId) 'The ARM access token belongs to a different tenant.'
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($claims.oid)) `
            'The ARM access token does not identify a user object.'
        return [string]$claims.oid
    }
    finally {
        $token = $null
        $tokenResponse = $null
        $claims = $null
    }
}

function Connect-MicrosoftGraphSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,
        [switch]$UseDeviceAuthentication
    )

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    if (Get-MgContext) {
        Assert-Condition ((Get-MgContext).TenantId -eq $TenantId) `
            'Microsoft Graph is connected to a different tenant.'
        return
    }

    if ($UseDeviceAuthentication) {
        Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' `
            -ContextScope Process -UseDeviceAuthentication -NoWelcome
    }
    else {
        $tokenOutput = & az account get-access-token --tenant $TenantId `
            --resource 'https://graph.microsoft.com/' --query accessToken `
            --output tsv --only-show-errors 2>$null
        $token = ($tokenOutput -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw 'Azure CLI did not return a Microsoft Graph access token.'
        }
        try {
            $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
            Connect-MgGraph -AccessToken $secureToken -NoWelcome
        }
        finally {
            $token = $null
            $tokenOutput = $null
            $secureToken = $null
        }
    }

    $context = Get-MgContext
    Assert-Condition ($null -ne $context -and $context.TenantId -eq $TenantId) `
        'Microsoft Graph authentication did not complete for the expected tenant.'
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
