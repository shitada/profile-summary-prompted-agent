targetScope = 'resourceGroup'

@description('Existing Azure Functions application name.')
param functionAppName string

@description('Existing App Service frontend name.')
param webAppName string

@description('Existing Storage account name used by Azure Functions.')
param storageAccountName string

@description('Existing Application Insights component name.')
param applicationInsightsName string

@description('Function user-assigned managed identity client ID.')
param functionIdentityClientId string

@description('Web user-assigned managed identity client ID.')
param webIdentityClientId string

@minLength(36)
@maxLength(36)
@description('Function API application ID.')
param functionApiApplicationId string

@description('Function API identifier URI accepted as Token A audience.')
param functionApiIdentifierUri string

@minLength(36)
@maxLength(36)
@description('Dedicated Foundry MCP OAuth client application ID.')
param oauthClientApplicationId string

@minLength(36)
@maxLength(36)
@description('Web application registration ID.')
param webApplicationId string

@description('Foundry project endpoint.')
param foundryProjectEndpoint string

@description('Prompt Agent name created by the post-provision script.')
param foundryAgentName string = 'profile-summary-agent'

@description('Foundry project connection name created by the post-provision script.')
param foundryConnectionName string = 'profile-mcp-oauth'

var functionAppHostname = '${functionAppName}.azurewebsites.net'
var functionAppUrl = 'https://${functionAppHostname}'
var webAppHostname = '${webAppName}.azurewebsites.net'
var webAppUrl = 'https://${webAppHostname}'
var graphConsentUrl = '${functionAppUrl}/.auth/login/aad?post_login_redirect_uri=%2Fapi%2Fconsent-complete'
var tenantIssuer = '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'

resource functionApp 'Microsoft.Web/sites@2025-03-01' existing = {
  name: functionAppName
}

resource webApp 'Microsoft.Web/sites@2025-03-01' existing = {
  name: webAppName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: storageAccountName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource functionAppSettings 'Microsoft.Web/sites/config@2025-03-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${functionIdentityClientId};Authorization=AAD'
    APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString
    AzureWebJobsStorage__accountName: storageAccount.name
    AzureWebJobsStorage__clientId: functionIdentityClientId
    AzureWebJobsStorage__credential: 'managedidentity'
    ENTRA_APPLICATION_CLIENT_ID: functionApiApplicationId
    OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID: functionIdentityClientId
    PUBLIC_BASE_URL: functionAppUrl
    TOKEN_EXCHANGE_AUDIENCE: 'api://AzureADTokenExchange'
    OTEL_SERVICE_NAME: 'profile-mcp-function'
  }
}

resource functionAuthSettings 'Microsoft.Web/sites/config@2025-03-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        isAutoProvisioned: false
        registration: {
          clientId: functionApiApplicationId
          clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
          openIdIssuer: tenantIssuer
        }
        login: {
          loginParameters: [
            'scope=openid profile email offline_access https://graph.microsoft.com/User.Read'
          ]
        }
        validation: {
          allowedAudiences: [
            functionApiIdentifierUri
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: [
              functionApiApplicationId
              oauthClientApplicationId
            ]
            allowedPrincipals: {}
          }
          jwtClaimChecks: {}
        }
      }
    }
    login: {
      preserveUrlFragmentsForLogins: false
      tokenStore: {
        enabled: true
        tokenRefreshExtensionHours: 72
      }
    }
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
  }
}

resource webConfig 'Microsoft.Web/sites/config@2025-03-01' = {
  parent: webApp
  name: 'web'
  properties: {
    cors: {
      allowedOrigins: [
        webAppUrl
      ]
      supportCredentials: true
    }
  }
}

resource webAppSettings 'Microsoft.Web/sites/config@2025-03-01' = {
  parent: webApp
  name: 'appsettings'
  properties: {
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${webIdentityClientId};Authorization=AAD'
    APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString
    FOUNDRY_AGENT_NAME: foundryAgentName
    FOUNDRY_CONNECTION_NAME: foundryConnectionName
    FOUNDRY_PROJECT_ENDPOINT: foundryProjectEndpoint
    GRAPH_CONSENT_URL: graphConsentUrl
    OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID: webIdentityClientId
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    OTEL_SERVICE_NAME: 'profile-chat-web'
  }
}

resource webAuthSettings 'Microsoft.Web/sites/config@2025-03-01' = {
  parent: webApp
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureActiveDirectory'
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        isAutoProvisioned: false
        registration: {
          clientId: webApplicationId
          clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
          openIdIssuer: tenantIssuer
        }
        login: {
          loginParameters: [
            'scope=openid profile email offline_access https://ai.azure.com/.default'
          ]
        }
        validation: {
          allowedAudiences: [
            webApplicationId
          ]
          jwtClaimChecks: {}
        }
      }
    }
    login: {
      preserveUrlFragmentsForLogins: false
      tokenStore: {
        enabled: true
        tokenRefreshExtensionHours: 72
      }
    }
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
  }
  dependsOn: [
    webConfig
  ]
}

output graphConsentUrl string = graphConsentUrl
output allowedApplicationCount int = 2
