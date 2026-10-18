import argparse
import contextlib
import io
import http.server
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch

import verify_rollout as rollout


MANIFEST = {'schema': 1, 'algorithm': 'sha256', 'files': {'index.html': 'a' * 64, 'assets/main.js': 'b' * 64}}
IMAGE = 'ghcr.io/example/edge@sha256:' + 'c' * 64


def archive(path, entries):
    with tarfile.open(path, 'w') as out:
        for name, content, kind in entries:
            entry = tarfile.TarInfo(name)
            entry.type = kind
            entry.size = len(content) if kind == tarfile.REGTYPE else 0
            out.addfile(entry, io.BytesIO(content) if entry.isfile() else None)


class ManifestTests(unittest.TestCase):
    def test_valid_and_canonical_order(self):
        self.assertEqual(rollout.manifest(json.dumps(MANIFEST).encode()), MANIFEST)
        reordered = {'files': MANIFEST['files'], 'algorithm': 'sha256', 'schema': 1}
        self.assertEqual(rollout.canonical_digest(MANIFEST), rollout.canonical_digest(reordered))

    def test_rejects_ambiguous_or_invalid_manifests(self):
        inputs = [b'{"schema":1,"schema":1,"algorithm":"sha256","files":{"index.html":"' + b'a' * 64 + b'"}}',
                  b'<html>fallback</html>', json.dumps(dict(MANIFEST, extra=True)).encode(),
                  b'null', b'[]', json.dumps(dict(MANIFEST, schema=True)).encode(),
                  b'x' * (rollout.MAX_MANIFEST + 1)]
        for path in ('../x', '/x', 'a//b', 'a/./b', 'a%2fb', 'a?b', 'a#b', 'a\\b', '_memql/site-refresh.js'):
            inputs.append(json.dumps(dict(MANIFEST, files={'index.html': 'a' * 64, path: 'b' * 64})).encode())
        for data in inputs:
            with self.subTest(data=data[:100]), self.assertRaises(rollout.Refused):
                rollout.manifest(data)

    def test_tar_reads_only_manifest_without_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.tar'
            archive(path, [('../../escape', b'no extraction', tarfile.REGTYPE),
                           (rollout.MANIFEST_PATH, json.dumps(MANIFEST).encode(), tarfile.REGTYPE)])
            self.assertEqual(rollout.image_manifest(path), MANIFEST)
            self.assertEqual([p.name for p in Path(directory).iterdir()], ['image.tar'])

    def test_missing_duplicate_symlink_and_truncated_archives_fail(self):
        valid = (rollout.MANIFEST_PATH, json.dumps(MANIFEST).encode(), tarfile.REGTYPE)
        cases = [[], [valid, valid], [(rollout.MANIFEST_PATH, b'', tarfile.SYMTYPE)]]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.tar'
            for entries in cases:
                archive(path, entries)
                with self.assertRaises(rollout.Refused):
                    rollout.image_manifest(path)
            path.write_bytes(b'broken')
            with self.assertRaises(rollout.Refused):
                rollout.image_manifest(path)
            path.unlink()
            with self.assertRaises(rollout.Refused):
                rollout.image_manifest(path)

    def test_public_transport_refuses_redirects_errors_and_oversized_bodies(self):
        received = []
        mode = ['valid']
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                received.append(self.path)
                if mode[0] == 'redirect':
                    self.send_response(302)
                    self.send_header('Location', '/must-not-be-followed')
                    body = b''
                elif mode[0] == 'error':
                    self.send_response(503)
                    body = b'no'
                else:
                    self.send_response(200)
                    body = b'x' * (rollout.MAX_MANIFEST + 1) if mode[0] == 'oversize' else json.dumps(MANIFEST).encode()
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                origin = 'http://127.0.0.1:' + str(server.server_port)
                self.assertEqual(rollout.public_manifest(origin, 2), MANIFEST)
                for case, code in [('redirect', 'rollout_redirect_refused'),
                                   ('error', 'rollout_bundle_unreported'),
                                   ('oversize', 'rollout_bundle_too_large')]:
                    mode[0] = case
                    with self.subTest(case=case), self.assertRaisesRegex(rollout.Refused, code):
                        rollout.public_manifest(origin, 2)
            finally:
                server.shutdown()
                thread.join()
        self.assertEqual(received, ['/memql-bundle.json'] * 4)

    def test_wait_preserves_last_typed_failure_and_accepts_recovery(self):
        clock = [0]
        sleep = lambda seconds: clock.__setitem__(0, clock[0] + seconds)
        calls = []
        def recovering(origin, timeout):
            calls.append(timeout)
            return {} if len(calls) == 1 else MANIFEST
        digest = rollout.wait_for_manifest(MANIFEST, 'https://os.example.com', 30,
            fetch=recovering, now=lambda: clock[0], sleep=sleep)
        self.assertEqual(digest, rollout.canonical_digest(MANIFEST))
        self.assertEqual(len(calls), 2)
        def unreachable(origin, timeout):
            raise rollout.Refused('rollout_unreachable')
        with self.assertRaisesRegex(rollout.Refused, 'rollout_unreachable'):
            rollout.wait_for_manifest(MANIFEST, 'https://os.example.com', 20,
                fetch=unreachable, now=lambda: clock[0], sleep=sleep)


class VerificationTests(unittest.TestCase):
    def run_case(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'receipt.json'
            args = argparse.Namespace(edge_image=IMAGE, domain='example.com', version='v1.2.3',
                os_origin='https://os.example.com', verifier='/verified/memql-verify',
                crane='/verified/crane', docs='https://docs.example.com/', wait_seconds=60, evidence=evidence)
            commands = []
            def command(argv, **options):
                commands.append((argv, options))
                self.assertEqual(set(options['env']), {'PATH', 'DOCKER_CONFIG'})
                if argv[0] == args.crane:
                    if mode == 'export-failed':
                        raise subprocess.TimeoutExpired(argv, 1)
                    archive(argv[-1], [(rollout.MANIFEST_PATH, json.dumps(MANIFEST).encode(), tarfile.REGTYPE)])
                else:
                    destination = next(x.split('=', 1)[1] for x in argv if x.startswith('--evidence='))
                    if mode != 'missing-evidence':
                        Path(destination).write_text(json.dumps([] if mode == 'invalid-evidence' else {'verified': mode != 'child-failed'}))
                    if mode == 'child-failed':
                        return subprocess.CompletedProcess(argv, 1)
                return subprocess.CompletedProcess(argv, 0)
            with patch.object(rollout.subprocess, 'run', command), \
                 patch.object(rollout, 'wait_for_manifest', return_value=rollout.canonical_digest(MANIFEST)), \
                 patch.object(rollout, 'public_manifest', return_value={} if mode == 'changed' else MANIFEST), \
                 contextlib.redirect_stdout(io.StringIO()):
                status = rollout.verify(args)
            result = json.loads(evidence.read_text())
            for _, options in commands:
                self.assertFalse(Path(options['env']['DOCKER_CONFIG']).exists(), 'temporary download must be removed')
            return status, result, commands

    def test_success_keeps_image_identity_and_public_receipt(self):
        status, receipt, commands = self.run_case('success')
        self.assertEqual(status, 0)
        self.assertEqual(receipt['edgeImage'], IMAGE)
        self.assertEqual(receipt['bundleManifestSHA256'], rollout.canonical_digest(MANIFEST))
        self.assertTrue(receipt['public']['verified'])
        self.assertIn('--samples=6', commands[1][0])
        self.assertIn('--docs=https://docs.example.com/', commands[1][0])

    def test_every_failure_retains_receipt_and_never_reports_success(self):
        for mode, code in [('export-failed', 'rollout_image_unreadable'),
                           ('child-failed', 'rollout_unverified'),
                           ('missing-evidence', 'rollout_unverified'),
                           ('invalid-evidence', 'rollout_verifier_incomplete'),
                           ('changed', 'rollout_changed_during_verification')]:
            with self.subTest(mode=mode):
                status, receipt, _ = self.run_case(mode)
                self.assertEqual(status, 1)
                self.assertFalse(receipt['verified'])
                self.assertEqual(receipt['code'], code)


if __name__ == '__main__':
    unittest.main()
