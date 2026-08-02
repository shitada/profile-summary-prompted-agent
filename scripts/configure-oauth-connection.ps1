[CmdletBinding()]
param(
    [switch]$ConfirmAzureWrite,
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = '',
    [string]$AccountName = '',
    [string]$ProjectName = '',
    [string]$ApiAppObjectId = '',
    [string]$ApiAppClientId = '',
    [string]$OAuthClientAppObjectId = '',
    [string]$OAuthClientAppClientId = '',
    [string]$ApiScope = '',
    [string]$McpServerUrl = '',
    [string]$TenantId = '',
    [string]$ConnectionName = '',
    [ValidateRange(1, 30)]
    [int]$SecretLifetimeDays = 7,
    [switch]$UseDeviceAuthentication
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ExplicitAzureWrite -Confirmed $ConfirmAzureWrite -Operation 'OAuth connection configuration'

$SubscriptionId = Resolve-AzdValue -Value $SubscriptionId -Name 'AZURE_SUBSCRIPTION_ID'
$ResourceGroup = Resolve-AzdValue -Value $ResourceGroup -Name 'AZURE_RESOURCE_GROUP'
$AccountName = Resolve-AzdValue -Value $AccountName -Name 'AZURE_AI_ACCOUNT_NAME'
$ProjectName = Resolve-AzdValue -Value $ProjectName -Name 'AZURE_AI_PROJECT_NAME'
$ApiAppObjectId = Resolve-AzdValue -Value $ApiAppObjectId -Name 'ENTRA_APPLICATION_OBJECT_ID'
$ApiAppClientId = Resolve-AzdValue -Value $ApiAppClientId -Name 'ENTRA_APPLICATION_ID'
$OAuthClientAppObjectId = Resolve-AzdValue -Value $OAuthClientAppObjectId -Name 'MCP_OAUTH_CLIENT_APPLICATION_OBJECT_ID'
$OAuthClientAppClientId = Resolve-AzdValue -Value $OAuthClientAppClientId -Name 'MCP_OAUTH_CLIENT_APPLICATION_ID'
$ApiScope = Resolve-AzdValue -Value $ApiScope -Name 'ENTRA_API_SCOPE'
$McpServerUrl = Resolve-AzdValue -Value $McpServerUrl -Name 'MCP_SERVER_URL'
$TenantId = Resolve-AzdValue -Value $TenantId -Name 'AZURE_TENANT_ID'
$ConnectionName = Resolve-AzdValue -Value $ConnectionName -Name 'FOUNDRY_CONNECTION_NAME'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
if (-not (Get-MgContext)) {
    if (-not $UseDeviceAuthentication) {
        throw 'No process-scoped Microsoft Graph session exists. Re-run with -UseDeviceAuthentication.'
    }
    Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' `
        -ContextScope Process -UseDeviceAuthentication -NoWelcome
}
$graphContext = Get-MgContext
Assert-Condition ($null -ne $graphContext) 'Microsoft Graph authentication did not complete.'
Assert-Condition ($graphContext.TenantId -eq $TenantId) 'Microsoft Graph is connected to a different tenant.'

$apiAppUri = "https://graph.microsoft.com/v1.0/applications/$ApiAppObjectId"
$oauthClientAppUri = "https://graph.microsoft.com/v1.0/applications/$OAuthClientAppObjectId"
$apiApp = Invoke-MgGraphRequest -Method Get -Uri "$apiAppUri`?`$select=id,appId,identifierUris,api"
$oauthClient = Invoke-MgGraphRequest -Method Get `
    -Uri "$oauthClientAppUri`?`$select=id,appId,web,passwordCredentials,requiredResourceAccess"

Assert-Condition ($apiApp.appId -eq $ApiAppClientId) 'The Function API object ID and application ID do not match.'
Assert-Condition ($oauthClient.appId -eq $OAuthClientAppClientId) 'The OAuth client object ID and application ID do not match.'
Assert-Condition (
    $ApiAppObjectId -ne $OAuthClientAppObjectId -and $ApiAppClientId -ne $OAuthClientAppClientId
) 'The Foundry OAuth client must be separate from the Function API application.'

$apiScopes = @($apiApp.api.oauth2PermissionScopes | Where-Object {
    $_.value -eq 'user_impersonation' -and $_.type -eq 'User' -and $_.isEnabled
})
Assert-Condition ($apiScopes.Count -eq 1) 'The Function API must expose one enabled user_impersonation scope.'
$expectedScopes = @($apiApp.identifierUris | ForEach-Object { "$_/user_impersonation" })
Assert-Condition ($expectedScopes -contains $ApiScope) 'ENTRA_API_SCOPE does not belong to the Function API.'

$requiredApiAccess = @($oauthClient.requiredResourceAccess | Where-Object resourceAppId -eq $ApiAppClientId)
Assert-Condition (
    @($oauthClient.requiredResourceAccess).Count -eq 1 -and $requiredApiAccess.Count -eq 1
) 'The OAuth client must request only the Function API delegated permission.'
$requiredScopes = @($requiredApiAccess[0].resourceAccess | Where-Object {
    $_.id -eq $apiScopes[0].id -and $_.type -eq 'Scope'
})
Assert-Condition (
    @($requiredApiAccess[0].resourceAccess).Count -eq 1 -and $requiredScopes.Count -eq 1
) 'The OAuth client must request exactly the Function API user_impersonation scope.'

$armToken = & az account get-access-token --subscription $SubscriptionId `
    --resource 'https://management.azure.com/' --query accessToken --output tsv --only-show-errors
if ([string]::IsNullOrWhiteSpace($armToken)) {
    throw 'An Azure Resource Manager access token could not be acquired.'
}
$armHeaders = @{ Authorization = "Bearer $armToken"; 'Content-Type' = 'application/json' }
$connectionUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
    "/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName" +
    "/connections/$ConnectionName`?api-version=2025-12-01"

$connectionBefore = $null
try {
    $connectionBefore = Invoke-RestMethod -Method Get -Uri $connectionUri -Headers $armHeaders
}
catch {
    if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) {
        throw
    }
}

$redirectUris = @($oauthClient.web.redirectUris)
if ($connectionBefore.properties.redirectUrl -and $redirectUris -notcontains $connectionBefore.properties.redirectUrl) {
    $redirectUris += $connectionBefore.properties.redirectUrl
    $patchBody = @{ web = @{ redirectUris = $redirectUris } } | ConvertTo-Json -Depth 4
    Invoke-MgGraphRequest -Method Patch -Uri $oauthClientAppUri -Body $patchBody `
        -ContentType 'application/json' | Out-Null
}

$passwordBody = @{
    passwordCredential = @{
        displayName = 'foundry-mcp-custom-oauth'
        endDateTime = (Get-Date).ToUniversalTime().AddDays($SecretLifetimeDays).ToString('o')
    }
} | ConvertTo-Json -Depth 4
$addedPassword = Invoke-MgGraphRequest -Method Post -Uri "$oauthClientAppUri/addPassword" `
    -Body $passwordBody -ContentType 'application/json'
$newSecret = $addedPassword.secretText
if ([string]::IsNullOrWhiteSpace($newSecret)) {
    throw 'Microsoft Graph did not return the new client secret.'
}

$authority = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
$connectionBody = @{
    properties = [ordered]@{
        authType = 'OAuth2'
        category = 'RemoteTool'
        target = $McpServerUrl
        metadata = [ordered]@{
            oAuthProvider = 'custom'
            type = 'custom_MCP'
        }
        authorizationUrl = "$authority/authorize"
        tokenUrl = "$authority/token"
        refreshUrl = "$authority/token"
        scopes = @($ApiScope, 'offline_access')
        isSharedToAll = $false
        useCustomConnector = $true
        credentials = [ordered]@{
            clientId = $OAuthClientAppClientId
            clientSecret = $newSecret
        }
    }
} | ConvertTo-Json -Depth 10

$connectionUpdated = $false
try {
    Invoke-RestMethod -Method Put -Uri $connectionUri -Headers $armHeaders -Body $connectionBody | Out-Null
    $connectionUpdated = $true
    $connection = Invoke-RestMethod -Method Get -Uri $connectionUri -Headers $armHeaders
    $redirectUrl = $connection.properties.redirectUrl
    if ([string]::IsNullOrWhiteSpace($redirectUrl)) {
        throw 'Foundry did not return an OAuth redirect URL.'
    }

    if ($redirectUris -notcontains $redirectUrl) {
        $redirectUris += $redirectUrl
        $patchBody = @{ web = @{ redirectUris = $redirectUris } } | ConvertTo-Json -Depth 4
        Invoke-MgGraphRequest -Method Patch -Uri $oauthClientAppUri -Body $patchBody `
            -ContentType 'application/json' | Out-Null
    }
}
catch {
    if (-not $connectionUpdated) {
        $removeBody = @{ keyId = $addedPassword.keyId } | ConvertTo-Json
        Invoke-MgGraphRequest -Method Post -Uri "$oauthClientAppUri/removePassword" `
            -Body $removeBody -ContentType 'application/json' | Out-Null
    }
    throw
}
finally {
    $newSecret = $null
    $connectionBody = $null
    $armToken = $null
    $armHeaders = $null
}

[pscustomobject]@{
    Status = 'configured'
    ConnectionName = $ConnectionName
    SeparateClientAndApi = $true
    SecretLifetimeDays = $SecretLifetimeDays
    ExistingSecretCount = @($oauthClient.passwordCredentials).Count
    SecretValuePrinted = $false
    RedirectUrlPrinted = $false
    NextStep = 'Create the Prompt Agent, complete consent, run end-to-end validation, then remove stale OAuth client secrets.'
} | ConvertTo-Json -Depth 4
