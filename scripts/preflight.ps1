[CmdletBinding()]
param(
    [string]$SubscriptionId = '',
    [string]$TenantId = '',
    [string]$Location = '',
    [string]$WebLocation = '',
    [string]$PrincipalId = '',
    [ValidateSet('User', 'ServicePrincipal', 'Group')]
    [string]$PrincipalType = 'User',
    [string]$ModelName = 'gpt-5-mini',
    [string]$ModelVersion = '2025-08-07',
    [string]$ModelSkuName = 'GlobalStandard',
    [ValidateRange(1, 1000)]
    [int]$ModelCapacity = 10,
    [string]$WebSkuName = 'B1',
    [switch]$SetAzdEnvironment
)

. (Join-Path $PSScriptRoot 'common.ps1')

$SubscriptionId = Resolve-AzdValue -Value $SubscriptionId -Name 'AZURE_SUBSCRIPTION_ID'
$Location = Resolve-AzdValue -Value $Location -Name 'AZURE_LOCATION'
if ([string]::IsNullOrWhiteSpace($WebLocation)) {
    $WebLocation = Resolve-AzdValue -Value '' -Name 'WEB_LOCATION' -Optional
    if ([string]::IsNullOrWhiteSpace($WebLocation)) {
        $WebLocation = $Location
    }
}

$account = Invoke-AzJson -Arguments @(
    'account', 'show', '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json'
)
Assert-Condition ($account.state -eq 'Enabled') 'The selected subscription is not enabled.'
if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
    Assert-Condition ($account.tenantId -eq $TenantId) 'The selected subscription belongs to a different tenant.'
}
$TenantId = $account.tenantId

if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
    if ($PrincipalType -eq 'User') {
        $PrincipalId = (& az ad signed-in-user show --query id --output tsv --only-show-errors 2>$null).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
        throw 'Pass -PrincipalId when the signed-in Azure CLI identity is not a user.'
    }
}

$requiredProviders = @(
    'Microsoft.Authorization',
    'Microsoft.CognitiveServices',
    'Microsoft.Insights',
    'Microsoft.ManagedIdentity',
    'Microsoft.OperationalInsights',
    'Microsoft.Resources',
    'Microsoft.Storage',
    'Microsoft.Web'
)
$providerStates = foreach ($provider in $requiredProviders) {
    $state = & az provider show --namespace $provider --subscription $SubscriptionId `
        --query registrationState --output tsv --only-show-errors
    [pscustomobject]@{ Namespace = $provider; Registered = $state -eq 'Registered' }
}

$roleAssignments = @(Invoke-AzJson -Arguments @(
    'role', 'assignment', 'list', '--assignee-object-id', $PrincipalId,
    '--scope', "/subscriptions/$SubscriptionId", '--include-inherited',
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
))
$roleNames = @($roleAssignments | ForEach-Object roleDefinitionName | Sort-Object -Unique)
$canAssignRoles = @($roleNames | Where-Object {
    $_ -in @('Owner', 'User Access Administrator', 'Role Based Access Control Administrator')
}).Count -gt 0

$flexLocations = Invoke-AzJson -Arguments @(
    'functionapp', 'list-flexconsumption-locations', '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json'
)
$normalizedLocation = ($Location -replace '\s', '').ToLowerInvariant()
$flexSupported = ($flexLocations | ConvertTo-Json -Depth 20 -Compress).ToLowerInvariant() -match [regex]::Escape($normalizedLocation)

$webLocations = Invoke-AzJson -Arguments @(
    'appservice', 'list-locations', '--sku', $WebSkuName, '--linux-workers-enabled',
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)
$normalizedWebLocation = ($WebLocation -replace '\s', '').ToLowerInvariant()
$webSupported = ($webLocations | ConvertTo-Json -Depth 20 -Compress).ToLowerInvariant() -match [regex]::Escape($normalizedWebLocation)

$webRuntimes = @(Invoke-AzJson -Arguments @(
    'webapp', 'list-runtimes', '--os', 'linux', '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json'
))
$python313Supported = @($webRuntimes | Where-Object {
    $_.config -eq 'PYTHON|3.13' -and $_.support -eq 'Active'
}).Count -gt 0

$models = @(Invoke-AzJson -Arguments @(
    'cognitiveservices', 'model', 'list', '--location', $Location,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
))
$modelMatches = @($models | Where-Object {
    $_.model.name -eq $ModelName -and
    $_.model.version -eq $ModelVersion -and
    $_.model.skus.name -contains $ModelSkuName
})

$usages = @(Invoke-AzJson -Arguments @(
    'cognitiveservices', 'usage', 'list', '--location', $Location,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
))
$usage = $usages | Where-Object {
    $_.name.value -like "*.$ModelName"
} | Select-Object -First 1
$availableCapacity = if ($usage) {
    [double]$usage.limit - [double]$usage.currentValue
}
else {
    0
}

$foundryServicePrincipals = @(Invoke-AzJson -Arguments @(
    'ad', 'sp', 'list', '--filter', "servicePrincipalNames/any(value:value eq 'https://ai.azure.com')",
    '--only-show-errors', '--output', 'json'
))
Assert-Condition ($foundryServicePrincipals.Count -eq 1) 'The tenant Foundry resource service principal could not be resolved uniquely.'
$foundryServicePrincipal = $foundryServicePrincipals[0]
$delegatedScopes = @($foundryServicePrincipal.oauth2PermissionScopes | Where-Object {
    $_.isEnabled -and $_.type -eq 'User'
})
$foundryScope = $delegatedScopes | Where-Object value -eq 'user_impersonation' | Select-Object -First 1
if (-not $foundryScope -and $delegatedScopes.Count -eq 1) {
    $foundryScope = $delegatedScopes[0]
}
Assert-Condition ($null -ne $foundryScope) 'A user-consentable Foundry delegated scope could not be resolved.'

$checks = [ordered]@{
    ProvidersRegistered = @($providerStates | Where-Object { -not $_.Registered }).Count -eq 0
    CanAssignRoles = $canAssignRoles
    FlexConsumptionLocation = $flexSupported
    AppServiceLocation = $webSupported
    Python313Runtime = $python313Supported
    ModelAvailable = $modelMatches.Count -gt 0
    ModelQuotaAvailable = $availableCapacity -ge $ModelCapacity
    FoundryDelegatedScopeResolved = $true
}
$ready = @($checks.Values | Where-Object { -not $_ }).Count -eq 0

if ($SetAzdEnvironment) {
    $values = [ordered]@{
        AZURE_SUBSCRIPTION_ID = $SubscriptionId
        AZURE_TENANT_ID = $TenantId
        AZURE_LOCATION = $Location
        WEB_LOCATION = $WebLocation
        AZURE_PRINCIPAL_ID = $PrincipalId
        AZURE_PRINCIPAL_TYPE = $PrincipalType
        FOUNDRY_RESOURCE_APP_ID = $foundryServicePrincipal.appId
        FOUNDRY_DELEGATED_PERMISSION_ID = $foundryScope.id
        MODEL_NAME = $ModelName
        MODEL_VERSION = $ModelVersion
        MODEL_SKU_NAME = $ModelSkuName
        MODEL_CAPACITY = [string]$ModelCapacity
        WEB_SKU_NAME = $WebSkuName
    }
    foreach ($entry in $values.GetEnumerator()) {
        & azd env set $entry.Key $entry.Value --no-prompt | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set azd environment value $($entry.Key)."
        }
    }
}

[pscustomobject]@{
    Status = if ($ready) { 'ready' } else { 'blocked' }
    ReadOnlyAzure = $true
    AzdEnvironmentUpdated = [bool]$SetAzdEnvironment
    Checks = $checks
    MissingProviders = @($providerStates | Where-Object { -not $_.Registered } | ForEach-Object Namespace)
    AvailableModelCapacity = $availableCapacity
    FoundryPermission = [ordered]@{
        Value = $foundryScope.value
        Type = $foundryScope.type
    }
} | ConvertTo-Json -Depth 6

if (-not $ready) {
    throw 'One or more preflight checks failed. Review the structured result above before provisioning.'
}
