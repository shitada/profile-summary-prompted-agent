# Troubleshooting

## Diagnostic Order

問題を次のboundary順に切り分けます。

1. BrowserとWeb Easy Auth
2. Web BFFとFoundry Responses API
3. Foundry RBAC
4. MCP OAuth brokerとToken A issuance
5. Function Easy Auth
6. Function OBO
7. Microsoft Graph `/me`

Token、raw claims、consent URL、UPN、object IDを採取しません。UTC time、safe correlation ID、HTTP status、sanitized event codeだけを使用します。

## Symptom Matrix

| Symptom | Likely boundary | Check |
|---|---|---|
| Web POSTが403 | CORS / Easy Auth | Exact-origin CORS、credentials、same-origin header |
| `You do not have access to this agent` | Foundry RBAC | Signed-in account、tenant、Project `Foundry User`、fresh sign-in |
| Consent actionが出ない | Agent / connection | Promptがtoolを呼ぶか、OAuth connection、consent host allowlist |
| `AADSTS90009` | OAuth client/resource design | OAuth client IDとFunction API IDが別か |
| Token A sign-in successだがFunction telemetry 0 | Function Easy Auth | `allowedApplications`にdedicated OAuth clientがあるか |
| Graph consentを繰り返す | OBO / grant | `User.Read` grant、Function Easy Auth token store、Conditional Access |
| MCP consentを繰り返す | OAuth broker | `offline_access`、refresh URL、connection recreation、grant revocation |
| Function indexing missing | Functions metadata | `azure-functions` version、`mcp_tool_trigger` metadata、`host.json` |
| 別ユーザーのdata疑い | Browser isolation | Fresh context、displayed account、token-derived identity only |

## CORS and Easy Auth 403

Web App CORSは自身のHTTPS originだけを許可し、`supportCredentials=true`にします。Browser requestはsame-originで送信し、arbitrary Originやmissing OriginをBFFが拒否します。

Easy AuthがCSRFまたはorigin validationで拒否した場合、Flask routeへ到達しません。App Service authentication logとCORS configurationを先に確認します。

## Foundry RBAC 403

1. Browserに表示されたaccountが想定userか確認する。
2. Foundry projectと同じtenantであることを確認する。
3. Role assignment propagationを待つ。
4. Browser sessionを閉じ、新しいInPrivate contextでsign-inする。
5. Project exact scopeの`Foundry User`を確認する。

`Foundry Agent Consumer`の一般guidanceとこの経路の実測差は[Foundry RBAC](foundry-rbac.md)を参照してください。

## `AADSTS90009`

このerrorはapplicationが自分自身向けtokenを要求し、resourceがGUID-based application IDでない場合に発生します。

確認事項:

- Foundry MCP OAuth client applicationとFunction API applicationが別ID
- OAuth clientのrequired permissionがFunction `user_impersonation` 1件だけ
- Foundry connectionのclient IDがdedicated OAuth client
- Function API applicationにlegacy OAuth client secretが残っていない

OAuth client/API分離後は既存ユーザーに1回だけ新しいMCP consentが必要です。

## Token A Issued but Function Is Not Reached

Entra sign-inがsuccessでも、Function Easy Authがcaller applicationを拒否できます。

Function `authsettingsV2`の`defaultAuthorizationPolicy.allowedApplications`は次の2件だけにします。

1. Function API application
2. Dedicated MCP OAuth client application

Audience、issuer、scopeが正しくても、Token Aの`azp`または`appid`がallowlist外ならruntimeへ到達しません。

## Graph Consent Required

Function OBOがinteraction requiredを返した場合、Functionはsafe `graph_consent_required` actionを返します。UserがFunction Easy Auth routeでdelegated `User.Read`へconsentし、同じprofile requestを再送します。

次を行いません。

- Graph application permission追加
- `User.Read.All`や`Directory.Read.All`への昇格
- Token AのGraphへのforward
- Static admin consent URLのapplication log保存

## Repeated MCP Consent

Foundry custom OAuth connectionにはFunction scope、`offline_access`、token URLと同じrefresh URLを設定します。それでも再同意が必要な場合は次を確認します。

- Userまたはadministratorによるgrant revocation
- Connectionの削除、再作成、改名
- OAuth client ID変更
- Refresh token invalidation
- Conditional Access reauthentication
- OAuth client secret expiration

最初のtool error後、同じrequestを1回再送すると新しい`oauth_consent_request`へ進む場合があります。古いconsent linkをbookmarkやticketから再利用しません。

## Function MCP Indexing

```powershell
./.venv/Scripts/python ./scripts/validate-function-metadata.py
```

期待するfunctionsは次の2件です。

- `get_my_profile`: `mcpToolTrigger`
- `consent_complete`: `httpTrigger` + `http`

Functions MCPはStreamable HTTP endpoint `/runtime/webhooks/mcp`を使用します。`host.json`はv4 extension bundleを参照し、Easy Authを使うためwebhook authorization levelをanonymousにします。

## CAE and Administrative Checks

Cached Graph bearer tokenを直接replayすると、Conditional Access Evaluationによりoutdated policy tokenとして拒否されることがあります。Application/service principal/FICの確認は`az ad app`、`az ad sp`、`az ad app federated-credential`を優先し、CLIのauthentication refreshへ委ねます。

## Safe Evidence

Supportまたはinternal investigationへ提供する値:

- UTC occurrence window
- Azure resource typeとgeneric component role
- HTTP statusとsafe error code
- Sanitized correlation ID
- OAuth connection auth type、scope names、refresh URL presence
- Whether a second call succeeded

提供しない値:

- Token、secret、authorization header
- Consent URL
- UPN、mail、object ID
- Raw Graph payload、raw Entra error body
- Tenant、subscription、application IDを含む未加工bundle

## References

- [Foundry MCP authentication troubleshooting](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/mcp-authentication)
- [App Service MCP authorization](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-mcp)
- [Functions MCP bindings](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-mcp)
