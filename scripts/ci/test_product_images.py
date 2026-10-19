import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("product_images", Path(__file__).with_name("product-images.py"))
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)


class ProductImages(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="memql-image-inventory-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.add_file("VERSION", "0.1.0\n")
        self.add_file("deploy/Dockerfile.bundle", "FROM scratch\nCOPY dsl /bundle\n")
        self.add_file("clients/web/Dockerfile", "FROM scratch\n")
        self.path = self.root / "memql-package.yaml"
        self.path.write_text("formatVersion: 1\nname: demo\npipeline:\n  platform: linux/amd64\n  stages: []\n")

    def add_file(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def test_added_and_removed_surfaces_require_a_reviewed_refresh(self):
        # A real sequence preserves the owner's checks and yields parseable YAML.
        self.path.write_text(self.path.read_text().replace("  stages: []", "  stages:\n  - name: checks\n    steps: []"))
        with self.assertRaises(ValueError):
            images.update(self.root, self.path)
        images.update(self.root, self.path, True)
        self.assertEqual(images.update(self.root, self.path), ["dsl-bundle", "web"])
        before = self.path.read_bytes()
        images.update(self.root, self.path, True)
        self.assertEqual(before, self.path.read_bytes())
        self.add_file("clients/game/Dockerfile", "FROM scratch\n")
        with self.assertRaises(ValueError):
            images.update(self.root, self.path)
        images.update(self.root, self.path, True)
        self.assertEqual(images.update(self.root, self.path), ["dsl-bundle", "game", "web"])
        (self.root / "clients/game/Dockerfile").unlink()
        with self.assertRaises(ValueError):
            images.update(self.root, self.path)
        (self.root / "clients/game").rmdir()
        with self.assertRaises(ValueError):
            images.update(self.root, self.path)
        self.assertIn("- name: checks", self.path.read_text())

    def test_credentials_are_opted_in_and_public_arguments_survive(self):
        self.path.write_text(self.path.read_text().replace("  stages: []", "  stages:\n  - name: checks\n    steps: []"))
        images.update(self.root, self.path, True)
        self.path.write_text(self.path.read_text().replace("    - name: web\n", "    - name: web\n      githubReadToken: true\n").replace("dockerfile: clients/web/Dockerfile", "dockerfile: clients/web/Dockerfile\n        args:\n          VITE_MEMQL_HTTP_URL: https://api.example.test"))
        images.update(self.root, self.path, True)
        self.assertIn("githubReadToken: true", self.path.read_text())
        self.assertIn("https://api.example.test", self.path.read_text())
        self.assertEqual(images.update(self.root, self.path), ["dsl-bundle", "web"])

    def test_symlinks_and_a_non_image_command_are_refused(self):
        self.path.write_text(self.path.read_text().replace("  stages: []", "  stages:\n  - name: checks\n    steps: []"))
        images.update(self.root, self.path, True)
        before = self.path.read_text()
        self.path.write_text(before.replace("    - name: web\n", "    - name: web\n      run: docker push ignored\n"))
        with self.assertRaises(ValueError):
            images.update(self.root, self.path, True)
        self.path.write_text(before)
        (self.root / "clients/link").symlink_to(self.root / "clients/web", target_is_directory=True)
        with self.assertRaises(ValueError):
            images.update(self.root, self.path)

    def test_ambiguous_markers_fail_without_modification(self):
        self.path.write_text(self.path.read_text() + images.BEGIN)
        before = self.path.read_bytes()
        with self.assertRaises(ValueError):
            images.update(self.root, self.path, True)
        self.assertEqual(before, self.path.read_bytes())

    def test_empty_stage_list_is_replaced_and_release_identity_is_checked(self):
        from unittest.mock import patch
        images.update(self.root, self.path, True)
        self.assertEqual(images.update(self.root, self.path), ["dsl-bundle", "web"])
        with patch.dict("os.environ", {"MEMQL_EVENT": "release", "MEMQL_VERSION": "v0.1.1"}):
            with self.assertRaises(ValueError):
                images.update(self.root, self.path)
        with patch.dict("os.environ", {"MEMQL_EVENT": "release", "MEMQL_VERSION": "v0.1.0"}):
            images.update(self.root, self.path)


if __name__ == "__main__":
    unittest.main()
