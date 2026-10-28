"""Exercise bootstrap source acquisition offline, identically in every product."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CockpitBootstrapTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name)
        self.root = self.workspace / "product"
        self.root.mkdir()
        source = Path(__file__).resolve().parents[2]
        (self.root / "scripts/lib").mkdir(parents=True)
        for name in ("init.sh", "lib/capability.sh"):
            shutil.copy2(source / "scripts" / name, self.root / "scripts" / name)
        self.envfile = self.root / "product.env"
        self.envfile.write_text("PRODUCT=demo\nPRODUCT_ORG=example\nDOMAIN=demo.example\nENGINE_REF=v0.31.3\nREGISTRY=\n")
        self.original = self.envfile.read_bytes()
        (self.root / "README.md").write_text("Original product readme\n")
        self.bin = self.workspace / "bin"
        self.bin.mkdir()
        git = self.bin / "git"
        git.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['BOOTSTRAP_GIT_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:1] == ['ls-remote']:
    print('a' * 40 + '\\trefs/tags/v0.30.0')
    print('b' * 40 + '\\trefs/tags/v0.31.3')
    sys.exit(0)
if os.environ.get('BOOTSTRAP_GIT_FAILURE'):
    sys.exit(1)
if args[:2] == ['clone', '--branch'] and args[2] == 'c' * 40:
    sys.exit(1)
if args[:1] == ['clone']:
    dest = pathlib.Path(args[-1])
    (dest / '.git').mkdir(parents=True)
    if not os.environ.get('BOOTSTRAP_NO_COCKPIT'):
        (dest / 'cockpit').mkdir()
        (dest / 'cockpit/go.mod').write_text('module example.invalid/cockpit\\n')
    if os.environ.get('BOOTSTRAP_RACE_DEST'):
        competing = dest.parent.parent / 'memql'
        (competing / '.git').mkdir(parents=True)
        (competing / 'keep').write_text('competing work\\n')
    sys.exit(0)
if args[:1] == ['-C'] and args[2:] == ['checkout', 'c' * 40]:
    sys.exit(0)
sys.exit(1)
""")
        git.chmod(0o755)
        self.log = self.workspace / "git.jsonl"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        BOOTSTRAP_GIT_LOG=str(self.log))

    def run_init(self, *flags, expected=0):
        result = subprocess.run(
            ["bash", str(self.root / "scripts/init.sh"), "--product=demo",
             "--product-org=example", *flags], cwd=self.root, env=self.env,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["ok"], expected == 0)
        if expected:
            self.assertEqual(envelope["error"]["code"], expected)
        return result, envelope

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_unstamped(self):
        self.assertEqual(self.envfile.read_bytes(), self.original)
        self.assertEqual((self.root / "README.md").read_text(), "Original product readme\n")
        self.assertEqual(list(self.workspace.glob(".memql-init.*")), [])

    def test_clones_selected_engine_with_cockpit_and_preserves_legacy_sibling(self):
        legacy = self.workspace / "memql-cockpit"
        legacy.mkdir()
        (legacy / "keep").write_text("legacy work\n")
        _, envelope = self.run_init("--engine-ref=v0.31.3")
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:-1], ["clone", "--branch", "v0.31.3", "https://github.com/znasllc-io/memql.git"])
        self.assertTrue((self.workspace / "memql/cockpit/go.mod").is_file())
        self.assertEqual(envelope["result"]["engineRef"], "v0.31.3")
        self.assertEqual((legacy / "keep").read_text(), "legacy work\n")
        self.run_init()
        self.assertEqual(self.calls(), calls)

    def test_default_release_selects_monorepo_and_cockpit(self):
        self.envfile.write_bytes(self.original.replace(b"ENGINE_REF=v0.31.3", b"ENGINE_REF="))
        _, envelope = self.run_init()
        self.assertEqual(envelope["result"]["engineRef"], "v0.31.3")
        self.assertTrue((self.workspace / "memql/cockpit/go.mod").is_file())
        self.assertEqual(self.calls()[-1][1:3], ["--branch", "v0.31.3"])

    def test_historical_source_ref_refuses_before_stamping(self):
        self.env["BOOTSTRAP_NO_COCKPIT"] = "1"
        self.run_init("--engine-ref=v0.14.0", expected=3)
        self.assert_unstamped()
        self.assertFalse((self.workspace / "memql").exists())

    def test_commit_ref_uses_checkout_fallback_in_staging(self):
        ref = "c" * 40
        _, envelope = self.run_init("--engine-ref=" + ref)
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][:-1], ["clone", "--branch", ref, "https://github.com/znasllc-io/memql.git"])
        self.assertEqual(calls[1][:-1], ["clone", "https://github.com/znasllc-io/memql.git"])
        self.assertEqual(calls[2], ["-C", calls[1][-1], "checkout", ref])
        self.assertEqual(envelope["result"]["engineRef"], ref)
        self.assertTrue((self.workspace / "memql/cockpit/go.mod").is_file())

    def test_clone_failure_refuses_before_stamping(self):
        self.env["BOOTSTRAP_GIT_FAILURE"] = "1"
        self.run_init(expected=5)
        self.assert_unstamped()
        self.assertFalse((self.workspace / "memql").exists())

    def test_existing_old_checkout_is_preserved_and_refused(self):
        dest = self.workspace / "memql"
        (dest / ".git").mkdir(parents=True)
        (dest / "keep").write_text("existing engine\n")
        self.run_init(expected=3)
        self.assert_unstamped()
        self.assertEqual((dest / "keep").read_text(), "existing engine\n")
        self.assertEqual(self.calls(), [])

    def test_existing_monorepo_worktree_is_preserved(self):
        dest = self.workspace / "memql"
        (dest / "cockpit").mkdir(parents=True)
        (dest / ".git").write_text("gitdir: /unchanged/worktree\n")
        (dest / "cockpit/go.mod").write_text("module example.invalid/cockpit\n")
        self.run_init()
        self.assertEqual((dest / ".git").read_text(), "gitdir: /unchanged/worktree\n")
        self.assertEqual(self.calls(), [])

    def test_competing_destination_is_preserved_without_nesting_checkout(self):
        self.env["BOOTSTRAP_RACE_DEST"] = "1"
        _, envelope = self.run_init(expected=3)
        self.assert_unstamped()
        dest = self.workspace / "memql"
        self.assertEqual(sorted(p.name for p in dest.iterdir()), [".git", "keep"])
        self.assertEqual((dest / "keep").read_text(), "competing work\n")
        self.assertFalse(envelope["changed"])

    def test_skip_clones_retains_historical_pin_without_acquiring_source(self):
        self.run_init("--skip-clones", "--engine-ref=v0.14.0")
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.workspace / "memql").exists())
        self.assertIn("ENGINE_REF=v0.14.0", self.envfile.read_text())

    def test_retired_cockpit_ref_is_rejected_before_writes(self):
        self.run_init("--cockpit-ref=main", expected=2)
        self.assert_unstamped()
        self.assertEqual(self.calls(), [])

    def test_dry_run_reports_monorepo_without_mutation(self):
        result, _ = self.run_init("--dry-run")
        self.assertIn("includes cockpit/", result.stderr)
        self.assertNotIn("memql-cockpit", result.stderr)
        self.assert_unstamped()
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
