"""Exercise the shipped DSL step without a network or an engine build."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
RECIPE = ROOT / ".template/memql-package.yaml"
if (ROOT / "product.env").exists() or not RECIPE.exists():
    RECIPE = ROOT / "memql-package.yaml"


class OptionalDSL(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="memql-optional-dsl-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.dsl = self.root / "dsl"
        self.dsl.mkdir()
        (self.root / "product.env").write_text("ENGINE_REF=v1.0.0\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Record attempts to fetch an engine or lint, without doing either.
        self.stub("git", 'printf "git %s\\n" "$*" >> "$TRACE"\nmkdir -p "$ENGINE"\n')
        self.stub("go", 'printf "go %s\\n" "$*" >> "$TRACE"\nexit "${LINT_STATUS:-0}"\n')
        manifest = yaml.safe_load(RECIPE.read_text())
        checks = next(s for s in manifest["pipeline"]["stages"] if s["name"] == "checks")
        self.run_script = next(s["run"] for s in checks["steps"] if s["name"] == "dsl")
        # Give the recipe's scratch clone its own isolated directory.
        self.engine = self.root / "engine"
        self.run_script = self.run_script.replace("/tmp/memql", str(self.engine))
        self.trace = self.root / "trace"

    def stub(self, name, body):
        target = self.bin / name
        target.write_text("#!/bin/sh\n" + body)
        target.chmod(0o755)

    def run_step(self, lint_status=0):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   TRACE=str(self.trace), ENGINE=str(self.engine), LINT_STATUS=str(lint_status))
        result = subprocess.run(["bash", "-c", self.run_script], cwd=self.root, env=env,
                                text=True, capture_output=True)
        trace = self.trace.read_text() if self.trace.exists() else ""
        return result, trace

    def test_empty_root_skips_engine_fetch_and_lint(self):
        result, trace = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("client-only", result.stdout)
        self.assertEqual(trace, "")

    def test_documented_client_only_root_skips_engine_fetch_and_lint(self):
        (self.dsl / "README.md").write_text("No product DSL yet.\n")
        result, trace = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, "")

    def test_missing_root_fails_before_engine_fetch(self):
        self.dsl.rmdir()
        result, trace = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, "")

    def test_misplaced_dsl_cannot_be_silently_skipped(self):
        for name in ("concepts.memql", "memql.toml", "namespace.pin"):
            with self.subTest(name=name):
                target = self.dsl / name
                target.write_text("misplaced\n")
                result, trace = self.run_step()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(trace, "")
                target.unlink()

    def test_symlink_domain_cannot_look_like_a_client_only_package(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.dsl / "linked").symlink_to(outside, target_is_directory=True)
        result, trace = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, "")

    def test_domain_runs_full_root_lint_at_the_pinned_engine(self):
        (self.dsl / "example").mkdir()
        result, trace = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("git clone --depth 1 --branch v1.0.0", trace)
        self.assertIn(f"go run ./cmd/memqllint {self.dsl}\n", trace)

    def test_lint_failure_is_still_fatal(self):
        (self.dsl / "example").mkdir()
        result, trace = self.run_step(lint_status=1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("go run ./cmd/memqllint", trace)


if __name__ == "__main__":
    unittest.main()
