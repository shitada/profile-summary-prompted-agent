# Foundry RBAC

## Scope

この文書は、delegated user tokenでFoundry projectのResponses APIを呼び、`agent_reference`、project connection、custom OAuth identity passthroughを使用する経路のRBACを扱います。Published Agent Applicationは異なるpermission pathを使用するため対象外です。

## Official Guidance

Microsoft Foundryの一般RBAC guidanceでは、Agent endpointと対話するだけのconsumerには`Foundry Agent Consumer`がleast-privilege roleです。MCP OAuth identity passthroughの公式資料もProject scopeの同roleを推奨し、`Foundry User`はAgent開発者向けの広いroleと位置付けています。

一方、同じMCP authentication資料のtroubleshootingは、consent後もtool callが失敗する場合にunderlying service accessとProject scopeの`Foundry User`以上を確認するよう案内しています。

## Observed Behavior

独立した複数ユーザーをfresh browser contextで検証した結果は次のとおりでした。

| Assignment | Scope | Result |
|---|---|---|
| `Foundry Agent Consumer` | Agent | HTTP 403 |
| `Foundry Agent Consumer` | Project | HTTP 403 |
| `Foundry User` | Project | 403を通過し、MCP OAuth consentへ進行 |
| `Foundry User` + per-user consent | Project / user | Function MCP、OBO、Graph `/me`まで成功 |

正確に不足したdata actionはpublic responseから特定できません。Conversationまたはagent stateに関するwrite actionが評価された可能性はありますが、推定として扱います。

## Repository Default

このsampleでは、再現性を優先して通常利用者へProject exact scopeの`Foundry User`を付与します。

```powershell
./scripts/grant-foundry-user.ps1 `
  -ConfirmAzureWrite `
  -PrincipalId <user-object-id>
```

これは公式一般guidanceより広いcompatibility workaroundです。Owner、Contributor、Foundry Project Managerは通常利用者へ付与しません。

## Least-privilege Revalidation

Service behaviorまたはdocumentationが更新された場合、次のA/B testを別のtest userで実施します。

1. Project `Foundry User`を削除する。
2. ProjectまたはAgent scopeへ`Foundry Agent Consumer`だけを付与する。
3. Role propagation後、fresh browser contextでsign-inする。
4. 新しいresponseからAgentを呼び出す。
5. MCP consent、Function call、Graph `/me`まで確認する。
6. Agent authoring、connection変更など不要な操作が拒否されることを確認する。

成功した場合はsample既定roleをConsumerへ戻します。失敗した場合はtimestamp、scope、HTTP status、sanitized correlationだけを採取し、Azure Supportへ最小data actionを問い合わせます。

## Published Agent Applications

Agent Applicationはproject Agent endpointと異なる`applications/invoke/action`を使用します。公式資料ではAgent Applicationを呼び出すにはApplication scopeの`Foundry User`または同actionを持つcustom roleが必要で、`Foundry Agent Consumer`では不足すると明記されています。

このsampleはProject Responses APIを使用し、Agent Applicationをpublishしません。両経路のRBAC結果を混同しないでください。

## Open Questions

- Project Responses API、`agent_reference`、project connection、OAuth passthroughを組み合わせた最小data actions
- Consumer-only 403が仕様、service ring差、またはdefectか
- Conversation state作成にwrite actionが必要か
- Consumer向け公式custom role pattern

## References

- [Role-based access control for Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry)
- [Foundry MCP authentication](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/mcp-authentication)
- [Agent applications in Microsoft Foundry](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/agent-applications)
