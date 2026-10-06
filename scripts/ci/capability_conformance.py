#!/usr/bin/env python3
"""Check every shell capability's non-executing metadata interface.

Keep this runner and its tests identical in the template and stamped products.
The script set is discovered; products may add capabilities without editing CI.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


SOURCE = re.compile(r"^\s*(?:source|\.)\s+[^\n]*\bcapability\.sh\b", re.MULTILINE)


def discover(root):
    scripts = sorted(
        path for path in (root / "scripts").rglob("*.sh")
        if SOURCE.search(path.read_text())
    )
    if not scripts or root / "scripts/init.sh" not in scripts:
        raise ValueError("discovery must include scripts/init.sh and at least one capability")
    return scripts


def metadata(root, path, flag):
    try:
        result = subprocess.run(
            ["bash", str(path), flag], cwd=root, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=15, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise ValueError(f"{path.relative_to(root)} {flag}: timed out") from exc
    if result.returncode:
        raise ValueError(
            f"{path.relative_to(root)} {flag}: exit {result.returncode}: {result.stderr.strip()}"
        )
    return result.stdout


def check(root):
    scripts = discover(root)
    for path in scripts:
        name = path.relative_to(root)
        # json.loads rejects both stray logs and a second document on stdout.
        try:
            spec = json.loads(metadata(root, path, "--print-spec"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"{name} --print-spec: expected exactly one JSON document: {exc}") from exc
        if not isinstance(spec, dict) or not isinstance(spec.get("capability"), str) or not spec["capability"].strip():
            raise ValueError(f"{name} --print-spec: missing non-empty capability name")
        if not isinstance(spec.get("params"), list):
            raise ValueError(f"{name} --print-spec: params must be an array")
        if name == Path("scripts/init.sh") and (spec["capability"] != "product.init" or len(spec["params"]) < 8):
            raise ValueError("scripts/init.sh must declare product.init and its eight base parameters")
        metadata(root, path, "--help")
        print(f"PASS {name}")
    return len(scripts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        count = check(args.root.resolve())
    except (ValueError, OSError) as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 1
    print(f"Verified metadata for {count} capabilities; operation results require their own execution tests.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
