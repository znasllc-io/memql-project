#!/usr/bin/env python3
"""Keep declared native image builds complete as product surfaces change.

This edits only the marked image stage. It never builds, publishes or changes
registry credentials. Existing public build arguments stay reviewable in YAML.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import sys

import yaml

BEGIN = "  # BEGIN NATIVE PRODUCT IMAGES\n"
END = "  # END NATIVE PRODUCT IMAGES\n"
SLUG = re.compile(r"[a-z][a-z0-9-]{0,62}\Z")


def components(root):
    bundle = root / "deploy/Dockerfile.bundle"
    if bundle.is_symlink() or not bundle.is_file():
        raise ValueError("product requires a regular deploy/Dockerfile.bundle")
    result = {"dsl-bundle": {"context": ".", "dockerfile": "deploy/Dockerfile.bundle"}}
    for surface in sorted((root / "clients").iterdir()):
        if not surface.is_dir():
            continue
        if surface.is_symlink() or not SLUG.fullmatch(surface.name) or surface.name in result:
            raise ValueError("client surface must have a unique directory slug")
        dockerfile = surface / "Dockerfile"
        if dockerfile.is_symlink() or not dockerfile.is_file():
            raise ValueError(f"clients/{surface.name} needs its Dockerfile")
        result[surface.name] = {"context": f"clients/{surface.name}",
                                "dockerfile": f"clients/{surface.name}/Dockerfile"}
    if len(result) < 2:
        raise ValueError("product has no client surfaces")
    return result


def stage_for(root, manifest):
    pipeline = manifest["pipeline"]
    if pipeline.get("platform") != "linux/amd64":
        raise ValueError("product images require the declared linux/amd64 platform")
    candidates = [s for s in pipeline["stages"] if s.get("name") == "images"]
    if len(candidates) > 1:
        raise ValueError("duplicate images stage")
    previous = candidates[0] if candidates else {"name": "images", "on": ["release"], "steps": []}
    if previous.get("on") != ["release"] or previous.get("when") or previous.get("needs"):
        raise ValueError("images stage must build the complete product on release")
    steps = previous.get("steps", [])
    old = {s["name"]: s for s in steps}
    if len(old) != len(steps):
        raise ValueError("duplicate image step")
    generated = copy.deepcopy(previous)
    generated["steps"] = []
    for name, build in components(root).items():
        step = copy.deepcopy(old.get(name, {"name": name, "placement": "cluster", "caches": [],
            "cpuMilli": 2000, "memoryMiB": 4096, "timeout": "45m", "imageBuild": build}))
        actual = step.get("imageBuild", {})
        if any(actual.get(k) != v for k, v in build.items()):
            raise ValueError(f"{name}: image source differs from its product component")
        if (step.get("placement") != "cluster" or step.get("platform", "linux/amd64") != "linux/amd64"
                or step.get("run") or step.get("when") or step.get("services") or step.get("caches")):
            raise ValueError(f"{name}: requires an unconditional isolated cloud image build")
        generated["steps"].append(step)
    return generated, previous if candidates else None


def update(root, path, write=False):
    version = (root / "VERSION").read_text().strip()
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise ValueError("VERSION must contain one canonical product release version")
    if os.environ.get("MEMQL_EVENT") == "release" and os.environ.get("MEMQL_VERSION") not in (version, "v" + version):
        raise ValueError("release tag differs from the product VERSION at this commit")
    original = path.read_text()
    # BaseLoader avoids YAML 1.1 treating the manifest's `on` key as boolean.
    # SafeLoader's scalar conversions are retained after fixing that resolver.
    class Loader(yaml.SafeLoader):
        pass
    Loader.yaml_implicit_resolvers = {k: [(tag, rx) for tag, rx in values
        if tag != "tag:yaml.org,2002:bool"] for k, values in Loader.yaml_implicit_resolvers.items()}
    Loader.add_implicit_resolver("tag:yaml.org,2002:bool", re.compile(r"^(?:true|false)$"), list("tf"))
    manifest = yaml.load(original, Loader=Loader)
    expected, current = stage_for(root, manifest)
    if write:
        if original.count(BEGIN) != original.count(END) or original.count(BEGIN) > 1:
            raise ValueError("ambiguous native image stage markers")
        if current is not None and BEGIN not in original:
            raise ValueError("existing images stage must be reviewed and marked before rewriting")
        block = BEGIN + "\n".join("  " + line for line in yaml.safe_dump([expected], sort_keys=False).splitlines()) + "\n" + END
        if BEGIN in original:
            first, rest = original.split(BEGIN)
            _, last = rest.split(END)
            result = first + block + last
        else:
            # Only append under pipeline.stages when it is the final mapping.
            if re.search(r"^\S", original[original.index("pipeline:") + len("pipeline:"):], re.M):
                raise ValueError("pipeline must be the last root mapping before adding the marked stage")
            result = original.replace("  stages: []\n", "  stages:\n").rstrip() + "\n" + block
        checked = yaml.load(result, Loader=Loader)
        _, written = stage_for(root, checked)
        if written != expected:
            raise ValueError("generated stage did not preserve the manifest structure")
        path.write_text(result)
    elif current != expected:
        raise ValueError("native image inventory is stale; run scripts/ci/product-images.py --write and review it")
    return [s["name"] for s in expected["steps"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--manifest", type=Path, default=Path("memql-package.yaml"))
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    names = update(root, root / args.manifest, args.write)
    print(json.dumps({"components": names, "platform": "linux/amd64", "publication": "approved release candidate"}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, yaml.YAMLError) as error:
        print(f"product image declarations: {error}", file=sys.stderr)
        sys.exit(1)
