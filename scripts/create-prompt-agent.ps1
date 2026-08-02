[CmdletBinding()]
param(
    [switch]$ConfirmAzureWrite,
    [string]$SubscriptionId = '',
    [string]$ProjectEndpoint = '',
    [string]$AccountName = '',
    [string]$ProjectName = '',
    [string]$ResourceGroup = '',
    [string]$McpServerUrl = '',
    [string]$ConnectionName = '',
    [string]$AgentName = '',
    [string]$ModelDeploymentName = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-ExplicitAzureWrite -Confirmed $ConfirmAzureWrite -Operation 'Prompt Agent creation'

$SubscriptionId = Resolve-AzdValue -Value $SubscriptionId -Name 'AZURE_SUBSCRIPTION_ID'
$ProjectEndpoint = Resolve-AzdValue -Value $ProjectEndpoint -Name 'AZURE_AI_PROJECT_ENDPOINT'
$AccountName = Resolve-AzdValue -Value $AccountName -Name 'AZURE_AI_ACCOUNT_NAME'
$ProjectName = Resolve-AzdValue -Value $ProjectName -Name 'AZURE_AI_PROJECT_NAME'
$ResourceGroup = Resolve-AzdValue -Value $ResourceGroup -Name 'AZURE_RESOURCE_GROUP'
$McpServerUrl = Resolve-AzdValue -Value $McpServerUrl -Name 'MCP_SERVER_URL'
$ConnectionName = Resolve-AzdValue -Value $ConnectionName -Name 'FOUNDRY_CONNECTION_NAME'
$AgentName = Resolve-AzdValue -Value $AgentName -Name 'FOUNDRY_AGENT_NAME'
$ModelDeploymentName = Resolve-AzdValue -Value $ModelDeploymentName -Name 'AZURE_AI_MODEL_DEPLOYMENT_NAME'

$connectionUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
    "/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName" +
    "/connections/$ConnectionName`?api-version=2025-12-01"
$connection = Invoke-AzJson -Arguments @(
    'rest', '--method', 'get', '--url', $connectionUri,
    '--subscription', $SubscriptionId, '--only-show-errors', '--output', 'json'
)
Assert-Condition ($connection.properties.authType -eq 'OAuth2') 'The Foundry MCP connection does not use OAuth2.'
Assert-Condition ($connection.properties.target -eq $McpServerUrl) 'The Foundry MCP connection targets a different server.'
Assert-Condition ($connection.properties.isSharedToAll -eq $false) 'The Foundry MCP connection must remain per-user.'

$instructions = @"
あなたは Microsoft Foundry 上で動作する自己紹介アシスタントです。

- ユーザーが自分のプロフィールや自己紹介について尋ねたら、必ず get_my_profile を呼び出してください。
- get_my_profile は、いま話しかけているユーザー本人のプロフィールだけを返します。他人の情報は取得しないでください。
- ツールに引数はありません。氏名、メールアドレス、object ID を尋ねたり、推測したり、引数として渡したりしないでください。
- ツールが返した項目だけを使い、日本語で自然な 3～4 文の自己紹介にまとめてください。欠けている項目は推測しないでください。
- graph_consent_required の場合は、安全な consent action を案内し、本人が同意してから同じ依頼を再実行するよう伝えてください。
- その他の error は correlationId と安全な message だけを簡潔に伝えてください。
"@

$definition = [ordered]@{
    kind = 'prompt'
    model = $ModelDeploymentName
    instructions = $instructions
    tools = @(
        [ordered]@{
            type = 'mcp'
            server_label = 'profile_mcp'
            server_url = $McpServerUrl
            allowed_tools = @('get_my_profile')
            require_approval = 'never'
            project_connection_id = $ConnectionName
        }
    )
}

$token = & az account get-access-token --subscription $SubscriptionId `
    --scope 'https://ai.azure.com/.default' --query accessToken --output tsv --only-show-errors
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'A Foundry data-plane token could not be acquired.'
}
try {
    $headers = @{ Authorization = "Bearer $token" }
    $uri = "$ProjectEndpoint/agents/$AgentName/versions?api-version=v1"
    $body = @{ definition = $definition } | ConvertTo-Json -Depth 12
    $created = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body))
}
finally {
    $token = $null
    $headers = $null
}

[pscustomobject]@{
    Status = 'created'
    AgentName = $AgentName
    Version = $created.version
    Published = $false
    AllowedTools = @('get_my_profile')
    NextStep = 'Run verify-deployment.ps1, then test consent and profile retrieval in a fresh InPrivate session.'
} | ConvertTo-Json -Depth 4
