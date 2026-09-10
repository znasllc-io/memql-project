#!/usr/bin/env python3
"""Argo deployment events -> verified composition -> durable Discord outbox.

No shell execution, cluster mutations, arbitrary diagnostics or response bodies
enter notifications. Kubernetes access is read-only. State is local SQLite.
"""
import argparse
import datetime as dt
import hashlib
import html.parser
import json
import os
import queue
import re
import sqlite3
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def fingerprint(value):
    return hashlib.sha256(encode(value).encode()).hexdigest()


def utc(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()


def epoch(value):
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


class SafeFailure(Exception):
    """Only constant reason codes and Kubernetes resource names are allowed."""


class API:
    def __init__(self):
        self.base = 'https://' + os.environ['KUBERNETES_SERVICE_HOST'] + ':' + os.environ.get('KUBERNETES_SERVICE_PORT', '443')
        self.directory = '/var/run/secrets/kubernetes.io/serviceaccount/'
        self.tls = ssl.create_default_context(cafile=self.directory + 'ca.crt')

    def open(self, path, timeout=30):
        # Read each time: projected service-account tokens rotate.
        with open(self.directory + 'token') as stream:
            token = stream.read().strip()
        request = urllib.request.Request(self.base + path, headers={'Authorization': 'Bearer ' + token})
        return urllib.request.urlopen(request, context=self.tls, timeout=timeout)

    def get(self, path):
        try:
            with self.open(path) as response:
                return json.load(response)
        except Exception:
            raise SafeFailure('kubernetes-read-unavailable') from None


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, value TEXT NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, payload TEXT NOT NULL, sent INTEGER DEFAULT 0, attempts INTEGER DEFAULT 0, next REAL DEFAULT 0)')
        self.db.commit()

    def load(self):
        row = self.db.execute('SELECT value FROM state WHERE id=1').fetchone()
        return json.loads(row[0]) if row else None

    def save(self, state, notices):
        # Incident transition and enqueue are one transaction, including restart.
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO state VALUES (1, ?)', (encode(state),))
            for key, payload in notices:
                self.db.execute('INSERT OR IGNORE INTO outbox(id,payload) VALUES (?,?)', (key, encode(payload)))

    def deliver(self, sender, now):
        # Ordered outbox: never deliver recovery before the preceding incident.
        row = self.db.execute('SELECT id,payload,attempts,next FROM outbox WHERE sent=0 ORDER BY rowid LIMIT 1').fetchone()
        if not row or row[3] > now:
            return
        key, payload, attempts, _ = row
        delay = sender(json.loads(payload))
        with self.db:
            if delay is None:
                self.db.execute('UPDATE outbox SET sent=1 WHERE id=?', (key,))
            else:
                self.db.execute('UPDATE outbox SET attempts=?,next=? WHERE id=?', (attempts + 1, now + max(delay, min(300, 2 ** min(attempts + 1, 8))), key))
                print(encode({'event': 'delivery-pending', 'id': key, 'attempts': attempts + 1}), flush=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Discord:
    def __init__(self, secret_file):
        self.secret_file = secret_file
        self.opener = urllib.request.build_opener(NoRedirect)

    def __call__(self, payload):
        try:
            with open(self.secret_file) as stream:
                url = stream.read().strip()
            parsed = urllib.parse.urlsplit(url)
            if parsed.scheme != 'https' or parsed.hostname != 'discord.com' or not re.fullmatch(r'/api/webhooks/[0-9]+/[A-Za-z0-9_-]+', parsed.path):
                return 300
            url = urllib.parse.urlunsplit(parsed._replace(query='wait=true'))
            request = urllib.request.Request(url, data=encode(payload).encode(), headers={'Content-Type': 'application/json', 'User-Agent': 'MemQL-Deployment-Observer/1'})
            with self.opener.open(request, timeout=15) as response:
                if response.status != 200:
                    return 60
                # Consume confirmation without ever printing webhook URL/body.
                result = json.load(response)
                return None if result.get('id') else 60
        except urllib.error.HTTPError as error:
            if error.code == 429:
                try:
                    return min(3600, max(1, float(json.loads(error.read(4096)).get('retry_after', 60))))
                except Exception:
                    return 60
            return 300 if 400 <= error.code < 500 else 30
        except Exception:
            return 30


def attempt(apps):
    return fingerprint([[a.get('metadata', {}).get('uid'), a.get('status', {}).get('operationState', {}).get('startedAt')] for a in apps])


def snapshot_key(apps):
    # Exclude notification/refresh annotations and resourceVersion churn.
    return fingerprint([[a.get('metadata', {}).get('uid'), a.get('spec', {}).get('source'), a.get('operation'), a.get('status', {}).get('sync'), a.get('status', {}).get('health'), a.get('status', {}).get('operationState'), a.get('status', {}).get('conditions')] for a in apps])


def classify(apps, now, limits):
    for app in apps:
        name = app['metadata']['name']
        status = app.get('status', {})
        operation = status.get('operationState', {})
        phase = operation.get('phase')
        if phase in ('Failed', 'Error'):
            return phase.lower(), name + ': operation-' + phase.lower(), 0
    for app in apps:
        name = app['metadata']['name']
        status = app.get('status', {})
        operation = status.get('operationState', {})
        phase = operation.get('phase')
        started = epoch(operation.get('startedAt'))
        if phase in ('Running', 'Terminating') and started is not None and now - started >= limits['stalled']:
            return 'stalled', name + ': operation-still-active', 0
        health = status.get('health', {}).get('status')
        if health == 'Degraded':
            return 'degraded', name + ': health-degraded', limits['degraded']
        if health in ('Unknown', 'Missing') or status.get('sync', {}).get('status') == 'Unknown' or any(c.get('type') in ('ComparisonError', 'SyncError', 'InvalidSpecError') for c in status.get('conditions', [])):
            return 'anomalous', name + ': reconciliation-unverified', limits['anomalous']
    ready = all(a.get('status', {}).get('operationState', {}).get('phase') == 'Succeeded' and a.get('status', {}).get('health', {}).get('status') == 'Healthy' and a.get('status', {}).get('sync', {}).get('status') == 'Synced' and not a.get('operation') for a in apps)
    return ('ready', 'composition-awaiting-verification', 0) if ready else ('pending', 'composition-not-ready', 0)


def overview_version(state, config=None):
    # Prefer the cut engine release from instance config (same value as ENGINE_REF),
    # e.g. v0.21.7. Operators cut SemVer releases; the Argo SHA is not the product version.
    config = config or {}
    configured = config.get('version')
    if isinstance(configured, str):
        configured = configured.strip()
        # Accept v-prefixed SemVer (and simple pre-release / build suffixes).
        if re.fullmatch(r'v?\d+\.\d+\.\d+[0-9A-Za-z.+-]*', configured):
            return configured if configured.startswith('v') else 'v' + configured
    # Fallback: shared Argo sync revision only when every tracked app agrees.
    revisions = []
    for app in state.get('apps') or []:
        revision = (app.get('status') or {}).get('sync', {}).get('revision') or ''
        if revision and revision != 'unknown':
            revisions.append(revision)
    unique = set(revisions)
    if len(unique) != 1 or len(revisions) != len(state.get('apps') or []):
        return 'unknown'
    revision = next(iter(unique))
    return revision[:7] if len(revision) > 7 else revision


def overview_os_link(config):
    links = config.get('links') or {}
    url = links.get('MemQL OS')
    if not isinstance(url, str) or not url.strip():
        return None
    url = url.strip()
    if not url.startswith('https://'):
        return None
    return '[Open](' + url + ')'


def message(config, state, kind, reason, now, evidence=None):
    labels = {'success': 'Deployment complete', 'recovery': 'Deployment recovered', 'failed': 'Deployment failed', 'error': 'Deployment needs attention', 'degraded': 'Service health degraded', 'stalled': 'Deployment taking longer than expected', 'anomalous': 'Deployment needs attention', 'unverified': 'Deployment not yet verified'}
    descriptions = {
        'success': 'Production is up to date. Rollout and public checks passed.',
        'recovery': 'The deployment issue has cleared. Rollout and public checks passed.',
        'failed': 'A deployment step failed. Review the deployment before retrying.',
        'error': 'A deployment error needs attention.',
        'degraded': 'A service is reporting unhealthy. Please review the deployment.',
        'stalled': 'The rollout is still in progress and taking longer than expected.',
        'anomalous': 'Deployment status could not be confirmed. Please review it.',
        'unverified': 'Some deployment checks are still incomplete. Success is not confirmed.',
    }
    colors = {'success': 3066993, 'recovery': 3066993, 'failed': 15158332, 'error': 15158332}
    # Detailed evidence stays in state; Discord is a short overview.
    fields = [{'name': 'Version', 'value': overview_version(state, config)}]
    os_link = overview_os_link(config)
    if os_link:
        fields.append({'name': 'MemQL OS', 'value': os_link})
    fields.append({'name': 'Deployment details', 'value': 'Coming soon in MemQL OS.'})
    embed = {
        'title': config['instance'][:100] + ' · ' + labels[kind],
        'description': descriptions[kind],
        'color': colors.get(kind, 15105570),
        'fields': fields,
        'timestamp': utc(now),
    }
    return {'username': 'MemQL Deployments', 'allowed_mentions': {'parse': []}, 'embeds': [embed]}


class Reducer:
    def __init__(self, config, store):
        self.config, self.store = config, store
        self.limits = {'stalled': 900, 'degraded': 120, 'anomalous': 300, 'unverified': 600, **config.get('thresholds', {})}

    def step(self, apps, now, verify):
        identity = attempt(apps)
        state = self.store.load()
        if state is None:
            # Baseline historical healthy operations quietly. Activation is not a deploy.
            state = {'attempt': identity, 'started': now, 'baseline': True, 'done': True, 'incident': None, 'sequence': 0, 'condition': None}
        elif identity != state['attempt']:
            initial_discovery = state.get('baseline') and not state.get('incident') and any(a['metadata'].get('uid', '').startswith('missing-') for a in state.get('apps', []))
            starts = [epoch(a.get('status', {}).get('operationState', {}).get('startedAt')) for a in apps]
            state.update(attempt=identity, started=max([s for s in starts if s is not None] or [now]), baseline=initial_discovery, done=initial_discovery, condition=None, unverified=False)
        if state.get('baseline') and any(a.get('status', {}).get('operationState', {}).get('phase') in ('Running', 'Terminating') for a in apps):
            state.update(baseline=False, done=False)
        state['apps'] = [{'metadata': {'name': a['metadata']['name'], 'uid': a['metadata'].get('uid')}, 'spec': {'source': {'repoURL': a.get('spec', {}).get('source', {}).get('repoURL', '')}}, 'status': {'sync': {'revision': a.get('status', {}).get('sync', {}).get('revision', 'unknown')}}} for a in apps]
        kind, reason, delay = classify(apps, now, self.limits)
        notices = []
        def emit(event, why, evidence=None):
            state['sequence'] += 1
            key = fingerprint([self.config['instance'], state['sequence'], identity, event])
            notices.append((key, message(self.config, state, event, why, now, evidence)))
        if kind in ('failed', 'error', 'stalled', 'degraded', 'anomalous'):
            condition = kind + ':' + reason
            if state.get('condition') != condition:
                state.update(condition=condition, since=now, alerted=False)
            if now - state['since'] >= delay and not state.get('alerted'):
                if not state.get('incident'):
                    state['incident'] = fingerprint([identity, now, state['sequence']])
                emit(kind, reason)
                state.update(alerted=True, done=False)
        elif kind == 'ready':
            # A cleared condition is re-armed even at the same source revision.
            state.update(condition=None, alerted=False)
            if not state['done'] or state.get('incident'):
                try:
                    evidence = verify(apps)
                except SafeFailure as error:
                    reason = str(error)
                    if now - state['started'] >= self.limits['unverified'] and not state.get('unverified'):
                        state['incident'] = state.get('incident') or fingerprint([identity, now, 'verification'])
                        emit('unverified', reason)
                        state['unverified'] = True
                else:
                    state['evidence'] = evidence
                    emit('recovery' if state.get('incident') else 'success', 'composition-and-probes-passed', evidence)
                    state.update(done=True, incident=None, unverified=False, baseline=False)
        else:
            state.update(condition=None, alerted=False)
            # Manual-sync pending changes alone never start an attempt.
            if not state['done'] and now - state['started'] >= self.limits['unverified'] and not state.get('unverified'):
                state['incident'] = state.get('incident') or fingerprint([identity, now, 'pending'])
                emit('unverified', reason)
                state['unverified'] = True
        self.store.save(state, notices)
        return notices


class Assets(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'script' and attrs.get('src'):
            self.paths.append(attrs['src'])
        if tag == 'link' and attrs.get('rel') in ('stylesheet', 'modulepreload') and attrs.get('href'):
            self.paths.append(attrs['href'])


def probe(spec):
    opener = urllib.request.build_opener(NoRedirect)
    headers = {}
    if spec.get('bearer_file'):
        with open(spec['bearer_file']) as stream:
            headers['Authorization'] = 'Bearer ' + stream.read().strip()
    def fetch(url, expected, contains=None, send_auth=False):
        if urllib.parse.urlsplit(url).scheme != 'https':
            raise SafeFailure('probe-requires-https')
        request = urllib.request.Request(url, headers=headers if send_auth else {})
        try:
            with opener.open(request, timeout=10) as response:
                data = response.read(2_000_001)
                if response.status != expected or len(data) > 2_000_000:
                    raise SafeFailure('probe-response-invalid')
                if contains and contains.encode() not in data:
                    raise SafeFailure('probe-content-mismatch')
                return data
        except urllib.error.HTTPError as error:
            if error.code == expected and not contains:
                return b''
            raise SafeFailure('probe-http-failed') from None
        except SafeFailure:
            raise
        except Exception:
            raise SafeFailure('probe-transport-failed') from None
    if spec.get('bearer_file'):
        fetch(spec['url'], spec.get('unauthenticated_status', 401))
    body = fetch(spec['url'], spec.get('status', 200), spec.get('contains'), True)
    if 'json_equals' in spec:
        try:
            data = json.loads(body)
            for dotted, expected in spec['json_equals'].items():
                value = data
                for part in dotted.split('.'):
                    value = value[part]
                if value != expected:
                    raise ValueError()
        except Exception:
            raise SafeFailure('probe-functional-mismatch') from None
    if spec.get('assets'):
        parser = Assets()
        parser.feed(body.decode('utf-8'))
        if not parser.paths or len(parser.paths) > 40:
            raise SafeFailure('probe-os-assets-missing')
        for path in parser.paths:
            url = urllib.parse.urljoin(spec['url'], path)
            if urllib.parse.urlsplit(url).netloc != urllib.parse.urlsplit(spec['url']).netloc:
                raise SafeFailure('probe-cross-origin-asset')
            data = fetch(url, 200)
            if not data or b'<html' in data[:512].lower() or b'<!doctype html' in data[:512].lower():
                raise SafeFailure('probe-asset-returned-html')


def workload_images(api, namespace, resource):
    kind, name = resource['kind'], resource['name']
    plural = {'Deployment': 'deployments', 'StatefulSet': 'statefulsets', 'DaemonSet': 'daemonsets'}[kind]
    obj = api.get('/apis/apps/v1/namespaces/' + namespace + '/' + plural + '/' + name)
    spec, status = obj['spec'], obj.get('status', {})
    if status.get('observedGeneration', 0) < obj['metadata']['generation']:
        raise SafeFailure(name + ': controller-generation-pending')
    desired = spec.get('replicas', 1) if kind != 'DaemonSet' else status.get('desiredNumberScheduled', 0)
    ready = status.get('readyReplicas', 0) if kind != 'DaemonSet' else status.get('numberReady', 0)
    updated = status.get('updatedReplicas', 0) if kind != 'DaemonSet' else status.get('updatedNumberScheduled', 0)
    if desired < 0 or ready != desired or updated != desired:
        raise SafeFailure(name + ': rollout-not-ready')
    if desired > 0 and kind == 'StatefulSet' and status.get('currentRevision') != status.get('updateRevision'):
        raise SafeFailure(name + ': statefulset-revision-pending')
    template = spec['template']['spec']
    applied = obj['metadata'].get('annotations', {}).get('kubectl.kubernetes.io/last-applied-configuration')
    try:
        applied_spec = json.loads(applied)['spec']
        intended = applied_spec['template']['spec']
    except Exception:
        raise SafeFailure(name + ': applied-manifest-evidence-missing') from None
    for key in ('containers', 'initContainers'):
        if {c['name']: c['image'] for c in template.get(key, [])} != {c['name']: c['image'] for c in intended.get(key, [])}:
            raise SafeFailure(name + ': image-drift-from-applied-manifest')
    expected = {c['name']: c['image'] for key in ('containers', 'initContainers') for c in template.get(key, [])}
    if any(not re.search(r'@sha256:[a-f0-9]{64}$', image) for image in expected.values()):
        raise SafeFailure(name + ': image-not-digest-pinned')
    selector = spec['selector']
    if selector.get('matchExpressions'):
        raise SafeFailure(name + ': selector-expressions-unverified')
    labels = ','.join(k + '=' + v for k, v in selector['matchLabels'].items())
    pods = api.get('/api/v1/namespaces/' + namespace + '/pods?' + urllib.parse.urlencode({'labelSelector': labels}))['items']
    if desired == 0:
        if kind == 'DaemonSet' or applied_spec.get('replicas', 1) != 0 or pods or status.get('replicas', 0) != 0:
            raise SafeFailure(name + ': scale-zero-evidence-mismatch')
        return [], []  # Deliberately disabled workload; no running image claim.
    pods = [p for p in pods if not p['metadata'].get('deletionTimestamp')]
    if len(pods) != desired:
        raise SafeFailure(name + ': pod-count-mismatch')
    runtime = []
    for pod in pods:
        ps = pod.get('status', {})
        if not any(c.get('type') == 'Ready' and c.get('status') == 'True' for c in ps.get('conditions', [])):
            raise SafeFailure(name + ': pod-not-ready')
        actual = {c['name']: c['image'] for key in ('containers', 'initContainers') for c in pod['spec'].get(key, [])}
        if actual != expected:
            raise SafeFailure(name + ': pod-image-mismatch')
        containers = ps.get('containerStatuses', []) + ps.get('initContainerStatuses', [])
        if {c['name'] for c in containers} != set(expected):
            raise SafeFailure(name + ': runtime-evidence-missing')
        for container in containers:
            image_id = container.get('imageID', '')
            if not re.search(r'sha256:[a-f0-9]{64}$', image_id):
                raise SafeFailure(name + ': runtime-image-unverified')
            runtime.append({'pod': pod['metadata']['name'], 'container': container['name'], 'requested': expected[container['name']], 'runtime': image_id, 'generation': obj['metadata']['generation'], 'pod_uid': pod['metadata']['uid']})
    return sorted(set(expected.values())), runtime


def verify_composition(config, api, apps, read_apps):
    if classify(apps, time.time(), {'stalled': 900, 'degraded': 120, 'anomalous': 300})[0] != 'ready':
        raise SafeFailure('composition-not-ready')
    # One instance repository, two applications: equality rules out the common
    # engine-first intermediate state. Different repositories require an explicit
    # composition plan and are intentionally refused by this implementation.
    revisions = {a['status']['sync'].get('revision') for a in apps}
    repositories = {a['spec']['source'].get('repoURL') for a in apps}
    if len(revisions) != 1 or not all(revisions) or len(repositories) != 1:
        raise SafeFailure('composition-source-mismatch')
    evidence = {'images': {}, 'runtime': [], 'probes': [], 'services': []}
    for app in apps:
        resources = [r for r in app['status'].get('resources', []) if r.get('kind') in ('Deployment', 'StatefulSet', 'DaemonSet')]
        if not resources:
            raise SafeFailure('composition-workloads-missing')
        images = []
        for resource in resources:
            if resource.get('namespace') != config['workload_namespace']:
                raise SafeFailure('composition-namespace-mismatch')
            found, runtime = workload_images(api, config['workload_namespace'], resource)
            evidence['services'].append(resource['kind'] + '/' + resource['name'] + (' (scaled to zero)' if not found else ''))
            images.extend(found)
            evidence['runtime'].extend(runtime)
        evidence['images'][config['applications'][app['metadata']['name']]] = sorted(set(images))
    probes = list(config.get('probes', []))
    if config.get('functional_probe_file'):
        try:
            with open(config['functional_probe_file']) as stream:
                probes.append(json.load(stream))
        except Exception:
            raise SafeFailure('functional-probe-credential-or-contract-missing') from None
    if not probes or not any(p.get('assets') for p in probes):
        raise SafeFailure('os-probe-not-configured')
    for spec in probes:
        try:
            probe(spec)
        except SafeFailure as error:
            raise SafeFailure(spec['name'] + ': ' + str(error)) from None
        except Exception:
            raise SafeFailure(spec['name'] + ': probe-configuration-unavailable') from None
        evidence['probes'].append(spec['name'])
    second_runtime = []
    for app in apps:
        for resource in app['status'].get('resources', []):
            if resource.get('kind') in ('Deployment', 'StatefulSet', 'DaemonSet'):
                _, runtime = workload_images(api, config['workload_namespace'], resource)
                second_runtime.extend(runtime)
    ordered = lambda rows: sorted(encode(row) for row in rows)
    if ordered(second_runtime) != ordered(evidence['runtime']):
        raise SafeFailure('workloads-changed-during-verification')
    if snapshot_key(read_apps()) != snapshot_key(apps):
        raise SafeFailure('composition-changed-during-verification')
    return evidence


def watch(api, path, events):
    while True:
        try:
            listing = api.get(path)
            events.put(('snapshot', listing['items']))
            revision = listing['metadata']['resourceVersion']
            query = urllib.parse.urlencode({'watch': 'true', 'resourceVersion': revision, 'timeoutSeconds': 300, 'allowWatchBookmarks': 'true'})
            with api.open(path + '?' + query, timeout=330) as response:
                for line in response:
                    event = json.loads(line)
                    if event['type'] == 'ERROR':
                        break  # includes expired resourceVersion (410): relist
                    if event['type'] != 'BOOKMARK':
                        events.put(('change', event))
        except Exception:
            events.put(('unavailable', None))
            time.sleep(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--state', default='/state/notifications.sqlite')
    args = parser.parse_args()
    with open(args.config) as stream:
        config = json.load(stream)
    if len(config['applications']) != 2 or set(config['applications'].values()) != {'engine', 'product'}:
        raise SystemExit('configuration must name engine and product Applications')
    api, store = API(), Store(args.state)
    path = '/apis/argoproj.io/v1alpha1/namespaces/' + config['argo_namespace'] + '/applications'
    def read_apps():
        return [api.get(path + '/' + name) for name in sorted(config['applications'])]
    events = queue.Queue(maxsize=1000)
    threading.Thread(target=watch, args=(api, path, events), daemon=True).start()
    reducer, sender = Reducer(config, store), Discord(config['webhook_file'])
    cached, last_key, next_verify = {}, None, 0
    unavailable_since = None
    while True:
        now = time.time()
        try:
            kind, value = events.get(timeout=5)
            if kind == 'snapshot':
                cached = {a['metadata']['name']: a for a in value if a['metadata']['name'] in config['applications']}
                unavailable_since = None
            elif kind == 'change':
                obj = value['object']
                name = obj['metadata']['name']
                if name in config['applications']:
                    if value['type'] == 'DELETED':
                        cached.pop(name, None)
                    else:
                        cached[name] = obj
            elif kind == 'unavailable':
                unavailable_since = unavailable_since or now
                print(encode({'event': 'application-watch-unavailable'}), flush=True)
        except queue.Empty:
            pass
        apps = []
        for name in sorted(config['applications']):
            app = json.loads(encode(cached.get(name, {'metadata': {'name': name, 'uid': 'missing-' + name}, 'status': {}})))
            if name not in cached:
                app.setdefault('status', {})['health'] = {'status': 'Missing'}
            elif unavailable_since is not None:
                app.setdefault('status', {})['health'] = {'status': 'Unknown'}
            apps.append(app)
        key = snapshot_key(apps)
        state = store.load()
        active = state is not None and (not state['done'] or state.get('condition') or state.get('incident'))
        if key != last_key or (active and now >= next_verify):
            def verify(current):
                return verify_composition(config, api, current, read_apps)
            reducer.step(apps, now, verify)
            last_key = key
            state = store.load()
            next_verify = now + (300 if state.get('unverified') else 30)
        store.deliver(sender, now)
        pending = store.db.execute('SELECT COUNT(*) FROM outbox WHERE sent=0').fetchone()[0]
        with open(os.path.join(os.path.dirname(args.state), 'health.json'), 'w') as stream:
            json.dump({'loop': time.time(), 'pending': pending}, stream)


if __name__ == '__main__':
    main()
