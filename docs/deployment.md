# Deployment

## Deployment Model

このsampleはAzure Developer CLIとsubscription-scope Bicepを使用し、新しいresource groupへ次を作成します。

- Microsoft Foundry account、project、model deployment
- Azure Functions Flex Consumption、Storage、UAMI
- App Service、Linux plan、UAMI
- Log Analytics、Application Insights
- Web、Function API、dedicated MCP OAuth clientの3 Entra applications
- Service principals、federated identity credentials、Azure RBAC
- App settings、CORS、Easy Auth policies

Foundry OAuth connectionとPrompt Agent versionはpost-provision PowerShellで作成します。

## Prerequisites

- Azure CLI、Azure Developer CLI、PowerShell 7
- Python 3.13、Azure Functions Core Tools
- Microsoft Graph PowerShell `Microsoft.Graph.Authentication`
- Azure subscriptionでresourceとrole assignmentを作成できること
- Tenantでapplication、service principal、FIC、client credentialを作成できること
- 選択regionでmodelとquotaが利用可能であること

Graph Bicep extensionを使用するdeployment principalには、tenant側の適切なMicrosoft Graph permissionが必要です。最小権限はtenant policyとdeployment方式に合わせて管理者が決定してください。

## 1. Initialize an azd Environment

```powershell
az login
azd auth login
azd env new
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION <primary-region>
azd env set WEB_LOCATION <web-region>
```

`AZURE_RESOURCE_GROUP`を設定しない場合はenvironment nameから生成されます。ModelとSKUを変更する場合は次を設定します。

```powershell
azd env set MODEL_DEPLOYMENT_NAME <deployment-name>
azd env set MODEL_NAME <model-name>
azd env set MODEL_VERSION <model-version>
azd env set MODEL_SKU_NAME <sku-name>
azd env set MODEL_CAPACITY <capacity>
azd env set WEB_SKU_NAME <sku-name>
azd env set WEB_SKU_TIER <sku-tier>
azd env set WEB_ALWAYS_ON <true-or-false>
```

F1を使用する場合はtierを`Free`、Always Onを`false`にします。F1はavailability、quota、SLA、cold startの制約があるため、既定値はB1です。

Subscription policyがStorage public network accessに承認済みの例外tagを要求する場合だけ、policy ownerが指定した値を設定します。一般環境では未設定のままにします。

```powershell
azd env set STORAGE_SECURITY_CONTROL_TAG_VALUE <approved-value>
```

## 2. Run Preflight

```powershell
./scripts/preflight.ps1 -SetAzdEnvironment
```

PreflightはAzureへresourceを作成せず、次を確認します。

- Required resource providers
- Role assignment作成権限
- Functions Flex Consumption region
- Linux App Service SKU region
- Python 3.13 runtime
- Model name、version、SKU、quota
- Tenant Foundry resource applicationとuser-consentable delegated scope

Model IDやpermission IDを推測してBicepへ固定しません。Preflightがtenantから解決した値をazd environmentへ設定します。

## 3. Validate Locally

```powershell
python -m venv .venv
./.venv/Scripts/python -m pip install `
  -r ./src/web/requirements.txt `
  -r ./src/function/requirements.txt `
  -r ./requirements-dev.txt
./scripts/validate-local.ps1
```

Release候補では、repo外のdenylistを指定します。

```powershell
$env:SENSITIVE_TERMS_FILE = '<path-to-private-denylist>'
./scripts/validate-local.ps1 -RequireDenylist
```

## 4. Review and Provision

Deployment前にBicep what-ifを確認します。Microsoft Graph extensible resourcesはwhat-ifの対象外または結果が限定されることがあるため、Azure resource差分とEntra object差分を別にレビューします。

```powershell
az deployment sub what-if `
  --location <primary-region> `
  --template-file ./infra/main.bicep `
  --parameters ./infra/main.parameters.json

azd provision
```

既存環境へ流用せず、専用の新規resource groupとazd environmentを使用してください。

## 5. Deploy Application Code

```powershell
azd deploy
```

`api`はAzure Functions、`web`はApp Serviceへdeployされます。Webのstartup commandはGunicorn、Function runtimeはPython 3.13です。

## 6. Configure the OAuth Connection

```powershell
./scripts/configure-oauth-connection.ps1 `
  -ConfirmAzureWrite
```

既定ではAzure CLIのWindows Authentication Manager (WAM) sessionからMicrosoft Graph tokenを取得し、process内だけでGraph PowerShellへ渡します。Managed-device Conditional Access環境ではdevice codeを使用しません。

Scriptは次を確認してからwriteします。

- OAuth clientとFunction APIが別application
- OAuth clientがFunction `user_impersonation`だけを要求
- API scopeがFunction APIに属する
- Graph sessionとAzure contextが同じtenant

その後、短期client secretを作成し、custom OAuth connectionへ設定し、Foundry callback URIをOAuth clientへ追加します。Secret値とcallback URLは出力しません。

## 7. Create the Prompt Agent

```powershell
./scripts/create-prompt-agent.ps1 -ConfirmAzureWrite
```

Agentは`get_my_profile`だけをallowlistし、project connectionを使用します。Agentは未publishのproject Prompt Agentとして作成されます。

## 8. Grant End-user Access

```powershell
./scripts/grant-foundry-user.ps1 `
  -ConfirmAzureWrite `
  -PrincipalId <user-object-id>
```

通常利用者にはProject exact scopeの`Foundry User`を割り当てます。公式一般guidanceと実測差は[Foundry RBAC](foundry-rbac.md)を参照してください。

## 9. Verify Configuration

```powershell
./scripts/verify-deployment.ps1 `
  -RequireAgent `
  -RequireNoFunctionApiSecrets
```

Verifierはread-onlyで次を検証します。

- Web/Function UAMI attachmentとFIC
- 3 application separation
- Function `user_impersonation`とGraph delegated `User.Read`
- Function Easy Auth 2-client allowlist
- Function API secret 0件
- Dedicated OAuth client active credential
- OAuth connection target、scope、per-user setting
- Prompt Agent、connection、`get_my_profile` allowlist

## 10. End-to-end Validation

各ユーザーについてfresh InPrivate browser contextを作成します。同じcontext内でaccount switchしません。

1. Web Appを開いてsign-inする。
2. Profile summaryを要求する。
3. Foundry MCP consent linkのhostとconnectionを確認してconsentする。
4. `previous_response_id`を使うretry、または同じrequestを再送する。
5. Graph `User.Read` consent actionを開いてconsentする。
6. 同じrequestを再送し、profile summaryを確認する。
7. 2回目がconsentなしで成功することを確認する。
8. 別ユーザーを新しいInPrivate contextで検証し、identityが混在しないことを確認する。

Screenshot、trace、HAR、video、browser storage stateへtoken、UPN、object ID、session URL fragmentを保存しません。

## 11. Rotate OAuth Credentials

E2E成功後に古いOAuth client credentialを削除します。

```powershell
./scripts/remove-stale-oauth-secrets.ps1 `
  -ConfirmAzureWrite
```

常にactive credentialを1件以上残します。Function API applicationにはclient secretを作成しません。

## Cleanup

Azure resources、Prompt Agent、Foundry connection、tenant-scope Entra objectsは別のlifecycleを持ちます。検証値を失わないよう、`azd down`より前にcleanup scriptを実行します。

```powershell
./scripts/cleanup-validation-environment.ps1 `
  -ConfirmAzureWrite `
  -EnvironmentName <environment-name> `
  -SubscriptionId <subscription-id> `
  -TenantId <tenant-id> `
  -ResourceGroup <resource-group> `
  -RemoveAzdEnvironment
```

ScriptはAgent、connection、Azure resource group、3 application/service principal pairsの順に削除し、削除後の不存在を確認します。`azd down`後にoutputsが消えている場合は、environment固有の3つのexact display nameが各1件に解決できる場合だけEntra objectsを復元して削除します。曖昧または部分的な状態では削除しません。

同じcleanupを再実行しても、resource group、6 Entra objects、local azd environmentがすべて不存在ならwriteを行わず成功します。

残るInPrivate browser contextとtemporary denylistは別途破棄します。削除前に対象subscription、tenant、resource groupを確認してください。

## References

- [Azure Developer CLI](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/overview)
- [Microsoft Graph Bicep overview](https://learn.microsoft.com/graph/templates/bicep/overview-bicep-templates-for-graph)
- [Foundry MCP authentication](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/mcp-authentication)
