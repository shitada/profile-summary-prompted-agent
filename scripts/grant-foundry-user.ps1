[CmdletBinding()]
param(
    [switch]$ConfirmAzureWrite,
    [Parameter(Mandatory)]
    [string]$PrincipalId,
    [ValidateSet('User', 'ServicePrincipal', 'Group')]
    [string]$PrincipalType = 'User',
    [string]$SubscriptionId = '',
    [string]$FoundryProjectId = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ExplicitAzureWrite -Confirmed $ConfirmAzureWrite -Operation 'Foundry User role assignment'

$SubscriptionId = Resolve-AzdValue -Value $SubscriptionId -Name 'AZURE_SUBSCRIPTION_ID'
$FoundryProjectId = Resolve-AzdValue -Value $FoundryProjectId -Name 'AZURE_AI_PROJECT_ID'
$foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
$roleDefinitionId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$foundryUserRoleId"

$existing = @(Invoke-AzJson -Arguments @(
    'role', 'assignment', 'list', '--assignee-object-id', $PrincipalId,
    '--scope', $FoundryProjectId, '--role', $foundryUserRoleId,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
) | Where-Object {
    $_.scope -eq $FoundryProjectId -and $_.roleDefinitionId -eq $roleDefinitionId
})

if ($existing.Count -eq 0) {
    Invoke-AzJson -Arguments @(
        'role', 'assignment', 'create', '--assignee-object-id', $PrincipalId,
        '--assignee-principal-type', $PrincipalType,
        '--scope', $FoundryProjectId, '--role', $foundryUserRoleId,
        '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
    ) | Out-Null
    $created = $true
}
else {
    $created = $false
}

[pscustomobject]@{
    Status = 'configured'
    Role = 'Foundry User'
    Scope = 'Project'
    Created = $created
    PrincipalValuePrinted = $false
} | ConvertTo-Json -Compress
