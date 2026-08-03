# Public Release Checklist

Private repositoryをsanitizationの代替として扱いません。Public visibilityへの変更はinitial private pushとは別の承認ゲートです。

## Source and History

- [x] Original source treeのbefore/after SHA-256 manifestが一致
- [x] Original Git historyをimportしていない
- [x] Repository historyがsanitized initial commitから開始
- [x] Branches、tags、stashes、reflogへ削除前の機微情報がない
- [x] Fresh cloneで同じscan結果になる

## Text and Binary Scan

- [x] External denylistを指定した`validate-local.ps1 -RequireDenylist`がpass
- [x] Email、tenant domain、subscription path、real Azure host、unreviewed GUIDが0
- [x] Gitleaks directory scanがpass
- [x] Gitleaks Git history scanがpass
- [ ] Binary file allowlistを人間が確認
- [x] ZIP、trace、HAR、video、browser storage stateがない

## Screenshots

- [x] Original imageを変更せずsanitized copyだけを含める
- [x] UPN、mail、person、customer、tenant、resource、URL、IDを余白込みでmask
- [x] EXIF、XMP、PNG text chunksを除去
- [x] OCR scanでsensitive term 0
- [x] `view_image`でmask edgeとcontextを目視確認
- [ ] Microsoft UI/brand screenshotの公開権利を確認
- [ ] 権利を確認できない画像は削除し、Mermaidへ置換

## Code and Infrastructure

- [x] 45 unit testsがpass
- [x] Function metadataにMCP toolとconsent routeが存在
- [x] PowerShell parserがpass
- [x] Bicep build/lintがpass
- [x] ARM validationとwhat-ifをreview
- [x] Provisioning what-ifのDelete operationが0
- [x] Function API application secret 0
- [x] OAuth clientとFunction APIが別application
- [x] Function Easy Auth caller allowlistが2件だけ

## Clean Azure Reproduction

- [x] Customerまたは既存production resourcesと分離した専用validation環境を使用
- [x] Greenfield preflight、provision、deployが成功
- [x] OAuth connectionとPrompt Agentをrepository scriptsだけで作成
- [x] Fresh InPrivateで初回MCP consentを確認
- [x] Fresh InPrivateでGraph consentと`/me`成功を確認
- [x] 2回目がnon-interactiveに成功
- [x] 別userを別contextで検証し、identity isolationを確認
- [x] `AADSTS90009`なし
- [x] Strict verifierがpass
- [x] Azure resourcesとtenant-scope Entra objectsをcleanup

## GitHub

- [x] Repository visibilityがPRIVATEであることをpush前に確認
- [x] Commit emailがGitHub noreply address
- [x] Actionsはcredential-free CIだけ
- [ ] Actions logs、workflow history、artifactsに機微情報なし
- [x] Dependabot設定とworkflow permissionsを自動検証
- [ ] Branch rulesetまたはprotectionを利用可能なplanで設定（現在のprivate repository planではAPI利用不可）
- [ ] Public化直前にfresh cloneと全historyを再scan

Privateからpublicへ変更するとActions historyとlogsもpublicになります。過去のworkflow runを含めて確認します。

## Rights and License

- [ ] Organizational/IP/legal approval
- [ ] Customerまたは第三者confidential informationがない
- [ ] Microsoft/customer brandingとscreenshot rightsを確認
- [x] Dependency license metadata inventoryを生成（法的評価は未実施）
- [ ] MIT採用を承認後に`LICENSE`を追加
- [ ] Public化前にprivate vulnerability reportingを有効化し、`SECURITY.md`の外部reporting pathを確認

## Release Decision

次のすべてが揃うまでvisibilityを変更しません。

1. Clean Azure E2Eとcleanup
2. Text、binary、history、image scan 0 findings
3. Rights/license approval
4. Human review of final commit and GitHub history
5. Explicit public-release approval

## Automated Evidence

- Local strict validation: 45 tests、2 Function bindings、11 Markdown files、11 Mermaid diagrams、59 text files、10 external denylist terms、3 OCR-scanned images。
- Fresh clone: 45 tests、3 bindings、11 Markdown files、11 Mermaid diagrams、60 text files、3 images、dependency vulnerabilities 0、directory/history secret findings 0、Git status clean。
- Git: sanitized root 1件、local branch 1件、tags/stashes 0件、reflogのunreachable commit 0件。
- GitHub: private visibility、credential-free CI success、Git-history secret scan success。Ruleset/branch protection APIは現在のplanで利用不可。
- Azure E2E: 初回consent、Graph `/me`、non-interactive repeat、別InPrivate userを確認。Telemetryはhashed distinct users 2名、success events 5件。
- Cleanup: Agent、connection、dedicated resource group、6 Entra objects、local azd environmentの不存在を確認。
- Dependency metadata: 111 packages、license metadata unknown 0件。License compatibilityと再配布可否は人間が判断する。

## Reference

- [GitHub repository visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)
