from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import unquote, urlsplit


REPO_ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_PARTS = {".git", ".venv", "__pycache__"}
LINK_PATTERN = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
FENCE_PATTERN = re.compile(r"^```([^\s`]*)\s*$")
MERMAID_START = {"flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram", "erDiagram", "journey", "gantt", "pie", "mindmap", "timeline", "gitGraph", "quadrantChart", "xychart-beta", "block-beta", "packet-beta", "architecture-beta", "kanban"}


def markdown_files() -> list[Path]:
    return sorted(
        path
        for path in REPO_ROOT.rglob("*.md")
        if not EXCLUDED_PARTS.intersection(path.relative_to(REPO_ROOT).parts)
    )


def link_target(raw_target: str) -> str:
    target = raw_target.strip()
    if target.startswith("<") and ">" in target:
        return target[1 : target.index(">")]
    return target.split(maxsplit=1)[0]


def validate_links(path: Path, content: str) -> list[str]:
    findings: list[str] = []
    for match in LINK_PATTERN.finditer(content):
        target = link_target(match.group(1))
        parsed = urlsplit(target)
        if parsed.scheme in {"http", "https", "mailto"} or target.startswith("#"):
            continue
        relative_target = unquote(parsed.path).replace("/", str(Path("/").anchor or "/"))
        candidate = (path.parent / relative_target).resolve()
        try:
            candidate.relative_to(REPO_ROOT)
        except ValueError:
            findings.append(f"{path.relative_to(REPO_ROOT)}: link escapes repository: {target}")
            continue
        if not candidate.exists():
            findings.append(f"{path.relative_to(REPO_ROOT)}: missing target: {target}")
    return findings


def validate_mermaid(path: Path, content: str) -> tuple[int, list[str]]:
    findings: list[str] = []
    mermaid_count = 0
    active_language: str | None = None
    block_lines: list[str] = []

    for line_number, line in enumerate(content.splitlines(), start=1):
        fence = FENCE_PATTERN.match(line.strip())
        if not fence:
            if active_language is not None:
                block_lines.append(line)
            continue

        language = fence.group(1)
        if active_language is None:
            active_language = language
            block_lines = []
            continue

        if language:
            findings.append(f"{path.relative_to(REPO_ROOT)}:{line_number}: nested code fence")
            continue

        if active_language == "mermaid":
            mermaid_count += 1
            first_line = next((item.strip() for item in block_lines if item.strip()), "")
            keyword = first_line.split(maxsplit=1)[0] if first_line else ""
            if keyword not in MERMAID_START:
                findings.append(
                    f"{path.relative_to(REPO_ROOT)}:{line_number}: unsupported or empty Mermaid diagram"
                )
        active_language = None
        block_lines = []

    if active_language is not None:
        findings.append(f"{path.relative_to(REPO_ROOT)}: unclosed code fence")
    return mermaid_count, findings


def main() -> None:
    findings: list[str] = []
    diagrams = 0
    files = markdown_files()
    for path in files:
        content = path.read_text(encoding="utf-8")
        findings.extend(validate_links(path, content))
        count, mermaid_findings = validate_mermaid(path, content)
        diagrams += count
        findings.extend(mermaid_findings)

    if findings:
        raise SystemExit("\n".join(findings))

    print(
        '{"status":"passed","markdownFiles":%d,"mermaidDiagrams":%d}'
        % (len(files), diagrams)
    )


if __name__ == "__main__":
    main()
