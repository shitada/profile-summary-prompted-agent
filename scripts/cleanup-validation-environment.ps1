[CmdletBinding()]
param(
    [switch]$ConfirmAzureWrite,
    [string]$EnvironmentName = '',
    [string]$SubscriptionId = '',
    [string]$TenantId = '',
    [string]$ResourceGroup = '',
    [switch]$RemoveAzdEnvironment
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ExplicitAzureWrite -Confirmed $ConfirmAzureWrite -Operation 'Validation environment cleanup'

$EnvironmentName = Resolve-AzdValue -Value $EnvironmentName -Name 'AZURE_ENV_NAME'
$SubscriptionId = Resolve-AzdValue -Value $SubscriptionId -Name 'AZURE_SUBSCRIPTION_ID'
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw 'Pass -TenantId when cleaning up after azd down.'
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    throw 'Pass -ResourceGroup when cleaning up after azd down.'
}

$account = Invoke-AzJson -Arguments @(
    'account', 'show', '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json'
)
Assert-Condition ($account.tenantId -eq $TenantId) 'Azure CLI is connected to a different tenant.'

function Invoke-OptionalAzDelete {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    $errorText = $output -join [Environment]::NewLine
    if ($errorText -match '(?i)404|not found|resourcenotfound') {
        return $false
    }
    throw 'An Azure cleanup request failed. No identifier or response body was logged.'
}

function Test-GraphNotFound {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)

    $statusCode = $null
    if (
        $ErrorRecord.Exception.PSObject.Properties['Response'] -and
        $null -ne $ErrorRecord.Exception.Response -and
        $ErrorRecord.Exception.Response.PSObject.Properties['StatusCode']
    ) {
        $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
    }
    return $statusCode -eq 404 -or $ErrorRecord.Exception.Message -match '(?i)404|Request_ResourceNotFound'
}

function Remove-GraphObject {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Id
    )

    $uri = "https://graph.microsoft.com/v1.0/$Type/$Id"
    try {
        Invoke-MgGraphRequest -Method Get -Uri $uri | Out-Null
    }
    catch {
        if (Test-GraphNotFound -ErrorRecord $_) {
            return $false
        }
        throw
    }

    Invoke-MgGraphRequest -Method Delete -Uri $uri | Out-Null
    try {
        Invoke-MgGraphRequest -Method Get -Uri $uri | Out-Null
        throw 'A Microsoft Entra object still exists after deletion.'
    }
    catch {
        if (Test-GraphNotFound -ErrorRecord $_) {
            return $true
        }
        throw
    }
}

function Resolve-OptionalAzdValue {
    param([Parameter(Mandatory)][string]$Name)

    $output = & azd env get-value $Name --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Resolve-GraphObjects {
    $outputNames = @(
        'ENTRA_SERVICE_PRINCIPAL_ID'
        'MCP_OAUTH_CLIENT_SERVICE_PRINCIPAL_ID'
        'WEB_ENTRA_SERVICE_PRINCIPAL_ID'
        'ENTRA_APPLICATION_OBJECT_ID'
        'MCP_OAUTH_CLIENT_APPLICATION_OBJECT_ID'
        'WEB_ENTRA_APPLICATION_OBJECT_ID'
    )
    $outputTypes = @(
        'servicePrincipals'
        'servicePrincipals'
        'servicePrincipals'
        'applications'
        'applications'
        'applications'
    )
    $outputValues = @($outputNames | ForEach-Object { Resolve-OptionalAzdValue -Name $_ })
    $availableOutputCount = @($outputValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($availableOutputCount -eq $outputNames.Count) {
        return [pscustomobject]@{
            Objects = @(for ($index = 0; $index -lt $outputNames.Count; $index++) {
                @{ Type = $outputTypes[$index]; Id = $outputValues[$index] }
            })
            AlreadyAbsent = 0
        }
    }
    Assert-Condition ($availableOutputCount -eq 0) `
        'Only part of the Microsoft Entra cleanup identifiers remain; cleanup was not attempted.'

    $displayNames = @(
        "Profile MCP API ($EnvironmentName)"
        "Profile Chat ($EnvironmentName)"
        "Profile Foundry MCP OAuth client ($EnvironmentName)"
    )
    $objects = @()
    $alreadyAbsent = 0
    foreach ($displayName in $displayNames) {
        $filter = [Uri]::EscapeDataString("displayName eq '$displayName'")
        $response = Invoke-MgGraphRequest -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId"
        $matches = @($response.value)
        Assert-Condition ($matches.Count -le 1) `
            'An environment-specific Microsoft Entra application resolved ambiguously.'
        if ($matches.Count -eq 1) {
            $objects += @{ Type = 'applications'; Id = $matches[0].id }
            $spFilter = [Uri]::EscapeDataString("appId eq '$($matches[0].appId)'")
        }
        else {
            $alreadyAbsent++
            $spFilter = [Uri]::EscapeDataString("displayName eq '$displayName'")
        }
        $spResponse = Invoke-MgGraphRequest -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$spFilter&`$select=id"
        $spMatches = @($spResponse.value)
        Assert-Condition ($spMatches.Count -le 1) `
            'An environment-specific Microsoft Entra service principal resolved ambiguously.'
        if ($spMatches.Count -eq 1) {
            $objects += @{ Type = 'servicePrincipals'; Id = $spMatches[0].id }
        }
        else {
            $alreadyAbsent++
        }
    }
    return [pscustomobject]@{
        Objects = $objects
        AlreadyAbsent = $alreadyAbsent
    }
}

$resourceGroupExists = (& az group exists --name $ResourceGroup --subscription $SubscriptionId) -eq 'true'
$agentDeleted = $false
$connectionDeleted = $false
$resourceGroupDeleted = -not $resourceGroupExists

Connect-MicrosoftGraphSession -TenantId $TenantId
try {
    $graphResolution = Resolve-GraphObjects
    $graphObjects = @($graphResolution.Objects)
    $graphAlreadyAbsent = [int]$graphResolution.AlreadyAbsent
}
catch {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    throw
}

if ($resourceGroupExists) {
    $ProjectEndpoint = Resolve-AzdValue -Value '' -Name 'AZURE_AI_PROJECT_ENDPOINT'
    $AccountName = Resolve-AzdValue -Value '' -Name 'AZURE_AI_ACCOUNT_NAME'
    $ProjectName = Resolve-AzdValue -Value '' -Name 'AZURE_AI_PROJECT_NAME'
    $AgentName = Resolve-AzdValue -Value '' -Name 'FOUNDRY_AGENT_NAME'
    $ConnectionName = Resolve-AzdValue -Value '' -Name 'FOUNDRY_CONNECTION_NAME'
    $agentDeleted = Invoke-OptionalAzDelete -Arguments @(
        'rest', '--method', 'delete',
        '--url', "$ProjectEndpoint/agents/$AgentName`?api-version=v1",
        '--resource', 'https://ai.azure.com/',
        '--only-show-errors', '--output', 'none'
    )

    $connectionUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
        "/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName" +
        "/connections/$ConnectionName`?api-version=2025-12-01"
    $connectionDeleted = Invoke-OptionalAzDelete -Arguments @(
        'rest', '--method', 'delete', '--url', $connectionUrl,
        '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'none'
    )

    & azd down --environment $EnvironmentName --purge --force --no-prompt
    if ($LASTEXITCODE -ne 0) {
        throw 'azd failed to remove the validation Azure resources.'
    }
    $resourceGroupDeleted = (& az group exists --name $ResourceGroup --subscription $SubscriptionId) -eq 'false'
    Assert-Condition $resourceGroupDeleted 'The validation resource group still exists after azd down.'
}

$graphDeleted = 0
try {
    foreach ($graphObject in $graphObjects) {
        if (Remove-GraphObject -Type $graphObject.Type -Id $graphObject.Id) {
            $graphDeleted++
        }
        else {
            $graphAlreadyAbsent++
        }
    }
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

$environmentRemoved = $false
$environmentAlreadyAbsent = $false
if ($RemoveAzdEnvironment) {
    $environmentListOutput = & azd env list --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'The local azd environment list could not be read.'
    }
    $environments = @((($environmentListOutput -join [Environment]::NewLine) | ConvertFrom-Json))
    $matchingEnvironments = @($environments | Where-Object Name -eq $EnvironmentName)
    Assert-Condition ($matchingEnvironments.Count -le 1) 'The local azd environment resolved ambiguously.'
    if ($matchingEnvironments.Count -eq 1) {
        & azd env remove $EnvironmentName --force --no-prompt
        if ($LASTEXITCODE -ne 0) {
            throw 'The local azd environment could not be removed.'
        }
        $environmentRemoved = $true
    }
    else {
        $environmentAlreadyAbsent = $true
    }
}

[pscustomobject]@{
    Status = 'completed'
    AgentDeleted = $agentDeleted
    ConnectionDeleted = $connectionDeleted
    ResourceGroupDeleted = $resourceGroupDeleted
    GraphObjectsDeleted = $graphDeleted
    GraphObjectsAlreadyAbsent = $graphAlreadyAbsent
    AzdEnvironmentRemoved = $environmentRemoved
    AzdEnvironmentAlreadyAbsent = $environmentAlreadyAbsent
    IdentifiersPrinted = $false
} | ConvertTo-Json -Compress
