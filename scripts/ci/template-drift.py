"""Retain the weekly template harness comparison as a native pipeline artifact."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


PATHS = ('memql-package.yaml', 'scripts', 'Makefile', 'CLAUDE.md', 'ONBOARDING.md', '.gitignore')
STAMPED = {'CLAUDE.md', 'ONBOARDING.md', 'memql-package.yaml'}


def git(root, *args):
    env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_TERMINAL_PROMPT='0')
    return subprocess.check_output(['git', '-c', 'safe.directory=' + str(root.resolve()),
                                   '-C', str(root), *args], env=env, stderr=subprocess.DEVNULL, timeout=120)


def inventory(root):
    # Tracked paths only: test caches and local scratch are not harness drift.
    return {name.decode() for name in git(root, 'ls-files', '-z', '--', *PATHS).split(b'\0') if name}


def digest(root, name):
    path = root / name
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('harness path is not a regular file inside its checkout')
    if path.stat().st_size > 10 << 20:
        raise ValueError('harness file exceeds comparison limit')
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def compare(root, template):
    local, upstream = inventory(root), inventory(template)
    counts = {state: 0 for state in ('same', 'differs', 'stamped', 'missing', 'extra')}
    rows = []
    for name in sorted(local | upstream):
        if name not in local:
            state = 'missing'
        elif name not in upstream:
            state = 'extra'
        elif digest(root, name) == digest(template, name):
            state = 'same'
        else:
            state = 'stamped' if name in STAMPED else 'differs'
        counts[state] += 1
        if state != 'same':
            rows.append({'path': name, 'state': state})
    return {'formatVersion': 1, 'code': 'template_compared', 'compared': True,
            'sourceCommit': git(root, 'rev-parse', 'HEAD').decode().strip(),
            'templateCommit': git(template, 'rev-parse', 'HEAD').decode().strip(),
            'counts': counts, 'differences': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--template', type=Path, help='existing checkout for an offline comparison')
    parser.add_argument('--output', type=Path, default=Path('.memql-maintenance/template-drift.json'))
    args = parser.parse_args()
    report = {'formatVersion': 1, 'compared': False, 'code': 'template_comparison_unavailable'}
    try:
        with tempfile.TemporaryDirectory(prefix='memql-template-drift-') as temp:
            template = args.template
            if template is None:
                template = Path(temp) / 'template'
                git(Path(temp), '-c', 'credential.helper=', 'clone', '--depth=1', '--branch=main',
                    'https://github.com/znasllc-io/memql-project.git', str(template))
            report = compare(args.root, template)
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        pass
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    # Intentional divergence remains a report, as in the retired Actions job.
    return 0 if report['compared'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
