# Automatic deployment notifications

Implemented preparation; inactive until an instance supplies its destination and
public probe configuration, validates live operation and scales to one.
The base Deployment has zero replicas and is not included in another overlay.

## Event source and verification

`deploy/notifications` is a small Python standard-library observer. It watches
Argo Application events through the Kubernetes API and maintains incident state
and an ordered outbox in SQLite on a PVC. There is no scheduled GitHub poller,
Discord chatbot, new product application code or release-publish success trigger.
One observer serves one two-Application installation. RBAC grants read-only
Application/workload access, no Secrets API access and no cluster writes.

The native Argo notifications controller was considered. Its templates see one
Application at a time; revision-only oncePer does not model multiple incidents
and recoveries at the same revision. The inspected Argo 2.13 health objects do
not expose transition timestamps. Implementing a separate cross-app gate plus
native delivery would introduce two execution paths and annotation-based trust.
This observer combines the narrowly scoped gate, incident state and delivery.
Do not also subscribe native triggers to the same destination for these events.

A deployment attempt is keyed by both Application UIDs and operation startedAt
values, so retrying the same revision is a new attempt. Startup baselines existing
healthy operations quietly. Running operations discovered at startup are followed.
A publish or source-only refresh with no new operation emits no deployment success.

Success requires both Applications Succeeded, Synced and Healthy, with no queued
operation. They must share a source repository and synced Git revision, preventing
an intermediate paired rollout from passing while its counterpart is still on the
old commit or OutOfSync. Intentionally unchanged counterparts need no new sync.
Separate source repositories require a composition contract and are refused.

Expected container/init-container image digests come automatically from each
tracked workload's Argo-applied `kubectl.kubernetes.io/last-applied-configuration`.
The observer checks them against live templates and pods, current controller
generation, updated/ready replica counts, pod readiness and immutable runtime
image IDs. It records requested index digests separately from runtime platform
manifest digests; those need not equal for multiarch images. No operator edits a
notification plan per release. Missing applied-manifest evidence, floating images,
zero replicas and selector expressions currently fail closed as unverified.
Server-side-apply workloads without this annotation need another authoritative
manifest source before this verifier can certify them.

It then probes configured public surfaces, validates OS HTML identity and its
same-origin script/style assets (rejecting HTML masquerading as JS). A completion
message establishes deployment and these listed checks, not authenticated user
flows. An optional authenticated JSON check, if configured, must reject the
unauthenticated request and satisfy its assertions with a dedicated credential.
Redirects are refused, including redirects that could forward credentials.
It rereads workloads/pod identities and Application status afterward; any change
invalidates the probe result. Verification evidence is retained in SQLite state.

This is its own shared postdeploy verification seam. It does not invoke the
engine's cloud deploy-gate wrapper, whose post-deploy-gate.sh backend was absent
in the inspected checkout. It does not claim full browser interaction or a
zero-dropped-streams test: those need additional functional checks if required.

## States and delivery

| Event | Threshold | Meaning |
|---|---|---|
| Failed / Error | Immediate | Argo operation outcome; distinct states, no outage inference |
| Stalled | Running/Terminating for 15 minutes | May still complete |
| Degraded | Continuous health degradation for 2 minutes | Not equivalent to sync failure |
| Anomalous | Unknown/Missing health or reconciliation error for 5 minutes | Includes missing Application and disconnected watch |
| Unverified | No verification after 10 minutes from latest sync attempt | Names the missing evidence/check |
| Success | Both Applications, workloads and all probes pass | One verified composite notice |
| Recovery | Open incident plus fresh successful verification | Linked to the incident, including same-revision recovery |

Thresholds are configurable seconds. Timers execute locally for active events;
unchanged healthy installations do not run functional probes. Pending verification
retries at 30 seconds, backing off to 5 minutes after an unverified alert. Watch
reconnection uses resourceVersion and relists after expiration. Unchanged incident
conditions do not repeatedly enqueue messages. A cleared condition rearms a later
incident at the same revision. A later terminal failure is distinct from a stall.
Manual-sync OutOfSync waiting for the first operator sync is not a failed deploy.

Transitions and enqueue are one durable SQLite transaction. A single ordered
outbox handles 429 Retry-After, 5xx, transport errors and restarts; recovery cannot
overtake a failed incident message. Retries back off to five minutes (or longer
Retry-After), and pending delivery makes the observer pod unready and emits a
safe structured log for existing cluster monitoring. Wire this readiness/log
signal into the installation's existing monitoring before relying on it: Discord
cannot be its own independent outage alarm. Liveness detects a stalled main loop.

Delivery is at-least-once, not exactly-once: a Discord acceptance followed by lost
HTTP confirmation or a crash before the local receipt commit can duplicate a
message. Event IDs make that ambiguity recognizable. Preserve the PVC, run one
replica only (Recreate strategy), and never run a second observer with the same
state/destination. Volume loss loses incident/delivery history. Retain/backup that
small volume and monitor its capacity; automated retention is not implemented.

## Configuration and secrets

Compose `deploy/notifications` at an immutable template commit. Override config.json
with instance/cluster, the two Application names (roles engine/product), namespaces,
public probes and approved application links. Patch RBAC namespaces when necessary.
The default image is digest-pinned Python 3.12 Alpine, with no runtime package
installation. Code/config ConfigMaps have content hashes; adoption is a deliberate
GitOps change. The suspended base must be explicitly scaled to one after setup.

Provision only these Kubernetes Secrets in the observer namespace through the
installation's established secure mechanism. No credentials belong in git:

- `memql-discord-deployment-webhook`, key `url`: the destination webhook URL.
- Optional `memql-deployment-functional-probe`, keys `token` and `check.json`: a dedicated
  read-only service credential and the check contract below. Set
  `functional_probe_file` to `/probe/check.json` to enable it. Rotation is read on
  every verification; projected volume updates do not require copying tokens.

Example contract shape (replace endpoint and assertion with a real protected,
read-only functional check for the installed engine/product):

```json
{
  "name": "authenticated-functional",
  "url": "https://api.example.invalid/protected-read-only-check",
  "status": 200,
  "unauthenticated_status": 401,
  "bearer_file": "/probe/token",
  "json_equals": {"ok": true}
}
```

When enabled, a missing or failing check/credential produces unverified, never a
synthetic pass. Leaving the optional check unconfigured does not claim auth testing. No observer
API permissions to read Kubernetes Secrets are granted: kubelet mounts only these
two named Secrets. Never copy an operator's broad token as a shortcut.

## Messages and versions

`message-examples.json` contains illustrative payloads rendered by the same code.
Messages include instance/cluster, state, source commit links, observation UTC,
latest sync attempt elapsed time, affected services, failure cause class and
approved app links. Engine/product versions are immutable image references and
digests, not a stale product.env engineRef or guessed semver. Optional version_labels
maps exact full image references to human release labels; it is unnecessary for
automatic reporting. Failure messages label prior evidence as last verified,
never as proof that those versions remain live after a partial rollout. Source
commit links are automatic; PR/release/workflow links can be supplied when known.

Only allowlisted program-generated reason codes/resource names reach Discord.
Raw operation messages, pod logs, response bodies and secret-bearing URLs are not
forwarded. JSON is serialized and bounded to Discord limits. Mentions are disabled
with allowed_mentions.parse=[]; no everyone/here ping. Restricted incident details
remain in Argo; summaries say which class of check needs attention.

## Validation and activation

Run `python3 -m unittest discover -s scripts/notifications -v` and
`kubectl kustomize deploy/notifications` locally. CI runs both on affected changes.
Tests cover transitions, same-revision retries/recovery, restart/outbox ordering,
partial paired rollout, stale probes, image drift and missing evidence. Unit tests
are not a claim that a live Discord delivery or authenticated probe has passed.

After the current production upgrade is confirmed complete: provision the exact
approved destination and webhook Secret, verify public checks (and any optional
authenticated contract), verify the
instance render and read-only RBAC, install suspended, preserve state volume,
activate one replica and exercise delivery/verification in an isolated fixture
installation before relying on the next real rollout. Do not fabricate a failed
production deployment just to test notifications. Confirm the first real rollout
against Argo, actual image composition and the Discord message. Disable by scaling
to zero; keep PVC and delivery receipts for restart/dedup.
