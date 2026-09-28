#!/usr/bin/env python3
"""The release gate: prove core/ is publishable.

Core checks structure only. It cannot ship a list of customer names, because that
list is itself the thing we are keeping out of core. An organisation supplies its
own terms through --denylist, and its layer owns that file.

    core/tests/test-core-purity.py
    core/tests/test-core-purity.py --denylist ../layers/<your-layer>/purity-denylist.json

Exit 0 clean, 1 findings, 2 usage.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

# A real absolute path starts the token. Without the lookbehind this also
# matched the tail of a relative one, so "dotfiles/home/.claude" read as a
# home directory and a legitimate path failed the gate.
HOME_PATH = re.compile(r"(?<![\w./~$-])/(?:Users|home)/(?!<|\$|\{)[A-Za-z0-9._-]+")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
CREDENTIAL = re.compile(
    r"xox[baprs]-[A-Za-z0-9-]{10,}"
    r"|ghp_[A-Za-z0-9]{20,}"
    r"|sk-[A-Za-z0-9]{20,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)
# Addresses that name nobody. Documentation is allowed to use them.
EMAIL_ALLOWED = ("example.com", "example.org", "localhost", "noreply@anthropic.com")
SKIP_DIRS = {".git", "__pycache__", ".pytest_cache", "node_modules"}
SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".ico", ".zip", ".gz"}


def files(root: Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        yield path


def scan(root: Path, denylist: List[str]) -> Dict[str, List[Tuple[str, int, str]]]:
    found: Dict[str, List[Tuple[str, int, str]]] = {
        "absolute home path": [],
        "email address": [],
        "credential pattern": [],
        "denylisted term": [],
    }
    terms = [(term, re.compile(r"\b%s\b" % re.escape(term), re.IGNORECASE)) for term in denylist]
    this_file = Path(__file__).resolve()

    for path in files(root):
        if path.resolve() == this_file:
            continue  # the gate names its own patterns
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        relative = str(path.relative_to(root.parent))
        for number, line in enumerate(text.splitlines(), 1):
            match = HOME_PATH.search(line)
            if match:
                found["absolute home path"].append((relative, number, match.group(0)))
            for candidate in EMAIL.findall(line):
                if not any(allowed in candidate for allowed in EMAIL_ALLOWED):
                    found["email address"].append((relative, number, candidate))
            if CREDENTIAL.search(line):
                found["credential pattern"].append((relative, number, "[redacted]"))
            for term, pattern in terms:
                if pattern.search(line):
                    found["denylisted term"].append((relative, number, term))
    return found


def check_no_layer_imports(root: Path) -> List[Tuple[str, int, str]]:
    """Rule 2 of the contract: core may not read a layer."""
    pattern = re.compile(r"(?:from|import)\s+layers\.|layers/[a-z]|\.\./layers")
    hits = []
    for path in files(root):
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        if path.name == "CONTRACT.md" or path.name == Path(__file__).name:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if pattern.search(line):
                hits.append((str(path.relative_to(root.parent)), number, line.strip()[:60]))
    return hits


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--denylist", help="JSON file with a 'terms' list of org-specific words")
    parser.add_argument("--core", default=None, help="path to core/ (default: this file's parent)")
    args = parser.parse_args()

    root = Path(args.core).resolve() if args.core else Path(__file__).resolve().parents[1]
    if not root.is_dir():
        print("no such directory: %s" % root, file=sys.stderr)
        return 2

    terms: List[str] = []
    if args.denylist:
        denylist_path = Path(args.denylist)
        if not denylist_path.is_absolute():
            denylist_path = (root / denylist_path).resolve()
        if not denylist_path.is_file():
            print("no such denylist: %s" % denylist_path, file=sys.stderr)
            return 2
        terms = json.loads(denylist_path.read_text()).get("terms", [])

    findings = scan(root, terms)
    findings["reads a layer"] = check_no_layer_imports(root)

    total = sum(len(v) for v in findings.values())
    print("core purity gate: %s" % root)
    print("denylist terms:   %d" % len(terms))
    for category, hits in findings.items():
        print("\n%-22s %d" % (category, len(hits)))
        for relative, number, detail in hits[:20]:
            print("  %s:%s  %s" % (relative, number, detail))
        if len(hits) > 20:
            print("  ... and %d more" % (len(hits) - 20))

    if total:
        print("\nFAIL: %d finding(s). core/ is not publishable as it stands." % total)
        return 1
    print("\nPASS: core/ is publishable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
