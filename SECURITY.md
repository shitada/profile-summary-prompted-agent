# Security Policy

## Reporting a Vulnerability

Security issueはpublic GitHub Issueへ投稿しないでください。Repository ownerへprivate channelで連絡し、影響するcomponent、再現条件、safe correlation informationだけを共有してください。

次をreportへ含めないでください。

- Password、access token、refresh token、client secret、authorization header
- Consent URL、callback state、session fragment
- Tenant、subscription、application、object ID
- UPN、mail、person、customer、resource name
- Raw Graph response、raw claims、unredacted screenshot

Ownerは受領後、再現可否、影響範囲、修正方針、公開可否をprivateに確認します。修正が公開されるまでtechnical detailをdiscloseしないでください。

## Supported Versions

このrepositoryはpublic release前のprivate sampleです。Current default branchだけをsecurity review対象とします。Production supportやSLAは提供しません。

## Security Boundaries

- User identityはdelegated tokenで維持する
- Graphはdelegated `User.Read`と`GET /me`だけ
- Browserへservice tokenを返さない
- Function APIとOAuth clientを分離する
- Web/Function workload credentialはUAMI + FIC
- OAuth client secretは短期rotationする

詳細は[Security and privacy](docs/security-and-privacy.md)を参照してください。
