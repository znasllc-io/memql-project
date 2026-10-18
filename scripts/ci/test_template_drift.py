import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('template-drift.py')
spec = importlib.util.spec_from_file_location('drift', SCRIPT)
drift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drift)


def checkout(path, files):
    path.mkdir()
    subprocess.run(['git', 'init', '-q', str(path)], check=True)
    for name, content in files.items():
        target = path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    subprocess.run(['git', '-C', str(path), 'add', '--', *files], check=True)
    subprocess.run(['git', '-C', str(path), '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                    '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture'], check=True)


class DriftTests(unittest.TestCase):
    def test_compares_every_harness_state_without_product_or_scratch_noise(self):
        with tempfile.TemporaryDirectory() as directory:
            root, template = Path(directory) / 'root', Path(directory) / 'template'
            checkout(root, {'Makefile': 'same', 'CLAUDE.md': 'product', 'scripts/common.sh': 'changed',
                            'scripts/extra.py': 'new', 'clients/app.txt': 'product'})
            checkout(template, {'Makefile': 'same', 'CLAUDE.md': 'template', 'scripts/common.sh': 'original',
                                'scripts/missing.py': 'missing', '.github/workflows/template-ci.yml': 'template only'})
            (root / 'scripts/scratch.txt').write_text('not tracked')
            receipt = drift.compare(root, template)
            self.assertEqual(receipt['counts'], {'same': 1, 'stamped': 1, 'differs': 1, 'missing': 1, 'extra': 1})
            self.assertEqual(len(receipt['sourceCommit']), 40)
            self.assertEqual(len(receipt['templateCommit']), 40)
            self.assertNotEqual(receipt['sourceCommit'], receipt['templateCommit'])

    def test_symlink_cannot_read_outside_the_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'link').symlink_to('/etc/hostname')
            with self.assertRaises(ValueError):
                drift.digest(root, 'link')

    def test_missing_template_retains_failure_receipt_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / 'report.json'
            result = subprocess.run(['python3', str(SCRIPT), '--root', str(root), '--template', str(root / 'absent'),
                                     '--output', str(output)], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(output.read_text())['compared'], False)


if __name__ == '__main__':
    unittest.main()
