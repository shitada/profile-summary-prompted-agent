[CmdletBinding()]
param(
    [switch]$ConfirmAzureWrite,
    [string]$OAuthClientAppObjectId = '',
    [string]$TenantId = '',
    [ValidateRange(1, 3)]
    [int]$RetainNewest = 1,
    [switch]$UseDeviceAuthentication
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ExplicitAzureWrite -Confirmed $ConfirmAzureWrite -Operation 'OAuth client credential cleanup'

$OAuthClientAppObjectId = Resolve-AzdValue -Value $OAuthClientAppObjectId -Name 'MCP_OAUTH_CLIENT_APPLICATION_OBJECT_ID'
$TenantId = Resolve-AzdValue -Value $TenantId -Name 'AZURE_TENANT_ID'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
if (-not (Get-MgContext)) {
    if (-not $UseDeviceAuthentication) {
        throw 'No process-scoped Microsoft Graph session exists. Re-run with -UseDeviceAuthentication.'
    }
    Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' `
        -ContextScope Process -UseDeviceAuthentication -NoWelcome
}
$context = Get-MgContext
Assert-Condition ($null -ne $context -and $context.TenantId -eq $TenantId) `
    'Microsoft Graph is not connected to the expected tenant.'

$appUri = "https://graph.microsoft.com/v1.0/applications/$OAuthClientAppObjectId"
$app = Invoke-MgGraphRequest -Method Get -Uri "$appUri`?`$select=passwordCredentials"
$managedCredentials = @($app.passwordCredentials | Where-Object {
    $_.displayName -eq 'foundry-mcp-custom-oauth'
} | Sort-Object { [DateTimeOffset]$_.endDateTime } -Descending)

$now = [DateTimeOffset]::UtcNow
$activeCredentials = @($managedCredentials | Where-Object {
    [DateTimeOffset]$_.startDateTime -le $now -and [DateTimeOffset]$_.endDateTime -gt $now
})
Assert-Condition ($activeCredentials.Count -ge 1) 'No active managed OAuth client credential exists; cleanup was not attempted.'

$retainedKeyIds = @($activeCredentials | Select-Object -First $RetainNewest | ForEach-Object keyId)
$removeCandidates = @($managedCredentials | Where-Object { $retainedKeyIds -notcontains $_.keyId })
foreach ($credential in $removeCandidates) {
    $removeBody = @{ keyId = $credential.keyId } | ConvertTo-Json
    Invoke-MgGraphRequest -Method Post -Uri "$appUri/removePassword" `
        -Body $removeBody -ContentType 'application/json' | Out-Null
}

[pscustomobject]@{
    Status = 'completed'
    ManagedCredentialCountBefore = $managedCredentials.Count
    RetainedCredentialCount = $retainedKeyIds.Count
    RemovedCredentialCount = $removeCandidates.Count
    SecretValuesPrinted = $false
    CredentialIdsPrinted = $false
} | ConvertTo-Json -Compress
