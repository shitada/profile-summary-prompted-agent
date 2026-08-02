# Deployment Plan

## Status

Validated

## Approval

- 2026-08-02: Automated release gates, private GitHub repository creation and push, clean Azure validation, end-to-end testing, and cleanup are approved.
- Final human review remains the last gate.
- Public visibility and license publication are not approved by this plan.

## Goal

App Service から Microsoft Foundry Prompt Agent と Azure Functions MCP を経由し、サインインユーザーの委任権限で Microsoft Graph `/me` を呼び出す再現可能なサンプルを構築する。

## Scope

- Python 3.13 / Flask Web application on Azure App Service
- Microsoft Foundry project, model deployment, and Prompt Agent
- Python 3.13 Azure Functions MCP server
- Microsoft Entra ID delegated authentication and On-Behalf-Of flow
- Microsoft Graph delegated `User.Read`
- Azure Developer CLI and Bicepによるgreenfield deployment
- 日本語の技術文書、ローカル検証、機密情報scan

Teams、Bot Service、production private networking、GitHub ActionsからのAzure deploymentは対象外とする。

## Architecture

1. BrowserはApp Service Easy Authでサインインする。
2. FlaskはEasy AuthからFoundry向けdelegated access tokenを受け取る。
3. FlaskはResponses APIとPrompt Agentを呼び出す。
4. Prompt Agentは専用OAuth clientを使ってAzure Functions MCPへToken Aを渡す。
5. Function Easy AuthはToken Aのaudienceとcaller applicationを検証する。
6. FunctionはToken AをOn-Behalf-Of flowでMicrosoft Graph向けToken Bへ交換する。
7. Functionは`GET /me`を呼び、安全なfield allowlistだけをMCP responseへ返す。

## Identity Design

- Web application registration: Foundry delegated permissionのみ
- Function API registration: `user_impersonation` scopeを公開し、Graph delegated `User.Read`を要求
- MCP OAuth client registration: Function `user_impersonation`だけを要求
- WebとFunctionのconfidential-client authentication: User-assigned managed identityとfederated identity credential
- MCP OAuth client: 短期client secret。値はsource、log、command outputへ保存しない
- Function Easy Auth caller allowlist: Function API applicationとMCP OAuth client applicationの2件
- Graph application permissionは使用しない

## Infrastructure

- Resource group
- Microsoft Foundry account, project, and model deployment
- Azure Functions Flex Consumption app, storage account, and managed identity
- Azure App Service Linux plan, Web app, and managed identity
- Log Analytics workspace and Application Insights
- Three Microsoft Entra application registrations and service principals
- Required federated identity credentials, RBAC, Easy Auth, and CORS settings

Locations、model、model version、capacity、Web App SKU、resource naming tokenはparametersとする。

## Implementation Phases

1. Create a clean repository skeleton and source-integrity manifest.
2. Port and generalize the Web, Function, and unit tests through an explicit allowlist.
3. Replace environment-specific incremental IaC with greenfield Bicep modules.
4. Generalize setup, validation, verification, and sensitive-data scan scripts.
5. Rewrite README and detailed documentation without operational identifiers.
6. Re-encode and validate only approved screenshots.
7. Run local tests, parsers, Bicep validation, dependency checks, and secret scans.
8. Set status to `Ready for Validation` and run the Azure validation workflow.
9. After human review, initialize fresh Git history and create a private GitHub repository.

## Security Gates

- Existing implementation remains read-only; verify its file hashes before and after work.
- Do not copy environment files, diagnostics, browser state, logs, archives, or Git history.
- Do not store tenant domains, UPNs, resource identifiers, tokens, secrets, or consent URLs.
- Run explicit denylist scanning and Gitleaks before and after Git initialization.
- Re-encode screenshots, remove metadata, run OCR checks, and inspect them visually.
- Use credential-free CI only; live Azure validation runs locally after explicit Azure-context confirmation.
- Repository visibility remains private until a separate public-release review is approved.

## Validation

- Python unit tests
- Azure Functions indexing
- Flask route smoke tests
- PowerShell parser checks
- Bicep build and lint
- Azure Developer CLI configuration validation
- Sensitive-data, binary allowlist, image metadata, OCR, and Gitleaks scans
- Azure preflight, template validation, and what-if with no unexpected deletes
- Greenfield deployment and end-to-end delegated identity validation in a clean environment
- Cleanup verification

## Validation Proof

Validated on 2026-08-02 before provisioning:

- `validate-local.ps1 -RequireDenylist`: passed with 45 unit tests, two Function bindings, 11 Markdown files, 11 Mermaid diagrams, PowerShell parsing, Bicep build, 59 text files, 10 external denylist terms, and three OCR-scanned images.
- `mcp_azure_mcp_ser_azd validate_azure_yaml`: passed against the stable `azure.yaml` schema.
- `az bicep build`: passed with Bicep CLI 0.46.1. Foundry resource API version `2026-05-01` was confirmed as the current stable version in Microsoft Learn.
- Source integrity: all 100 source files matched the pre-work SHA-256 manifest.
- Secret scanning: Gitleaks directory scan and one-commit Git history scan both reported zero leaks.
- Dependency audit: no known vulnerabilities were found.
- Binary allowlist: three sanitized PNG files and zero unexpected binary files.
- Azure preflight: all eight checks passed for registered providers, role-assignment capability, Functions Flex Consumption, App Service, Python 3.13, model availability, model quota, and the Foundry delegated scope.
- Model validation: `gpt-5-mini` version `2025-08-07` supports the Responses API and sufficient deployment capacity was available in the selected primary region.
- ARM validation: subscription-scope template validation passed.
- ARM what-if: 27 planned changes and zero deletes with the Web App in the separately validated web region.
- `azd provision --preview --no-prompt`: passed and listed only new resources in the dedicated validation resource group.
- Static identity and RBAC verification: three separate Entra applications, two managed-identity federated credentials, delegated Graph `User.Read`, Function `user_impersonation`, exactly two Function Easy Auth callers, storage data roles, monitoring publisher roles, and project-scoped Foundry roles were present.

The primary and web regions are intentionally parameterized. The validation subscription had zero App Service worker quota in the primary region, so the preview used a separate web region with available B1 quota. No Azure resources were created during validation.

## Deployment Approval

This plan authorizes automated local validation, private GitHub repository creation and push, clean Azure deployment validation, end-to-end testing, and cleanup. Public visibility, license publication, and final release still require separate human approval.