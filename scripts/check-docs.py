#!/usr/bin/env python3

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
DOCUMENTS = [
    ROOT / "README.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / "CLAUDE.md",
    ROOT / "docs/index.html",
]
GENERATED_ASSETS = [
    ROOT / "docs/icon-256.png",
    ROOT / "docs/screenshots/menubar-dark.png",
    ROOT / "docs/screenshots/menubar-light.png",
    ROOT / "docs/screenshots/popover-auto-dark.png",
    ROOT / "docs/screenshots/popover-auto-light.png",
    ROOT / "docs/screenshots/popover-curve-dark.png",
    ROOT / "docs/screenshots/popover-curve-light.png",
    ROOT / "docs/screenshots/reel-dark.mp4",
    ROOT / "docs/screenshots/reel-dark.png",
    ROOT / "docs/screenshots/reel-light.mp4",
    ROOT / "docs/screenshots/reel-light.png",
]

MARKDOWN_LINK = re.compile(r"!?\[[^\]]*]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HTML_LINK = re.compile(r"\b(?:href|src|srcset)=\"([^\"]+)\"")
HTML_ID = re.compile(r"\bid=\"([^\"]+)\"")


def local_target(document: Path, raw_target: str) -> tuple[Path | None, str]:
    parsed = urlsplit(raw_target)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme not in {"http", "https", "mailto"}:
            raise ValueError(f"unsupported URL scheme in {raw_target}")
        return None, ""

    if not parsed.path:
        return document, unquote(parsed.fragment)

    target = (document.parent / unquote(parsed.path)).resolve()
    try:
        target.relative_to(ROOT)
    except ValueError as error:
        raise ValueError(f"target escapes repository: {raw_target}") from error
    return target, unquote(parsed.fragment)


def check_target(document: Path, raw_target: str, failures: list[str]) -> int:
    try:
        target, fragment = local_target(document, raw_target)
    except ValueError as error:
        failures.append(f"{document.relative_to(ROOT)}: {error}")
        return 0

    if target is None:
        return 0
    if not target.exists():
        failures.append(
            f"{document.relative_to(ROOT)}: missing target {raw_target}"
        )
        return 0
    if target.is_file() and target.stat().st_size == 0:
        failures.append(
            f"{document.relative_to(ROOT)}: empty target {raw_target}"
        )
        return 0
    if fragment and target.suffix == ".html":
        ids = set(HTML_ID.findall(target.read_text(encoding="utf-8")))
        if fragment not in ids:
            failures.append(
                f"{document.relative_to(ROOT)}: missing anchor {raw_target}"
            )
    return 1


def main() -> int:
    failures: list[str] = []
    checked = 0

    for document in DOCUMENTS:
        if not document.is_file():
            failures.append(f"missing document {document.relative_to(ROOT)}")
            continue
        text = document.read_text(encoding="utf-8")
        targets = MARKDOWN_LINK.findall(text)
        targets.extend(HTML_LINK.findall(text))
        for target in targets:
            checked += check_target(document, target, failures)

    for asset in GENERATED_ASSETS:
        if not asset.is_file() or asset.stat().st_size == 0:
            failures.append(f"missing or empty generated asset {asset.relative_to(ROOT)}")
        else:
            checked += 1

    if failures:
        for failure in failures:
            print(f"docs check failed: {failure}", file=sys.stderr)
        return 1

    print(f"docs check passed ({checked} local links and assets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
