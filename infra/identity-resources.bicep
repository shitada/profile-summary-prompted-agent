targetScope = 'resourceGroup'

extension microsoftGraphV1

@description('azd environment name used in generic display names.')
param environmentName string

@minLength(3)
@maxLength(12)
@description('Lowercase alphanumeric suffix shared with the Azure resources.')
param resourceToken string

@description('Function App base URL used for the Easy Auth callback URI.')
param functionAppUrl string

@description('Web App base URL used for the Easy Auth callback URI.')
param webAppUrl string

@description('Function user-assigned managed identity principal ID.')
param functionIdentityPrincipalId string

@description('Web user-assigned managed identity principal ID.')
param webIdentityPrincipalId string

@minLength(36)
@maxLength(36)
@description('Microsoft Foundry resource application ID resolved during preflight.')
param foundryResourceAppId string

@minLength(36)
@maxLength(36)
@description('Microsoft Foundry delegated permission ID resolved during preflight.')
param foundryDelegatedPermissionId string

@description('Optional service-management reference required by some tenants.')
param serviceManagementReference string = ''

var functionAppName = 'func-profile-${resourceToken}'
var webAppName = 'web-profile-${resourceToken}'
var functionApiUniqueName = '${functionAppName}-api'
var functionApiIdentifierUri = 'api://${functionApiUniqueName}'
var functionScopeId = guid(functionApiUniqueName, 'user_impersonation')
var webApplicationUniqueName = '${webAppName}-client'
var oauthClientUniqueName = '${functionAppName}-foundry-mcp-oauth-client'
var graphResourceAppId = '00000003-0000-0000-c000-000000000000'
var graphUserReadPermissionId = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'
var tokenExchangeAudience = 'api://AzureADTokenExchange'
var tenantIssuer = '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'

resource functionApiApplication 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: functionApiUniqueName
  displayName: 'Profile MCP API (${environmentName})'
  serviceManagementReference: !empty(serviceManagementReference) ? serviceManagementReference : null
  signInAudience: 'AzureADMyOrg'
  identifierUris: [
    functionApiIdentifierUri
  ]
  api: {
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [
      {
        id: functionScopeId
        isEnabled: true
        type: 'User'
        value: 'user_impersonation'
        adminConsentDisplayName: 'Access the profile MCP API'
        adminConsentDescription: 'Allow this client to call the profile MCP API for a signed-in user.'
        userConsentDisplayName: 'Access your profile MCP tool'
        userConsentDescription: 'Allow this client to call the profile MCP tool as you.'
      }
    ]
  }
  web: {
    redirectUris: [
      '${functionAppUrl}/.auth/login/aad/callback'
    ]
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: true
    }
  }
  requiredResourceAccess: [
    {
      resourceAppId: graphResourceAppId
      resourceAccess: [
        {
          id: graphUserReadPermissionId
          type: 'Scope'
        }
      ]
    }
  ]
}

resource functionApiServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: functionApiApplication.appId
  appRoleAssignmentRequired: false
}

resource functionFederatedCredential 'Microsoft.Graph/applications/federatedIdentityCredentials@v1.0' = {
  name: '${functionApiApplication.uniqueName}/function-managed-identity'
  audiences: [
    tokenExchangeAudience
  ]
  issuer: tenantIssuer
  subject: functionIdentityPrincipalId
  description: 'UAMI client assertion for Function Easy Auth and Graph OBO.'
}

resource webApplication 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: webApplicationUniqueName
  displayName: 'Profile Chat (${environmentName})'
  serviceManagementReference: !empty(serviceManagementReference) ? serviceManagementReference : null
  signInAudience: 'AzureADMyOrg'
  web: {
    redirectUris: [
      '${webAppUrl}/.auth/login/aad/callback'
    ]
    implicitGrantSettings: {
      enableAccessTokenIssuance: false
      enableIdTokenIssuance: true
    }
  }
  requiredResourceAccess: [
    {
      resourceAppId: foundryResourceAppId
      resourceAccess: [
        {
          id: foundryDelegatedPermissionId
          type: 'Scope'
        }
      ]
    }
  ]
}

resource webServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: webApplication.appId
  appRoleAssignmentRequired: false
}

resource webFederatedCredential 'Microsoft.Graph/applications/federatedIdentityCredentials@v1.0' = {
  name: '${webApplication.uniqueName}/web-managed-identity'
  audiences: [
    tokenExchangeAudience
  ]
  issuer: tenantIssuer
  subject: webIdentityPrincipalId
  description: 'UAMI client assertion for App Service Easy Auth.'
}

resource oauthClientApplication 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: oauthClientUniqueName
  displayName: 'Profile Foundry MCP OAuth client (${environmentName})'
  serviceManagementReference: !empty(serviceManagementReference) ? serviceManagementReference : null
  signInAudience: 'AzureADMyOrg'
  requiredResourceAccess: [
    {
      resourceAppId: functionApiApplication.appId
      resourceAccess: [
        {
          id: functionScopeId
          type: 'Scope'
        }
      ]
    }
  ]
}

resource oauthClientServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: oauthClientApplication.appId
  appRoleAssignmentRequired: false
}

output functionApiApplicationId string = functionApiApplication.appId
output functionApiApplicationObjectId string = functionApiApplication.id
output functionApiServicePrincipalId string = functionApiServicePrincipal.id
output functionApiIdentifierUri string = functionApiIdentifierUri
output functionApiScope string = '${functionApiIdentifierUri}/user_impersonation'
output webApplicationId string = webApplication.appId
output webApplicationObjectId string = webApplication.id
output webServicePrincipalId string = webServicePrincipal.id
output oauthClientApplicationId string = oauthClientApplication.appId
output oauthClientApplicationObjectId string = oauthClientApplication.id
output oauthClientServicePrincipalId string = oauthClientServicePrincipal.id
