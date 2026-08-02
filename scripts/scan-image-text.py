from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path

from rapidocr import RapidOCR


PATTERNS = {
    "email": re.compile(r"(?i)(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"),
    "tenant-domain": re.compile(r"(?i)\b[A-Z0-9.-]+\.onmicrosoft\.com\b"),
    "guid": re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"),
    "subscription-path": re.compile(r"(?i)/subscriptions/[0-9a-f-]{36}"),
    "azure-host": re.compile(r"(?i)\b[A-Z0-9-]+\.(?:azurewebsites\.net|services\.ai\.azure\.com)\b"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Scan OCR text without printing recognized text.")
    parser.add_argument("directory", type=Path)
    parser.add_argument("--denylist", type=Path)
    parser.add_argument("--require-denylist", action="store_true")
    return parser.parse_args()


def load_denylist(path: Path | None, required: bool) -> list[str]:
    if path is None:
        environment_path = os.environ.get("SENSITIVE_TERMS_FILE", "").strip()
        path = Path(environment_path) if environment_path else None
    if required and path is None:
        raise RuntimeError("SENSITIVE_TERMS_FILE or --denylist is required for release OCR scan.")
    if path is None:
        return []
    if not path.is_file():
        raise FileNotFoundError("The OCR denylist file does not exist.")
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def extract_text(result: object) -> str:
    if result is None:
        return ""
    if hasattr(result, "txts"):
        return "\n".join(str(text) for text in (result.txts or []))
    if isinstance(result, tuple) and result:
        rows = result[0] or []
        return "\n".join(str(row[1]) for row in rows if len(row) > 1)
    return ""


def main() -> None:
    args = parse_args()
    denylist = load_denylist(args.denylist, args.require_denylist)
    engine = RapidOCR()
    findings: list[dict[str, str]] = []
    images = sorted(args.directory.glob("*.png"))

    for image in images:
        result = engine(str(image))
        text = extract_text(result)
        for rule, pattern in PATTERNS.items():
            if pattern.search(text):
                findings.append({"file": image.name, "rule": rule})
        lower_text = text.casefold()
        for term in denylist:
            if term.casefold() in lower_text:
                findings.append({"file": image.name, "rule": "external-denylist"})

    summary = {
        "status": "passed" if not findings else "failed",
        "imagesScanned": len(images),
        "externalDenylistTerms": len(denylist),
        "findingCount": len(findings),
        "findings": findings,
        "recognizedTextPrinted": False,
    }
    print(json.dumps(summary, separators=(",", ":")))
    if findings:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
