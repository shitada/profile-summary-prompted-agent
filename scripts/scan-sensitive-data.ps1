[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$DenylistPath = $env:SENSITIVE_TERMS_FILE,
    [switch]$RequireDenylist
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$excludedDirectories = @('.git', '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache')
$textExtensions = @('.py', '.ps1', '.md', '.bicep', '.json', '.yaml', '.yml', '.html', '.css', '.js', '.svg', '.txt')
$textFileNames = @('.gitignore', '.gitattributes')
$publicGuidAllowlist = @(
    '00000003-0000-0000-c000-000000000000',
    'e1fe6dd8-ba31-4d61-89e7-88639da4683d',
    'b7e6dc6d-f1e8-4753-8033-0f276bb0955b',
    '974c5e8b-45b9-4653-ba55-5f855dd0fb88',
    '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3',
    '3913510d-42f4-4e42-8a64-420c390055eb',
    'eadc314b-1a2d-4efa-be10-5d325db5065e',
    '53ca6127-db72-4b80-b1b0-d745d6d5456d'
)

if ($RequireDenylist -and [string]::IsNullOrWhiteSpace($DenylistPath)) {
    throw 'SENSITIVE_TERMS_FILE is required for a release scan.'
}
if (-not [string]::IsNullOrWhiteSpace($DenylistPath) -and -not (Test-Path -LiteralPath $DenylistPath -PathType Leaf)) {
    throw 'The sensitive terms file does not exist.'
}

$denylist = @()
if (-not [string]::IsNullOrWhiteSpace($DenylistPath)) {
    $denylist = @(
        Get-Content -LiteralPath $DenylistPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

$patterns = [ordered]@{
    EmailAddress = '(?i)(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}(?![A-Z0-9.-])'
    TenantDomain = '(?i)\b[A-Z0-9.-]+\.onmicrosoft\.com\b'
    SubscriptionPath = '(?i)/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    LocalUserPath = '(?i)\b[A-Z]:\\Users\\[^\\\s]+'
    SourceProjectPath = '(?i)external[\\/]([^\r\n]+[\\/])?prompted_agent_test'
    PrivateKey = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
    Jwt = '(?i)\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b'
}
$guidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
$syntheticGuidPattern = '^00000000-0000-4000-8000-00000000000[1-3]$'

$files = Get-ChildItem -LiteralPath $RootPath -File -Recurse -Force | Where-Object {
    $relative = $_.FullName.Substring($RootPath.Length).TrimStart('\', '/')
    $segments = $relative -split '[\\/]'
    $isAzdLocalState = $segments[0] -eq '.azure' -and $relative -notmatch '^\.azure[\\/]deployment-plan\.md$'
    -not ($segments | Where-Object { $excludedDirectories -contains $_ }) -and
    -not $isAzdLocalState -and
    (($textExtensions -contains $_.Extension.ToLowerInvariant()) -or ($textFileNames -contains $_.Name))
}

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($RootPath.Length + 1).Replace('\', '/')
    $content = Get-Content -LiteralPath $file.FullName -Raw

    foreach ($entry in $patterns.GetEnumerator()) {
        foreach ($match in [regex]::Matches($content, $entry.Value)) {
            $findings.Add([pscustomobject]@{ File = $relativePath; Rule = $entry.Key; Value = $match.Value })
        }
    }

    foreach ($match in [regex]::Matches($content, $guidPattern)) {
        $normalizedGuid = $match.Value.ToLowerInvariant()
        if (
            $publicGuidAllowlist -notcontains $normalizedGuid -and
            $normalizedGuid -notmatch $syntheticGuidPattern
        ) {
            $findings.Add([pscustomobject]@{ File = $relativePath; Rule = 'UnreviewedGuid'; Value = $match.Value })
        }
    }

    foreach ($term in $denylist) {
        $isShortAlias = $term.Length -le 4 -and $term -match '^[A-Za-z0-9]+$'
        $matched = if ($isShortAlias) {
            $escapedTerm = [regex]::Escape($term)
            [regex]::IsMatch(
                $content,
                "(?i)(?<![A-Za-z0-9])$escapedTerm(?![A-Za-z0-9])"
            )
        }
        else {
            $content.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        if ($matched) {
            $findings.Add([pscustomobject]@{ File = $relativePath; Rule = 'ExternalDenylist'; Value = '[redacted]' })
        }
    }
}

if ($findings.Count -gt 0) {
    $findings | Select-Object File, Rule, Value | Format-Table -AutoSize | Out-String | Write-Error
    throw "Sensitive-data scan found $($findings.Count) finding(s)."
}

[pscustomobject]@{
    Status = 'passed'
    FilesScanned = $files.Count
    ExternalDenylistTerms = $denylist.Count
} | ConvertTo-Json -Compress
