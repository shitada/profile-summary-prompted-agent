[CmdletBinding()]
param(
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = '',
    [string]$FunctionAppName = '',
    [string]$WebAppName = '',
    [string]$FunctionIdentityResourceId = '',
    [string]$FunctionIdentityClientId = '',
    [string]$FunctionIdentityPrincipalId = '',
    [string]$WebIdentityResourceId = '',
    [string]$WebIdentityClientId = '',
    [string]$WebIdentityPrincipalId = '',
    [string]$FunctionApiObjectId = '',
    [string]$FunctionApiApplicationId = '',
    [string]$FunctionApiServicePrincipalId = '',
    [string]$FunctionApiIdentifierUri = '',
    [string]$OAuthClientObjectId = '',
    [string]$OAuthClientApplicationId = '',
    [string]$OAuthClientServicePrincipalId = '',
    [string]$WebAppObjectId = '',
    [string]$WebAppApplicationId = '',
    [string]$WebAppServicePrincipalId = '',
    [string]$FoundryAccountName = '',
    [string]$FoundryProjectName = '',
    [string]$FoundryProjectId = '',
    [string]$ProjectEndpoint = '',
    [string]$McpServerUrl = '',
    [string]$ConnectionName = '',
    [string]$AgentName = '',
    [switch]$RequireAgent,
    [switch]$RequireNoFunctionApiSecrets
)

. (Join-Path $PSScriptRoot 'common.ps1')

function Write-VerificationStep {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host "[Verify] $Name"
}

$SubscriptionId = Resolve-AzdValue -Value $SubscriptionId -Name 'AZURE_SUBSCRIPTION_ID'
$ResourceGroup = Resolve-AzdValue -Value $ResourceGroup -Name 'AZURE_RESOURCE_GROUP'
$FunctionAppName = Resolve-AzdValue -Value $FunctionAppName -Name 'SERVICE_API_NAME'
$WebAppName = Resolve-AzdValue -Value $WebAppName -Name 'SERVICE_WEB_NAME'
$FunctionIdentityResourceId = Resolve-AzdValue -Value $FunctionIdentityResourceId -Name 'FUNCTION_IDENTITY_RESOURCE_ID'
$FunctionIdentityClientId = Resolve-AzdValue -Value $FunctionIdentityClientId -Name 'FUNCTION_IDENTITY_CLIENT_ID'
$FunctionIdentityPrincipalId = Resolve-AzdValue -Value $FunctionIdentityPrincipalId -Name 'FUNCTION_IDENTITY_PRINCIPAL_ID'
$WebIdentityResourceId = Resolve-AzdValue -Value $WebIdentityResourceId -Name 'WEB_IDENTITY_RESOURCE_ID'
$WebIdentityClientId = Resolve-AzdValue -Value $WebIdentityClientId -Name 'WEB_IDENTITY_CLIENT_ID'
$WebIdentityPrincipalId = Resolve-AzdValue -Value $WebIdentityPrincipalId -Name 'WEB_IDENTITY_PRINCIPAL_ID'
$FunctionApiObjectId = Resolve-AzdValue -Value $FunctionApiObjectId -Name 'ENTRA_APPLICATION_OBJECT_ID'
$FunctionApiApplicationId = Resolve-AzdValue -Value $FunctionApiApplicationId -Name 'ENTRA_APPLICATION_ID'
$FunctionApiServicePrincipalId = Resolve-AzdValue -Value $FunctionApiServicePrincipalId -Name 'ENTRA_SERVICE_PRINCIPAL_ID'
$FunctionApiIdentifierUri = Resolve-AzdValue -Value $FunctionApiIdentifierUri -Name 'ENTRA_IDENTIFIER_URI'
$OAuthClientObjectId = Resolve-AzdValue -Value $OAuthClientObjectId -Name 'MCP_OAUTH_CLIENT_APPLICATION_OBJECT_ID'
$OAuthClientApplicationId = Resolve-AzdValue -Value $OAuthClientApplicationId -Name 'MCP_OAUTH_CLIENT_APPLICATION_ID'
$OAuthClientServicePrincipalId = Resolve-AzdValue -Value $OAuthClientServicePrincipalId -Name 'MCP_OAUTH_CLIENT_SERVICE_PRINCIPAL_ID'
$WebAppObjectId = Resolve-AzdValue -Value $WebAppObjectId -Name 'WEB_ENTRA_APPLICATION_OBJECT_ID'
$WebAppApplicationId = Resolve-AzdValue -Value $WebAppApplicationId -Name 'WEB_ENTRA_APPLICATION_ID'
$WebAppServicePrincipalId = Resolve-AzdValue -Value $WebAppServicePrincipalId -Name 'WEB_ENTRA_SERVICE_PRINCIPAL_ID'
$FoundryAccountName = Resolve-AzdValue -Value $FoundryAccountName -Name 'AZURE_AI_ACCOUNT_NAME'
$FoundryProjectName = Resolve-AzdValue -Value $FoundryProjectName -Name 'AZURE_AI_PROJECT_NAME'
$FoundryProjectId = Resolve-AzdValue -Value $FoundryProjectId -Name 'AZURE_AI_PROJECT_ID'
$ProjectEndpoint = Resolve-AzdValue -Value $ProjectEndpoint -Name 'AZURE_AI_PROJECT_ENDPOINT'
$McpServerUrl = Resolve-AzdValue -Value $McpServerUrl -Name 'MCP_SERVER_URL'
$ConnectionName = Resolve-AzdValue -Value $ConnectionName -Name 'FOUNDRY_CONNECTION_NAME'
$AgentName = Resolve-AzdValue -Value $AgentName -Name 'FOUNDRY_AGENT_NAME'

Write-VerificationStep 'Azure application resources'
$function = Invoke-AzJson -Arguments @(
    'functionapp', 'show', '--name', $FunctionAppName, '--resource-group', $ResourceGroup,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)
Assert-Condition ($function.kind -eq 'functionapp,linux') 'The Function App is not a Linux Function App.'
Assert-Condition ($function.properties.httpsOnly -eq $true) 'The Function App does not require HTTPS.'
Assert-Condition (@($function.identity.userAssignedIdentities.PSObject.Properties.Name) -contains $FunctionIdentityResourceId) `
    'The expected user-assigned identity is not attached to the Function App.'

$web = Invoke-AzJson -Arguments @(
    'webapp', 'show', '--name', $WebAppName, '--resource-group', $ResourceGroup,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)
Assert-Condition ($web.kind -eq 'app,linux') 'The frontend is not a Linux App Service application.'
Assert-Condition ($web.httpsOnly -eq $true) 'The frontend does not require HTTPS.'
Assert-Condition (@($web.identity.userAssignedIdentities.PSObject.Properties.Name) -contains $WebIdentityResourceId) `
    'The expected user-assigned identity is not attached to the frontend.'

Write-VerificationStep 'Runtime application settings'
$functionSettings = @(Invoke-AzJson -Arguments @(
    'functionapp', 'config', 'appsettings', 'list', '--name', $FunctionAppName,
    '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json'
))
$functionSettingMap = @{}
foreach ($setting in $functionSettings) { $functionSettingMap[$setting.name] = $setting.value }
Assert-Condition ($functionSettingMap.AzureWebJobsStorage__credential -eq 'managedidentity') `
    'AzureWebJobsStorage is not configured for managed identity.'
Assert-Condition ($functionSettingMap.AzureWebJobsStorage__clientId -eq $FunctionIdentityClientId) `
    'AzureWebJobsStorage uses an unexpected client ID.'
Assert-Condition ($functionSettingMap.ENTRA_APPLICATION_CLIENT_ID -eq $FunctionApiApplicationId) `
    'The Function runtime uses an unexpected application ID.'
Assert-Condition ($functionSettingMap.OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID -eq $FunctionIdentityClientId) `
    'Function Easy Auth does not use the expected managed identity client assertion.'
Assert-Condition (-not $functionSettingMap.ContainsKey('AzureWebJobsStorage')) `
    'A secret-based AzureWebJobsStorage setting is present.'

$webSettings = @(Invoke-AzJson -Arguments @(
    'webapp', 'config', 'appsettings', 'list', '--name', $WebAppName,
    '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json'
))
$webSettingMap = @{}
foreach ($setting in $webSettings) { $webSettingMap[$setting.name] = $setting.value }
Assert-Condition ($webSettingMap.FOUNDRY_PROJECT_ENDPOINT -eq $ProjectEndpoint) `
    'The frontend uses an unexpected Foundry project endpoint.'
Assert-Condition ($webSettingMap.FOUNDRY_AGENT_NAME -eq $AgentName) `
    'The frontend uses an unexpected Prompt Agent name.'
Assert-Condition ($webSettingMap.FOUNDRY_CONNECTION_NAME -eq $ConnectionName) `
    'The frontend uses an unexpected Foundry connection name.'
Assert-Condition ($webSettingMap.OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID -eq $WebIdentityClientId) `
    'Frontend Easy Auth does not use the expected managed identity client assertion.'
Assert-Condition (-not $webSettingMap.ContainsKey('AZURE_CLIENT_SECRET')) `
    'The frontend contains an Azure client secret setting.'

Write-VerificationStep 'Easy Auth policies'
$functionAuthUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
    "/providers/Microsoft.Web/sites/$FunctionAppName/config/authsettingsV2`?api-version=2025-03-01"
$functionAuth = (Invoke-AzJson -Arguments @(
    'rest', '--method', 'get', '--url', $functionAuthUrl,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)).properties
Assert-Condition ($functionAuth.globalValidation.requireAuthentication -eq $true) 'Function Easy Auth is not required.'
Assert-Condition ($functionAuth.globalValidation.unauthenticatedClientAction -eq 'Return401') `
    'Function Easy Auth does not return 401 for unauthenticated requests.'
Assert-Condition ($functionAuth.identityProviders.azureActiveDirectory.registration.clientId -eq $FunctionApiApplicationId) `
    'Function Easy Auth uses an unexpected application registration.'
Assert-Condition (@($functionAuth.identityProviders.azureActiveDirectory.validation.allowedAudiences) -contains $FunctionApiIdentifierUri) `
    'Function Easy Auth does not accept the Function API audience.'
$allowedApplications = @(
    $functionAuth.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications
)
Assert-Condition ($allowedApplications.Count -eq 2) `
    'Function Easy Auth must allow exactly two calling applications.'
Assert-Condition ($allowedApplications -contains $FunctionApiApplicationId) `
    'Function Easy Auth does not allow its own application for interactive consent.'
Assert-Condition ($allowedApplications -contains $OAuthClientApplicationId) `
    'Function Easy Auth does not allow the dedicated Foundry OAuth client.'

$webAuthUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
    "/providers/Microsoft.Web/sites/$WebAppName/config/authsettingsV2`?api-version=2025-03-01"
$webAuth = (Invoke-AzJson -Arguments @(
    'rest', '--method', 'get', '--url', $webAuthUrl,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)).properties
Assert-Condition ($webAuth.globalValidation.requireAuthentication -eq $true) 'Frontend Easy Auth is not required.'
Assert-Condition ($webAuth.globalValidation.unauthenticatedClientAction -eq 'RedirectToLoginPage') `
    'Frontend Easy Auth does not redirect unauthenticated browser requests.'
Assert-Condition ($webAuth.identityProviders.azureActiveDirectory.registration.clientId -eq $WebAppApplicationId) `
    'Frontend Easy Auth uses an unexpected application registration.'

Write-VerificationStep 'Microsoft Entra applications'
$functionApiApp = Invoke-AzJson -Arguments @(
    'ad', 'app', 'show', '--id', $FunctionApiObjectId, '--only-show-errors', '--output', 'json'
)
$functionApiSp = Invoke-AzJson -Arguments @(
    'ad', 'sp', 'show', '--id', $FunctionApiServicePrincipalId, '--only-show-errors', '--output', 'json'
)
$oauthClientApp = Invoke-AzJson -Arguments @(
    'ad', 'app', 'show', '--id', $OAuthClientObjectId, '--only-show-errors', '--output', 'json'
)
$oauthClientSp = Invoke-AzJson -Arguments @(
    'ad', 'sp', 'show', '--id', $OAuthClientServicePrincipalId, '--only-show-errors', '--output', 'json'
)
$webAppRegistration = Invoke-AzJson -Arguments @(
    'ad', 'app', 'show', '--id', $WebAppObjectId, '--only-show-errors', '--output', 'json'
)
$webAppSp = Invoke-AzJson -Arguments @(
    'ad', 'sp', 'show', '--id', $WebAppServicePrincipalId, '--only-show-errors', '--output', 'json'
)

Assert-Condition ($functionApiApp.appId -eq $FunctionApiApplicationId) 'Function API object and application IDs do not match.'
Assert-Condition ($functionApiSp.appId -eq $FunctionApiApplicationId) 'Function API service principal is incorrect.'
Assert-Condition ($oauthClientApp.appId -eq $OAuthClientApplicationId) 'OAuth client object and application IDs do not match.'
Assert-Condition ($oauthClientSp.appId -eq $OAuthClientApplicationId) 'OAuth client service principal is incorrect.'
Assert-Condition ($webAppRegistration.appId -eq $WebAppApplicationId) 'Web object and application IDs do not match.'
Assert-Condition ($webAppSp.appId -eq $WebAppApplicationId) 'Web service principal is incorrect.'
Assert-Condition (
    $FunctionApiApplicationId -ne $OAuthClientApplicationId -and
    $FunctionApiObjectId -ne $OAuthClientObjectId
) 'The Function API and Foundry OAuth client are not separate applications.'

$functionScopes = @($functionApiApp.api.oauth2PermissionScopes | Where-Object {
    $_.value -eq 'user_impersonation' -and $_.type -eq 'User' -and $_.isEnabled
})
Assert-Condition ($functionScopes.Count -eq 1) 'The Function API delegated scope is missing.'
$graphAccess = @($functionApiApp.requiredResourceAccess | Where-Object resourceAppId -eq '00000003-0000-0000-c000-000000000000')
Assert-Condition (@($graphAccess.resourceAccess | Where-Object {
    $_.id -eq 'e1fe6dd8-ba31-4d61-89e7-88639da4683d' -and $_.type -eq 'Scope'
}).Count -eq 1) 'The Function API does not request delegated Graph User.Read.'
$oauthApiAccess = @($oauthClientApp.requiredResourceAccess | Where-Object resourceAppId -eq $FunctionApiApplicationId)
Assert-Condition (
    @($oauthClientApp.requiredResourceAccess).Count -eq 1 -and
    $oauthApiAccess.Count -eq 1 -and
    @($oauthApiAccess[0].resourceAccess).Count -eq 1 -and
    $oauthApiAccess[0].resourceAccess[0].id -eq $functionScopes[0].id
) 'The OAuth client must request only Function user_impersonation.'
Assert-Condition (@($webAppRegistration.requiredResourceAccess).Count -eq 1) `
    'The Web application must request only one Foundry resource permission set.'

Write-VerificationStep 'Federated credentials and secrets'
$functionFics = @(Invoke-AzJson -Arguments @(
    'ad', 'app', 'federated-credential', 'list', '--id', $FunctionApiObjectId,
    '--only-show-errors', '--output', 'json'
))
$webFics = @(Invoke-AzJson -Arguments @(
    'ad', 'app', 'federated-credential', 'list', '--id', $WebAppObjectId,
    '--only-show-errors', '--output', 'json'
))
Assert-Condition (@($functionFics | Where-Object {
    $_.subject -eq $FunctionIdentityPrincipalId -and $_.audiences -contains 'api://AzureADTokenExchange'
}).Count -eq 1) 'The Function managed identity federated credential is missing.'
Assert-Condition (@($webFics | Where-Object {
    $_.subject -eq $WebIdentityPrincipalId -and $_.audiences -contains 'api://AzureADTokenExchange'
}).Count -eq 1) 'The Web managed identity federated credential is missing.'

if ($RequireNoFunctionApiSecrets) {
    Assert-Condition (@($functionApiApp.passwordCredentials).Count -eq 0) `
        'The Function API contains a client secret.'
}
$now = [DateTimeOffset]::UtcNow
$activeOAuthSecrets = @($oauthClientApp.passwordCredentials | Where-Object {
    [DateTimeOffset]$_.startDateTime -le $now -and [DateTimeOffset]$_.endDateTime -gt $now
})
Assert-Condition ($activeOAuthSecrets.Count -ge 1) 'The dedicated OAuth client has no active credential.'
Assert-Condition (@($webAppRegistration.passwordCredentials).Count -eq 0) 'The Web application contains a client secret.'

Write-VerificationStep 'Microsoft Foundry resources and connection'
$foundry = Invoke-AzJson -Arguments @(
    'cognitiveservices', 'account', 'show', '--name', $FoundryAccountName,
    '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json'
)
Assert-Condition ($foundry.kind -eq 'AIServices') 'The Foundry account kind is not AIServices.'
Assert-Condition ($foundry.properties.disableLocalAuth -eq $true) 'Foundry local authentication is enabled.'
$project = Invoke-AzJson -Arguments @(
    'rest', '--method', 'get', '--url', "https://management.azure.com$FoundryProjectId`?api-version=2026-05-01",
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)
Assert-Condition (($project.name -split '/')[-1] -eq $FoundryProjectName) 'The Foundry project output is inconsistent.'

$connectionUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
    "/providers/Microsoft.CognitiveServices/accounts/$FoundryAccountName/projects/$FoundryProjectName" +
    "/connections/$ConnectionName`?api-version=2025-12-01"
$connection = Invoke-AzJson -Arguments @(
    'rest', '--method', 'get', '--url', $connectionUrl,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)
Assert-Condition ($connection.properties.authType -eq 'OAuth2') 'The MCP connection does not use OAuth2.'
Assert-Condition ($connection.properties.target -eq $McpServerUrl) 'The MCP connection targets an unexpected URL.'
Assert-Condition ($connection.properties.isSharedToAll -eq $false) 'The MCP connection is shared to all users.'
$connectionScopes = @($connection.properties.scopes)
Assert-Condition (
    $connectionScopes.Count -eq 2 -and
    $connectionScopes -contains "$FunctionApiIdentifierUri/user_impersonation" -and
    $connectionScopes -contains 'offline_access'
) 'The MCP connection scopes are incorrect.'
Assert-Condition (@($oauthClientApp.web.redirectUris) -contains $connection.properties.redirectUrl) `
    'The Foundry callback URI is absent from the OAuth client.'

$agentVerified = $false
if ($RequireAgent) {
    Write-VerificationStep 'Prompt Agent definition'
    $token = & az account get-access-token --subscription $SubscriptionId `
        --scope 'https://ai.azure.com/.default' --query accessToken --output tsv --only-show-errors
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'A Foundry data-plane token could not be acquired.'
    }
    try {
        $headers = @{ Authorization = "Bearer $token" }
        $agent = Invoke-RestMethod -Method Get -Headers $headers `
            -Uri "$ProjectEndpoint/agents/$AgentName`?api-version=v1"
        $versions = Invoke-RestMethod -Method Get -Headers $headers `
            -Uri "$ProjectEndpoint/agents/$AgentName/versions`?api-version=v1"
    }
    finally {
        $token = $null
        $headers = $null
    }

    $definitions = @()
    foreach ($container in @($agent, $versions)) {
        if ($container.PSObject.Properties['definition']) {
            $definitions += $container.definition
        }
        $items = @()
        if ($container.PSObject.Properties['value']) {
            $items += @($container.value)
        }
        if ($container.PSObject.Properties['data']) {
            $items += @($container.data)
        }
        foreach ($item in $items) {
            if ($item.PSObject.Properties['definition']) {
                $definitions += $item.definition
            }
        }
    }
    $definition = $definitions | Where-Object kind -eq 'prompt' | Select-Object -First 1
    Assert-Condition ($null -ne $definition) 'No Prompt Agent definition was returned.'
    $mcpTool = @($definition.tools | Where-Object {
        $_.type -eq 'mcp' -and $_.project_connection_id -eq $ConnectionName
    }) | Select-Object -First 1
    Assert-Condition ($null -ne $mcpTool) 'The Prompt Agent does not reference the expected MCP connection.'
    Assert-Condition ($mcpTool.server_url -eq $McpServerUrl) 'The Prompt Agent MCP URL is incorrect.'
    $allowedToolNames = @()
    foreach ($allowedTool in @($mcpTool.allowed_tools)) {
        if ($allowedTool -is [string]) {
            $allowedToolNames += $allowedTool
        }
        elseif ($allowedTool.PSObject.Properties['tool_names']) {
            $allowedToolNames += @($allowedTool.tool_names)
        }
    }
    Assert-Condition ($allowedToolNames -contains 'get_my_profile') `
        'The Prompt Agent does not allow get_my_profile.'
    $agentVerified = $true
}

Write-VerificationStep 'Completed'

[pscustomobject]@{
    Status = 'passed'
    ReadOnly = $true
    SecretValuesPrinted = $false
    ApplicationsSeparated = $true
    FunctionAllowedApplicationCount = $allowedApplications.Count
    FunctionApiSecretCount = @($functionApiApp.passwordCredentials).Count
    ActiveOAuthClientSecretCount = $activeOAuthSecrets.Count
    FoundryConnection = $ConnectionName
    AgentVerified = $agentVerified
} | ConvertTo-Json -Depth 4
