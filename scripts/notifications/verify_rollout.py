"""Bind public rollout verification to an approved immutable edge image.

The existing memql-verify command checks public health, versions, OS assets and
optional docs. This wrapper first binds its served bundle manifest to the one
inside the pinned edge image. It uses anonymous registry reads, never cluster
credentials, and retains a typed receipt on failure as well as success.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


MAX_MANIFEST = 2 << 20
MAX_ARCHIVE = 2 << 30
MANIFEST_PATH = 'app/os/memql-bundle.json'
DIGEST_IMAGE = re.compile(r'[a-z0-9][a-z0-9.:-]*/[a-z0-9][a-z0-9._/-]*@sha256:[a-f0-9]{64}')


class Refused(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def manifest(data):
    if len(data) > MAX_MANIFEST:
        raise Refused('rollout_bundle_too_large')
    try:
        def require(condition):
            if not condition:
                raise ValueError('invalid bundle manifest')
        def unique(pairs):
            result = {}
            for key, value in pairs:
                require(key not in result)
                result[key] = value
            return result
        value = json.loads(data, object_pairs_hook=unique)
        require(isinstance(value, dict) and set(value) == {'schema', 'algorithm', 'files'})
        require(type(value['schema']) is int and value['schema'] == 1 and value['algorithm'] == 'sha256')
        files = value['files']
        require(isinstance(files, dict) and 1 <= len(files) <= 4096)
        require('index.html' in files)
        for path, digest in files.items():
            require(isinstance(path, str) and path and not path.startswith('/'))
            require('\\' not in path and '%' not in path and '?' not in path and '#' not in path)
            require(all(part not in ('', '.', '..') for part in path.split('/')))
            require(all(ord(c) >= 32 and ord(c) != 127 for c in path))
            require(not path.startswith('_memql/'))
            require(isinstance(digest, str) and re.fullmatch('[a-f0-9]{64}', digest))
        return value
    except (ValueError, KeyError, TypeError, RecursionError):
        raise Refused('rollout_bundle_invalid') from None


def image_manifest(archive):
    found = None
    try:
        if Path(archive).stat().st_size > MAX_ARCHIVE:
            raise Refused('rollout_image_too_large')
        with tarfile.open(archive, 'r:') as stream:
            for index, entry in enumerate(stream):
                if index >= 100000:
                    raise Refused('rollout_image_too_large')
                path = entry.name.removeprefix('./').removeprefix('/')
                if path != MANIFEST_PATH:
                    continue
                if found is not None or not entry.isfile() or entry.size > MAX_MANIFEST:
                    raise Refused('rollout_image_manifest_invalid')
                found = manifest(stream.extractfile(entry).read(MAX_MANIFEST + 1))
    except (tarfile.TarError, OSError):
        raise Refused('rollout_image_invalid') from None
    if found is None:
        raise Refused('rollout_image_manifest_missing')
    return found


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def public_manifest(origin, timeout):
    request = urllib.request.Request(origin + '/memql-bundle.json', headers={
        'User-Agent': 'memql-verify-image', 'Cache-Control': 'no-cache',
    })
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=timeout) as response:
            if response.status != 200:
                raise Refused('rollout_bundle_unreported')
            return manifest(response.read(MAX_MANIFEST + 1))
    except urllib.error.HTTPError as error:
        code = 'rollout_redirect_refused' if 300 <= error.code < 400 else 'rollout_bundle_unreported'
        raise Refused(code) from None
    except (OSError, urllib.error.URLError):
        raise Refused('rollout_unreachable') from None


def canonical_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def wait_for_manifest(expected, origin, deadline, fetch=public_manifest, now=time.monotonic, sleep=time.sleep):
    failure = Refused('rollout_bundle_mismatch')
    while True:
        remaining = deadline - now()
        if remaining <= 0:
            raise failure
        try:
            observed = fetch(origin, min(20, remaining))
            if observed == expected:
                return canonical_digest(observed)
            failure = Refused('rollout_bundle_mismatch')
        except Refused as error:
            failure = error
        remaining = deadline - now()
        if remaining <= 0:
            raise failure
        sleep(min(10, remaining))


def image_file_limit():
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_ARCHIVE, MAX_ARCHIVE))


def verify(args):
    # Registry credentials and credential-helper configuration are deliberately
    # absent. Public engine images need neither Kubernetes nor operator auth.
    deadline = time.monotonic() + args.wait_seconds
    report = {'formatVersion': 1, 'verified': False, 'code': 'rollout_unverified',
              'version': args.version, 'edgeImage': args.edge_image, 'osOrigin': args.os_origin}
    try:
        with tempfile.TemporaryDirectory(prefix='memql-rollout-') as directory:
            root = Path(directory)
            archive = root / 'edge.tar'
            environment = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'DOCKER_CONFIG': directory}
            try:
                subprocess.run([args.crane, 'export', args.edge_image, str(archive)],
                    env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=min(180, args.wait_seconds),
                    preexec_fn=image_file_limit, check=True)
            except (OSError, subprocess.SubprocessError):
                raise Refused('rollout_image_unreadable') from None
            expected = image_manifest(archive)
            archive.unlink()
            report['bundleManifestSHA256'] = wait_for_manifest(expected, args.os_origin, deadline)
            child_evidence = root / 'public.json'
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Refused('rollout_unverified')
            command = [args.verifier, '--domain=' + args.domain, '--version=' + args.version,
                       '--samples=6', '--wait=' + str(int(remaining)) + 's',
                       '--evidence=' + str(child_evidence), '--os-url=' + args.os_origin]
            if args.docs:
                command.append('--docs=' + args.docs)
            try:
                result = subprocess.run(command, stdin=subprocess.DEVNULL,
                    env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=remaining)
                if child_evidence.exists() and child_evidence.stat().st_size <= MAX_MANIFEST:
                    child = json.loads(child_evidence.read_text())
                    if not isinstance(child, dict):
                        raise Refused('rollout_verifier_incomplete')
                    report['public'] = child
                if result.returncode != 0 or report.get('public', {}).get('verified') is not True:
                    raise Refused('rollout_unverified')
            except (OSError, ValueError, RecursionError, subprocess.SubprocessError):
                raise Refused('rollout_verifier_incomplete') from None
            remaining = deadline - time.monotonic()
            if remaining <= 0 or public_manifest(args.os_origin, min(20, remaining)) != expected:
                raise Refused('rollout_changed_during_verification')
            report.update(verified=True, code='rollout_verified')
    except Refused as error:
        report['code'] = error.code
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'verified': report['verified'], 'code': report['code'], 'evidence': str(args.evidence)}))
    return 0 if report['verified'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--edge-image', required=True)
    parser.add_argument('--domain', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--os-origin', required=True)
    parser.add_argument('--verifier', required=True)
    parser.add_argument('--crane', required=True)
    parser.add_argument('--docs', default='')
    parser.add_argument('--wait-seconds', type=int, default=900)
    parser.add_argument('--evidence', type=Path, default=Path('verify-rollout.json'))
    args = parser.parse_args()
    try:
        origin = urllib.parse.urlsplit(args.os_origin)
        docs = urllib.parse.urlsplit(args.docs)
    except ValueError:
        parser.error('invalid public URL')
    if not DIGEST_IMAGE.fullmatch(args.edge_image):
        parser.error('--edge-image requires an immutable registry/repository@sha256:digest')
    if origin.scheme != 'https' or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment or origin.path not in ('', '/'):
        parser.error('--os-origin requires one HTTPS origin')
    if not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?', args.domain):
        parser.error('--domain requires a bare host name')
    if not re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.+-]+)?|[a-f0-9]{7,40}', args.version):
        parser.error('--version requires a release version or commit')
    if args.docs and (docs.scheme != 'https' or not docs.hostname or docs.username or docs.password or docs.fragment):
        parser.error('--docs requires an HTTPS page without credentials or a fragment')
    if not 1 <= args.wait_seconds <= 3600:
        parser.error('--wait-seconds must be within 1..3600')
    args.os_origin = args.os_origin.rstrip('/')
    return verify(args)


if __name__ == '__main__':
    raise SystemExit(main())
