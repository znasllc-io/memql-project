#!/usr/bin/env python3
"""Check every shell capability's non-executing metadata interface and how it
reads its boolean params.

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

# Boolean reads. cap_flag returns the raw flag string and "false" is not empty,
# so a boolean read through it and tested with -n took --force=false as true:
# assemble-lockfile.sh overwrote an immutable lockfile. A boolean is read with
# cap_bool. The engine's TestCapabilityScriptsReadBooleansWithCapBool holds its
# own scripts to these two rules and three more about cap_bool_str, which no
# script here uses.
SPEC_PARAM = re.compile(r'cap_spec_param(?:_required)?[ \t]+"([^"]+)"[ \t]+"((?:[^"\\]|\\.)*)"')
# A param is declared a flag when a parenthetical in its description names the
# word: "(flag)", "(flag; for CI + offline runs)", "(immutability override; flag)".
FLAG_MARKER = re.compile(r"\([^()]*\bflag\b[^()]*\)")
PARAM_READ = re.compile(r'\b(cap_flag|cap_param|cap_bool_str|cap_bool)[ \t]+"?([A-Za-z0-9][A-Za-z0-9_-]*)"?')


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


def boolean_reads(text):
    """Return (line, problem) for every boolean read that can fail open.

    1. A param declared a flag is read only with cap_bool or cap_bool_str.
    2. cap_flag only probes whether a VALUE param arrived as a flag, beside the
       cap_param read that resolves it (init.sh's --domain); a cap_flag read
       of a param nothing resolves is a boolean read, whatever its description
       says. Full-line comments are not code.
    """
    declared = {m.group(1) for m in SPEC_PARAM.finditer(text) if FLAG_MARKER.search(m.group(2))}
    reads, valued = [], set()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        for match in PARAM_READ.finditer(line):
            reads.append((number, match.group(1), match.group(2)))
            if match.group(1) == "cap_param":
                valued.add(match.group(2))
    problems = []
    for number, reader, param in reads:
        if param in declared and reader in ("cap_flag", "cap_param"):
            problems.append((number, f"--{param} is declared a flag but read with {reader}, whose raw "
                                     f"string makes --{param}=false read as true; use `if cap_bool {param}; then`"))
        elif reader == "cap_flag" and param not in valued:
            problems.append((number, f"cap_flag {param} reads a param no cap_param resolves, so it is a "
                                     f"boolean read; use `if cap_bool {param}; then`"))
    return problems


def check(root):
    scripts = discover(root)
    for path in scripts:
        name = path.relative_to(root)
        problems = boolean_reads(path.read_text())
        if problems:
            raise ValueError("\n".join(f"{name}:{line}: {problem}" for line, problem in problems))
        # json.loads rejects both stray logs and a second document on stdout.
        try:
            spec = json.loads(metadata(root, path, "--print-spec"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"{name} --print-spec: expected exactly one JSON document: {exc}") from exc
        if not isinstance(spec, dict) or not isinstance(spec.get("capability"), str) or not spec["capability"].strip():
            raise ValueError(f"{name} --print-spec: missing non-empty capability name")
        if not isinstance(spec.get("params"), list):
            raise ValueError(f"{name} --print-spec: params must be an array")
        if name == Path("scripts/init.sh") and (spec["capability"] != "product.init" or len(spec["params"]) < 7):
            raise ValueError("scripts/init.sh must declare product.init and its seven base parameters")
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
