import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

source = pathlib.Path(__file__).resolve().parents[2] / 'deploy/notifications/observer.py'
spec = importlib.util.spec_from_file_location('observer', source)
o = importlib.util.module_from_spec(spec)
spec.loader.exec_module(o)


def apps(start='2026-09-09T00:00:00Z'):
    return [{'metadata': {'name': name, 'uid': name}, 'spec': {'source': {'repoURL': 'https://github.com/test/instance.git'}}, 'status': {'operationState': {'phase': 'Succeeded', 'startedAt': start}, 'health': {'status': 'Healthy'}, 'sync': {'status': 'Synced', 'revision': 'a' * 40}}} for name in ('engine', 'product')]


class Transitions(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = o.Store(self.directory.name + '/state.sqlite')
        self.config = {'instance': 'example', 'cluster': 'example-cluster', 'applications': {'engine': 'engine', 'product': 'product'}, 'thresholds': {'degraded': 2, 'anomalous': 5, 'stalled': 15, 'unverified': 10}, 'links': {'MemQL OS': 'https://os.example.invalid/'}}
        self.reducer = o.Reducer(self.config, self.store)
        self.now = o.epoch('2026-09-09T00:00:00Z')
        self.current = apps()
        self.calls = 0
        self.reducer.step(self.current, self.now, self.verify)

    def tearDown(self):
        self.store.db.close()
        self.directory.cleanup()

    def verify(self, _):
        self.calls += 1
        return {'images': {'engine': ['engine@sha256:' + 'a' * 64], 'product': ['product@sha256:' + 'b' * 64]}, 'probes': ['os', 'functional']}

    def step(self, seconds=0, verify=None):
        return self.reducer.step(self.current, self.now + seconds, verify or self.verify)

    def deploy(self):
        self.current[0]['status']['operationState']['startedAt'] = '2026-09-09T00:00:01Z'

    def test_activation_and_publish_are_quiet(self):
        self.assertEqual(self.step(), [])
        for a in self.current:
            a['status']['sync']['revision'] = 'b' * 40
        self.assertEqual(self.step(1), [])
        self.assertEqual(self.calls, 0)

    def test_success_once_and_same_revision_retry(self):
        self.deploy()
        self.assertEqual(len(self.step(2)), 1)
        self.assertEqual(self.step(3), [])
        self.current[0]['status']['operationState']['startedAt'] = '2026-09-09T00:00:04Z'
        self.assertEqual(len(self.step(5)), 1)

    def test_failed_and_error_distinct_without_probe(self):
        self.deploy()
        self.current[0]['status']['operationState']['phase'] = 'Failed'
        self.assertEqual(len(self.step(2)), 1)
        self.assertEqual(self.step(3), [])
        self.current[0]['status']['operationState']['phase'] = 'Error'
        self.assertEqual(len(self.step(4)), 1)
        self.assertEqual(self.calls, 0)

    def test_degraded_debounce_then_recovery_and_second_incident(self):
        self.current[0]['status']['health']['status'] = 'Degraded'
        self.assertEqual(self.step(1), [])
        self.assertEqual(len(self.step(3)), 1)
        self.assertEqual(self.step(4), [])
        self.current[0]['status']['health']['status'] = 'Healthy'
        notice = self.step(5)[0][1]
        self.assertIn('recovered', notice['embeds'][0]['title'])
        self.current[0]['status']['health']['status'] = 'Degraded'
        self.step(6)
        self.assertEqual(len(self.step(8)), 1)

    def test_transient_degraded_does_not_send_recovery(self):
        self.current[0]['status']['health']['status'] = 'Degraded'
        self.step(1)
        self.current[0]['status']['health']['status'] = 'Healthy'
        self.assertEqual(self.step(2), [])

    def test_stall_terminal_failure_and_later_recovery(self):
        self.deploy()
        self.current[0]['status']['operationState']['phase'] = 'Running'
        self.assertEqual(self.step(2), [])
        self.assertEqual(len(self.step(16)), 1)
        self.current[0]['status']['operationState']['phase'] = 'Failed'
        self.assertEqual(len(self.step(17)), 1)
        self.current[0]['status']['operationState']['phase'] = 'Succeeded'
        self.assertIn('recovered', self.step(18)[0][1]['embeds'][0]['title'])

    def test_verifier_error_never_success_then_recovers(self):
        self.deploy()
        def bad(_):
            raise o.SafeFailure('os: probe-content-mismatch')
        self.assertEqual(self.step(2, bad), [])
        self.assertEqual(len(self.step(12, bad)), 1)
        self.assertEqual(self.step(13, bad), [])
        self.assertIn('recovered', self.step(14)[0][1]['embeds'][0]['title'])

    def test_new_attempt_rearms_unverified(self):
        self.deploy()
        self.current[0]['status']['health']['status'] = 'Progressing'
        self.step(12)
        self.current[0]['status']['operationState']['startedAt'] = '2026-09-09T00:00:13Z'
        self.assertEqual(len(self.step(24)), 1)

    def test_restart_keeps_dedup_and_outbox_order(self):
        self.deploy()
        self.current[0]['status']['operationState']['phase'] = 'Failed'
        self.step(2)
        self.reducer = o.Reducer(self.config, self.store)
        self.assertEqual(self.step(3), [])
        self.current[0]['status']['operationState']['phase'] = 'Succeeded'
        self.step(4)
        delivered = []
        self.store.deliver(lambda p: delivered.append(p), self.now + 5)
        self.store.deliver(lambda p: delivered.append(p), self.now + 6)
        self.assertIn('failed', delivered[0]['embeds'][0]['title'])
        self.assertIn('recovered', delivered[1]['embeds'][0]['title'])

    def test_retry_does_not_release_next_message(self):
        self.deploy()
        self.current[0]['status']['operationState']['phase'] = 'Failed'
        self.step(2)
        self.store.deliver(lambda _: 60, self.now + 3)
        self.current[0]['status']['operationState']['phase'] = 'Succeeded'
        self.step(4)
        delivered = []
        self.store.deliver(lambda p: delivered.append(p), self.now + 5)
        self.assertEqual(delivered, [])

    def test_message_never_contains_diagnostic_or_mentions(self):
        self.deploy()
        self.current[0]['status']['operationState'].update(phase='Error', message='secret-token @everyone')
        notice = self.step(2)[0][1]
        self.assertNotIn('secret-token', json.dumps(notice))
        self.assertEqual(notice['allowed_mentions'], {'parse': []})

    def test_composition_mismatch_refuses(self):
        self.current[1]['status']['sync']['revision'] = 'b' * 40
        with self.assertRaisesRegex(o.SafeFailure, 'source-mismatch'):
            o.verify_composition(self.config, None, self.current, lambda: self.current)

    def test_missing_workload_refuses(self):
        with self.assertRaisesRegex(o.SafeFailure, 'workloads-missing'):
            o.verify_composition(self.config, None, self.current, lambda: self.current)

    def test_missing_app_is_anomaly(self):
        self.current[1]['status'] = {'health': {'status': 'Missing'}}
        self.step(1)
        self.assertEqual(len(self.step(6)), 1)

    def test_initial_running_attempt_is_not_baselined(self):
        fresh = o.Store(':memory:')
        self.current[0]['status']['operationState']['phase'] = 'Running'
        reducer = o.Reducer(self.config, fresh)
        reducer.step(self.current, self.now, self.verify)
        self.current[0]['status']['operationState']['phase'] = 'Succeeded'
        self.assertEqual(len(reducer.step(self.current, self.now + 2, self.verify)), 1)
        fresh.db.close()

    def test_message_overview_has_version_os_link_and_placeholder(self):
        self.deploy()
        notice = self.step(2)[0][1]
        fields = {f['name']: f['value'] for f in notice['embeds'][0]['fields']}
        self.assertEqual(list(fields), ['Version', 'MemQL OS', 'Deployment details'])
        self.assertEqual(fields['Version'], 'a' * 7)
        self.assertEqual(fields['MemQL OS'], '[Open](https://os.example.invalid/)')
        self.assertEqual(fields['Deployment details'], 'Coming soon in MemQL OS.')
        self.assertNotIn('sha256:', json.dumps(notice))

    def test_message_omits_os_link_when_unconfigured(self):
        del self.config['links']
        notice = o.message(self.config, {'apps': [{'status': {'sync': {'revision': 'abcdef0123456789'}}}]}, 'failed', 'x', self.now)
        names = [f['name'] for f in notice['embeds'][0]['fields']]
        self.assertEqual(names, ['Version', 'Deployment details'])

    def test_message_version_unknown_on_revision_mismatch(self):
        state = {'apps': [
            {'status': {'sync': {'revision': 'a' * 40}}},
            {'status': {'sync': {'revision': 'b' * 40}}},
        ]}
        notice = o.message(self.config, state, 'failed', 'x', self.now)
        fields = {f['name']: f['value'] for f in notice['embeds'][0]['fields']}
        self.assertEqual(fields['Version'], 'unknown')

    def test_message_examples_match_renderer(self):
        examples = json.loads((pathlib.Path(__file__).resolve().parents[2] / 'docs/design/deployment-notifications/message-examples.json').read_text())
        config = {'instance': 'ZNAS instance', 'links': {'MemQL OS': 'https://os.memql.znas.io/'}}
        state = {'apps': [{'status': {'sync': {'revision': 'a' * 40}}}, {'status': {'sync': {'revision': 'a' * 40}}}]}
        now = o.epoch('2026-09-09T16:13:12Z')
        for kind, expected in examples.items():
            self.assertEqual(o.message(config, state, kind, 'example', now), expected)


class ProbeChecks(unittest.TestCase):

    def test_assets_parser(self):
        parser = o.Assets()
        parser.feed('<html><script src="/assets/os.js"></script><link rel="stylesheet" href="/assets/os.css"></html>')
        self.assertEqual(parser.paths, ['/assets/os.js', '/assets/os.css'])

    def test_no_plaintext_or_redirect(self):
        with self.assertRaisesRegex(o.SafeFailure, 'requires-https'):
            o.probe({'url': 'http://example.com'})
        self.assertIsNone(o.NoRedirect().redirect_request(None, None, None, None, None, None))



class Verification(unittest.TestCase):
    def setUp(self):
        self.apps = apps()
        self.config = {'workload_namespace': 'memql', 'applications': {'engine': 'engine', 'product': 'product'}, 'probes': [{'name': 'os', 'assets': True}, {'name': 'functional', 'bearer_file': '/unused', 'json_equals': {'ok': True}}]}
        image = 'example/engine@sha256:' + 'a' * 64
        template = {'containers': [{'name': 'main', 'image': image}]}
        self.deployment = {'metadata': {'name': 'head', 'generation': 1, 'annotations': {'kubectl.kubernetes.io/last-applied-configuration': json.dumps({'spec': {'template': {'spec': template}}})}}, 'spec': {'replicas': 1, 'selector': {'matchLabels': {'app': 'head'}}, 'template': {'spec': copy.deepcopy(template)}}, 'status': {'observedGeneration': 1, 'readyReplicas': 1, 'updatedReplicas': 1}}
        self.pod = {'metadata': {'name': 'head-abc', 'uid': 'pod-uid'}, 'spec': copy.deepcopy(template), 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}], 'containerStatuses': [{'name': 'main', 'imageID': 'containerd://sha256:' + 'b' * 64}]}}
        for app in self.apps:
            app['status']['resources'] = [{'kind': 'Deployment', 'name': 'head', 'namespace': 'memql'}]
        outer = self
        class API:
            def get(self, path):
                return {'items': [outer.pod]} if '/pods?' in path else outer.deployment
        self.api = API()

    def verify(self, read=None):
        with patch.object(o, 'probe'):
            return o.verify_composition(self.config, self.api, self.apps, read or (lambda: self.apps))

    def test_positive_composition_and_multiarch_runtime_evidence(self):
        evidence = self.verify()
        self.assertEqual(set(evidence['images']), {'engine', 'product'})
        self.assertEqual(evidence['runtime'][0]['runtime'], 'containerd://sha256:' + 'b' * 64)

    def test_stale_source_after_probes_rejected(self):
        changed = copy.deepcopy(self.apps)
        changed[0]['status']['sync']['revision'] = 'c' * 40
        with self.assertRaisesRegex(o.SafeFailure, 'changed-during-verification'):
            self.verify(lambda: changed)

    def test_pod_replaced_during_probes_rejected(self):
        def mutate(_):
            self.pod['metadata']['uid'] = 'replacement'
        with patch.object(o, 'probe', side_effect=mutate):
            with self.assertRaisesRegex(o.SafeFailure, 'workloads-changed'):
                o.verify_composition(self.config, self.api, self.apps, lambda: self.apps)

    def test_partial_paired_rollout_rejected(self):
        self.apps[1]['status']['sync']['revision'] = 'c' * 40
        with self.assertRaisesRegex(o.SafeFailure, 'source-mismatch'):
            self.verify()

    def test_pending_workload_rejected(self):
        self.deployment['status']['updatedReplicas'] = 0
        with self.assertRaisesRegex(o.SafeFailure, 'rollout-not-ready'):
            self.verify()

    def test_out_of_band_image_change_rejected(self):
        self.deployment['spec']['template']['spec']['containers'][0]['image'] = 'example/wrong@sha256:' + 'c' * 64
        with self.assertRaisesRegex(o.SafeFailure, 'image-drift'):
            self.verify()

    def test_missing_manifest_evidence_rejected(self):
        self.deployment['metadata']['annotations'] = {}
        with self.assertRaisesRegex(o.SafeFailure, 'applied-manifest-evidence-missing'):
            self.verify()

    def test_public_deployment_checks_do_not_require_privileged_credential(self):
        self.config['probes'] = [{'name': 'os', 'assets': True}]
        self.assertEqual(self.verify()['probes'], ['os'])

    def test_missing_os_assets_probe_rejected(self):
        self.config['probes'] = [{'name': 'health'}]
        with self.assertRaisesRegex(o.SafeFailure, 'os-probe-not-configured'):
            self.verify()

    def test_intentionally_disabled_workload_has_no_running_image_claim(self):
        self.deployment['spec']['replicas'] = 0
        self.deployment['status'].update(readyReplicas=0, updatedReplicas=0)
        key = 'kubectl.kubernetes.io/last-applied-configuration'
        applied = json.loads(self.deployment['metadata']['annotations'][key])
        applied['spec']['replicas'] = 0
        self.deployment['metadata']['annotations'][key] = json.dumps(applied)
        with patch.object(self.api, 'get', side_effect=lambda path: {'items': []} if '/pods?' in path else self.deployment):
            evidence = self.verify()
        self.assertEqual(evidence['runtime'], [])
        self.assertTrue(all('(scaled to zero)' in s for s in evidence['services']))

    def test_unexpected_scale_to_zero_is_rejected(self):
        self.deployment['spec']['replicas'] = 0
        self.deployment['status'].update(readyReplicas=0, updatedReplicas=0)
        with patch.object(self.api, 'get', side_effect=lambda path: {'items': []} if '/pods?' in path else self.deployment):
            with self.assertRaisesRegex(o.SafeFailure, 'scale-zero-evidence-mismatch'):
                self.verify()

    def test_missing_credential_is_unverified_not_exception(self):
        self.config['functional_probe_file'] = '/does-not-exist/check.json'
        with self.assertRaisesRegex(o.SafeFailure, 'credential-or-contract-missing'):
            self.verify()

if __name__ == '__main__':
    unittest.main()
