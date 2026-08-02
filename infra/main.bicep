targetScope = 'subscription'

@minLength(1)
@description('azd environment name.')
param environmentName string

@description('Resource group name.')
param resourceGroupName string = 'rg-profile-${environmentName}'

@description('Primary Azure region for Foundry and Azure Functions.')
param location string

@description('Azure region for the App Service frontend. Defaults to the primary region.')
param webLocation string = location

@description('Deployment principal configured as Foundry project manager and user.')
param principalId string = ''

@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param principalType string = 'User'

@minLength(36)
@maxLength(36)
@description('Microsoft Foundry resource application ID resolved by preflight.')
param foundryResourceAppId string

@minLength(36)
@maxLength(36)
@description('Microsoft Foundry delegated permission ID resolved by preflight.')
param foundryDelegatedPermissionId string

@description('Optional service-management reference required by some tenants.')
param serviceManagementReference string = ''

@description('Foundry project name.')
param foundryProjectName string = 'profile-summary'

@description('Prompt Agent name created after provisioning.')
param foundryAgentName string = 'profile-summary-agent'

@description('Foundry MCP OAuth connection name created after provisioning.')
param foundryConnectionName string = 'profile-mcp-oauth'

@description('Foundry model deployment name.')
param modelDeploymentName string = 'gpt-5-mini'

@description('Foundry model name.')
param modelName string = 'gpt-5-mini'

@description('Foundry model version available in the selected region.')
param modelVersion string = '2025-08-07'

@description('Foundry model deployment SKU.')
param modelSkuName string = 'GlobalStandard'

@minValue(1)
param modelCapacity int = 10

@description('App Service plan SKU for the Flask frontend.')
param webSkuName string = 'B1'

@description('App Service plan tier for the Flask frontend.')
param webSkuTier string = 'Basic'

@minValue(1)
param webSkuCapacity int = 1

@description('Enable Always On for a paid App Service plan.')
param webAlwaysOn bool = true

var resourceToken = toLower(take(uniqueString(subscription().id, environmentName), 12))
var tags = {
  'azd-env-name': environmentName
  application: 'profile-summary-prompted-agent'
  environment: environmentName
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module core './core-resources.bicep' = {
  name: 'core-resources'
  scope: resourceGroup
  params: {
    location: location
    webLocation: webLocation
    resourceToken: resourceToken
    principalId: principalId
    principalType: principalType
    foundryProjectName: foundryProjectName
    modelDeploymentName: modelDeploymentName
    modelName: modelName
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    webSkuName: webSkuName
    webSkuTier: webSkuTier
    webSkuCapacity: webSkuCapacity
    webAlwaysOn: webAlwaysOn
    tags: tags
  }
}

module identity './identity-resources.bicep' = {
  name: 'identity-resources'
  scope: resourceGroup
  params: {
    environmentName: environmentName
    resourceToken: resourceToken
    functionAppUrl: core.outputs.functionAppUrl
    webAppUrl: core.outputs.webAppUrl
    functionIdentityPrincipalId: core.outputs.functionIdentityPrincipalId
    webIdentityPrincipalId: core.outputs.webIdentityPrincipalId
    foundryResourceAppId: foundryResourceAppId
    foundryDelegatedPermissionId: foundryDelegatedPermissionId
    serviceManagementReference: serviceManagementReference
  }
}

module runtime './runtime-configuration.bicep' = {
  name: 'runtime-configuration'
  scope: resourceGroup
  params: {
    functionAppName: core.outputs.functionAppName
    webAppName: core.outputs.webAppName
    storageAccountName: core.outputs.storageAccountName
    applicationInsightsName: core.outputs.applicationInsightsName
    functionIdentityClientId: core.outputs.functionIdentityClientId
    webIdentityClientId: core.outputs.webIdentityClientId
    functionApiApplicationId: identity.outputs.functionApiApplicationId
    functionApiIdentifierUri: identity.outputs.functionApiIdentifierUri
    oauthClientApplicationId: identity.outputs.oauthClientApplicationId
    webApplicationId: identity.outputs.webApplicationId
    foundryProjectEndpoint: core.outputs.foundryProjectEndpoint
    foundryAgentName: foundryAgentName
    foundryConnectionName: foundryConnectionName
  }
}

output AZURE_LOCATION string = location
output WEB_LOCATION string = webLocation
output AZURE_RESOURCE_GROUP string = resourceGroup.name
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_API_NAME string = core.outputs.functionAppName
output SERVICE_API_URI string = core.outputs.functionAppUrl
output FUNCTION_APP_HOSTNAME string = core.outputs.functionAppHostname
output MCP_SERVER_URL string = core.outputs.mcpServerUrl
output GRAPH_CONSENT_URL string = runtime.outputs.graphConsentUrl
output ENTRA_APPLICATION_ID string = identity.outputs.functionApiApplicationId
output ENTRA_APPLICATION_OBJECT_ID string = identity.outputs.functionApiApplicationObjectId
output ENTRA_SERVICE_PRINCIPAL_ID string = identity.outputs.functionApiServicePrincipalId
output ENTRA_IDENTIFIER_URI string = identity.outputs.functionApiIdentifierUri
output ENTRA_API_SCOPE string = identity.outputs.functionApiScope
output MCP_OAUTH_CLIENT_APPLICATION_ID string = identity.outputs.oauthClientApplicationId
output MCP_OAUTH_CLIENT_APPLICATION_OBJECT_ID string = identity.outputs.oauthClientApplicationObjectId
output MCP_OAUTH_CLIENT_SERVICE_PRINCIPAL_ID string = identity.outputs.oauthClientServicePrincipalId
output FUNCTION_AUTH_ALLOWED_APPLICATION_COUNT int = runtime.outputs.allowedApplicationCount
output FUNCTION_IDENTITY_RESOURCE_ID string = core.outputs.functionIdentityResourceId
output FUNCTION_IDENTITY_CLIENT_ID string = core.outputs.functionIdentityClientId
output FUNCTION_IDENTITY_PRINCIPAL_ID string = core.outputs.functionIdentityPrincipalId
output STORAGE_ACCOUNT_NAME string = core.outputs.storageAccountName
output AZURE_AI_ACCOUNT_NAME string = core.outputs.foundryAccountName
output AZURE_AI_PROJECT_NAME string = core.outputs.foundryProjectName
output AZURE_AI_PROJECT_ID string = core.outputs.foundryProjectId
output AZURE_AI_PROJECT_ENDPOINT string = core.outputs.foundryProjectEndpoint
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = core.outputs.modelDeploymentName
output FOUNDRY_AGENT_NAME string = foundryAgentName
output FOUNDRY_CONNECTION_NAME string = foundryConnectionName
output APPLICATIONINSIGHTS_NAME string = core.outputs.applicationInsightsName
output SERVICE_WEB_NAME string = core.outputs.webAppName
output SERVICE_WEB_URI string = core.outputs.webAppUrl
output WEB_APP_HOSTNAME string = core.outputs.webAppHostname
output WEB_IDENTITY_RESOURCE_ID string = core.outputs.webIdentityResourceId
output WEB_IDENTITY_CLIENT_ID string = core.outputs.webIdentityClientId
output WEB_IDENTITY_PRINCIPAL_ID string = core.outputs.webIdentityPrincipalId
output WEB_ENTRA_APPLICATION_ID string = identity.outputs.webApplicationId
output WEB_ENTRA_APPLICATION_OBJECT_ID string = identity.outputs.webApplicationObjectId
output WEB_ENTRA_SERVICE_PRINCIPAL_ID string = identity.outputs.webServicePrincipalId
