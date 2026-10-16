"""The template recipe becomes the product recipe exactly once."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PipelineStamping(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="memql-pipeline-stamp-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "product"
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns(
            ".git", "node_modules", ".next", "dist", "__pycache__", ".memql-ci", ".memql-security"))

    def stamp(self, *extra, product="demo-app"):
        return subprocess.run([
            str(self.root / "scripts/init.sh"), f"--product={product}",
            "--product-org=demo-org", "--domain=demo.local", "--engine-ref=v0.24.0",
            "--skip-clones", *extra,
        ], cwd=self.root, text=True, capture_output=True)

    def test_product_recipe_is_stamped_once_and_owner_edits_survive(self):
        first = self.stamp()
        self.assertEqual(first.returncode, 0, first.stderr)
        manifest = self.root / "memql-package.yaml"
        contents = manifest.read_text()
        self.assertIn("name: demo-app\n", contents)
        self.assertNotIn("__PRODUCT__", contents)
        self.assertNotIn("name: init-smoke", contents)
        self.assertFalse((self.root / ".template").exists())
        manifest.write_text(contents + "\n# An owner-authored policy extension.\n")
        before = manifest.read_bytes()
        second = self.stamp()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertFalse(json.loads(second.stdout)["changed"])
        self.assertEqual(manifest.read_bytes(), before)
        refused = self.stamp(product="different")
        self.assertEqual(refused.returncode, 3)
        self.assertEqual(manifest.read_bytes(), before)

    def test_dry_run_keeps_both_recipes_unchanged(self):
        paths = [self.root / "memql-package.yaml", self.root / ".template/memql-package.yaml"]
        before = [p.read_bytes() for p in paths]
        result = self.stamp("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["changed"])
        self.assertEqual([p.read_bytes() for p in paths], before)

    def test_template_sync_cannot_replace_an_existing_product_recipe(self):
        first = self.stamp()
        self.assertEqual(first.returncode, 0, first.stderr)
        manifest = self.root / "memql-package.yaml"
        manifest.write_text(manifest.read_text() + "\n# Owner-selected pipeline policy.\n")
        source = self.root / ".template/memql-package.yaml"
        source.parent.mkdir()
        source.write_text("name: __PRODUCT__\npipeline: {stages: []}\n")
        paths = [manifest, source]
        before = [p.read_bytes() for p in paths]
        for flags in [("--dry-run",), ()]:
            with self.subTest(flags=flags):
                result = self.stamp(*flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(json.loads(result.stdout)["changed"])
                self.assertNotIn("would copy:", result.stderr)
                self.assertEqual([p.read_bytes() for p in paths], before)

    def test_first_stamp_preserves_other_template_assets(self):
        extra = self.root / ".template/another-recipe.yaml"
        extra.write_text("name: retained-template-asset\n")
        result = self.stamp()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("name: demo-app\n", (self.root / "memql-package.yaml").read_text())
        self.assertFalse((self.root / ".template/memql-package.yaml").exists())
        self.assertEqual(extra.read_text(), "name: retained-template-asset\n")


if __name__ == "__main__":
    unittest.main()
