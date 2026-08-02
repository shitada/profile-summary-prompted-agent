# Public Release Checklist

Private repositoryをsanitizationの代替として扱いません。Public visibilityへの変更はinitial private pushとは別の承認ゲートです。

## Source and History

- [ ] Original source treeのbefore/after SHA-256 manifestが一致
- [ ] Original Git historyをimportしていない
- [ ] Repository historyがsanitized initial commitから開始
- [ ] Branches、tags、stashes、reflogへ削除前の機微情報がない
- [ ] Fresh cloneで同じscan結果になる

## Text and Binary Scan

- [ ] External denylistを指定した`validate-local.ps1 -RequireDenylist`がpass
- [ ] Email、tenant domain、subscription path、real Azure host、unreviewed GUIDが0
- [ ] Gitleaks directory scanがpass
- [ ] Gitleaks Git history scanがpass
- [ ] Binary file allowlistを人間が確認
- [ ] ZIP、trace、HAR、video、browser storage stateがない

## Screenshots

- [ ] Original imageを変更せずsanitized copyだけを含める
- [ ] UPN、mail、person、customer、tenant、resource、URL、IDを余白込みでmask
- [ ] EXIF、XMP、PNG text chunksを除去
- [ ] OCR scanでsensitive term 0
- [ ] `view_image`でmask edgeとcontextを目視確認
- [ ] Microsoft UI/brand screenshotの公開権利を確認
- [ ] 権利を確認できない画像は削除し、Mermaidへ置換

## Code and Infrastructure

- [ ] 45 unit testsがpass
- [ ] Function metadataにMCP toolとconsent routeが存在
- [ ] PowerShell parserがpass
- [ ] Bicep build/lintがpass
- [ ] ARM validationとwhat-ifをreview
- [ ] Delete operation 0、または意図したdeleteだけを人間が承認
- [ ] Function API application secret 0
- [ ] OAuth clientとFunction APIが別application
- [ ] Function Easy Auth caller allowlistが2件だけ

## Clean Azure Reproduction

- [ ] Customerまたは既存production環境と別のsubscription/tenantを使用
- [ ] Greenfield preflight、provision、deployが成功
- [ ] OAuth connectionとPrompt Agentをrepository scriptsだけで作成
- [ ] Fresh InPrivateで初回MCP consentを確認
- [ ] Fresh InPrivateでGraph consentと`/me`成功を確認
- [ ] 2回目がnon-interactiveに成功
- [ ] 別userを別contextで検証し、identity isolationを確認
- [ ] `AADSTS90009`なし
- [ ] Strict verifierがpass
- [ ] Azure resourcesとtenant-scope Entra objectsをcleanup

## GitHub

- [ ] Repository visibilityがPRIVATEであることをpush前に確認
- [ ] Commit emailがGitHub noreply address
- [ ] Actionsはcredential-free CIだけ
- [ ] Actions logs、workflow history、artifactsに機微情報なし
- [ ] Dependabot設定とworkflow permissionsをreview
- [ ] Branch rulesetまたはprotectionを利用可能なplanで設定
- [ ] Public化直前にfresh cloneと全historyを再scan

Privateからpublicへ変更するとActions historyとlogsもpublicになります。過去のworkflow runを含めて確認します。

## Rights and License

- [ ] Organizational/IP/legal approval
- [ ] Customerまたは第三者confidential informationがない
- [ ] Microsoft/customer brandingとscreenshot rightsを確認
- [ ] Dependency license inventoryを確認
- [ ] MIT採用を承認後に`LICENSE`を追加
- [ ] `SECURITY.md`のreporting pathが有効

## Release Decision

次のすべてが揃うまでvisibilityを変更しません。

1. Clean Azure E2Eとcleanup
2. Text、binary、history、image scan 0 findings
3. Rights/license approval
4. Human review of final commit and GitHub history
5. Explicit public-release approval

## Reference

- [GitHub repository visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)
