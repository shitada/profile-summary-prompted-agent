from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw


IMAGE_RULES = {
    "step-01-foundry-oauth-consent.png": {
        "output": "mcp-connection-consent.png",
        "crop": (0, 84, 1260, 914),
        "redactions": (),
    },
    "step-02-graph-consent-required.png": {
        "output": "graph-consent-required.png",
        "crop": (36, 15, 996, 875),
        "redactions": (),
    },
    "step-03-profile-summary-success.png": {
        "output": "profile-summary-success.png",
        "crop": (208, 63, 1168, 923),
        "redactions": ((0, 73, 960, 116, (255, 255, 255)),),
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create metadata-free, cropped copies of approved authentication screenshots."
    )
    parser.add_argument("source", type=Path, help="Directory containing the approved source images")
    parser.add_argument("destination", type=Path, help="Destination directory for sanitized images")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitize(source: Path, destination: Path, rule: dict[str, object]) -> dict[str, object]:
    with Image.open(source) as opened:
        opened.load()
        image = opened.convert("RGB").crop(rule["crop"])

    draw = ImageDraw.Draw(image)
    for left, top, right, bottom, color in rule["redactions"]:
        draw.rectangle((left, top, right, bottom), fill=color)

    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, format="PNG", optimize=True, compress_level=9)

    with Image.open(destination) as verified:
        verified.load()
        if verified.info or verified.text:
            raise RuntimeError(f"Unexpected metadata remains in {destination.name}")
        size = list(verified.size)
        mode = verified.mode

    return {
        "name": destination.name,
        "size": size,
        "mode": mode,
        "metadataKeys": [],
        "sha256": sha256(destination),
    }


def main() -> None:
    args = parse_args()
    manifest = []

    for source_name, rule in IMAGE_RULES.items():
        source = args.source / source_name
        if not source.is_file():
            raise FileNotFoundError(f"Approved source image is missing: {source_name}")
        destination = args.destination / str(rule["output"])
        manifest.append(sanitize(source, destination, rule))

    print(json.dumps({"status": "passed", "images": manifest}, separators=(",", ":")))


if __name__ == "__main__":
    main()
