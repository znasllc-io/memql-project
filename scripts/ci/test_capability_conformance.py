"""Exercise discovery and its failure controls without invoking release actions."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from capability_conformance import check, discover


class ConformanceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts/lib").mkdir(parents=True)
        (self.root / "scripts/lib/capability.sh").write_text("# fixture runtime\n")
        self.script("init.sh", {"capability": "product.init", "params": [{}] * 8})

    def script(self, name, spec, suffix="", help_exit=0):
        path = self.root / "scripts" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        # JSON is supplied as a quoted heredoc, never as shell code.
        path.write_text(
            '. ./scripts/lib/capability.sh\n'
            f'if [ "$1" = "--help" ]; then exit {help_exit}; fi\n'
            "cat <<'SPEC'\n" + json.dumps(spec) + suffix + "\nSPEC\n"
        )
        return path

    def run_check(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return check(self.root)

    def test_additional_product_capabilities_are_discovered(self):
        self.script("release/publish.sh", {"capability": "product.publish", "params": []})
        self.script("other action.sh", {"capability": "product.other", "params": []})
        self.assertEqual(self.run_check(), 3)

    def test_non_init_second_json_document_and_logs_fail(self):
        for extra in ('\n{}', '\nthis log belongs on stderr'):
            with self.subTest(extra=extra):
                self.script("release/publish.sh", {"capability": "product.publish", "params": []}, extra)
                with self.assertRaisesRegex(ValueError, "release/publish.sh.*exactly one"):
                    self.run_check()

    def test_non_init_bad_spec_fails(self):
        for spec in ({"capability": " ", "params": []}, {"capability": "publish", "params": {}}, []):
            with self.subTest(spec=spec):
                self.script("release/publish.sh", spec)
                with self.assertRaisesRegex(ValueError, "release/publish.sh"):
                    self.run_check()

    def test_non_init_failed_help_fails(self):
        self.script("release/publish.sh", {"capability": "publish", "params": []}, help_exit=5)
        with self.assertRaisesRegex(ValueError, "publish.sh --help: exit 5"):
            self.run_check()

    def test_floor_requires_init_even_when_other_capabilities_exist(self):
        (self.root / "scripts/init.sh").unlink()
        with self.assertRaisesRegex(ValueError, "discovery must include"):
            discover(self.root)
        self.script("release/publish.sh", {"capability": "publish", "params": []})
        with self.assertRaisesRegex(ValueError, "discovery must include"):
            discover(self.root)

    def test_runtime_comment_does_not_count_as_a_capability(self):
        (self.root / "scripts/lib/capability.sh").write_text('# source "lib/capability.sh"\n')
        self.assertEqual(self.run_check(), 1)

    def test_named_init_contract_still_applies(self):
        self.script("init.sh", {"capability": "wrong", "params": [{}] * 8})
        with self.assertRaisesRegex(ValueError, "product.init"):
            self.run_check()


if __name__ == "__main__":
    unittest.main()
