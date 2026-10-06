#!/usr/bin/env python3
"""Stamp two products and load their combined DSL through the real engine."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def verify(template, engine):
    with tempfile.TemporaryDirectory(prefix="memql-starter-pair-") as scratch:
        combined = Path(scratch) / "combined"
        combined.mkdir()
        for product in ("sample", "sample-app"):
            stamped = Path(scratch) / product
            shutil.copytree(template, stamped, ignore=shutil.ignore_patterns(
                ".git", "node_modules", "__pycache__", ".DS_Store", "dist", ".cache",
            ))
            subprocess.run([
                "bash", "scripts/init.sh", f"--product={product}",
                "--product-org=sample-org", "--engine-ref=main", "--skip-clones",
            ], cwd=stamped, check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["go", "run", "./cmd/memqllint", str(stamped / "dsl")], cwd=engine, check=True)
            for path in (stamped / "dsl").iterdir():
                if path.is_dir():
                    shutil.copytree(path, combined / path.name)
                elif not (combined / path.name).exists():
                    shutil.copy2(path, combined / path.name)
        # Lint the domain ROOT, so registry collisions and imports are checked.
        subprocess.run(["go", "run", "./cmd/memqllint", str(combined)], cwd=engine, check=True)
        subprocess.run([
            "go", "run", "./cmd/memqlmigrate", "-check",
            "--rewrite=language-line,expressions,bodies,attributes,attributes-namespace",
            str(combined),
        ], cwd=engine, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-root", type=Path, required=True)
    args = parser.parse_args()
    verify(Path(__file__).resolve().parents[2], args.engine_root.resolve())


if __name__ == "__main__":
    main()
