# memql-bff-__PRODUCT__ -- the __PRODUCT__ product pack (carrier)

**Type:** Product pack / carrier for the memQL engine
**Language:** Go + MemQL DSL
**Depends on:** `github.com/znasllc-io/memql` (the shared, product-agnostic engine)

This repo owns EVERYTHING __PRODUCT__-specific that runs server-side: the
product DSL tree (`dsl/__PRODUCT__`, `dsl/guide`, `dsl/curriculum`), the
product Go integrations, the carrier image builds (engine + pack compiled
together), the product's deploy/release estate (staging/prod overlays,
release lockfiles, rollouts, gate-browser), and the local-stack
orchestration. The engine repo contains zero product knowledge; this pack
plugs in through the engine's generic seams.

## Local stack

```bash
make up          # engine cluster + carrier-built nodes + the bff head
make up-refresh  # clean slate (fresh DB), then the same bring-up
make dev         # rebuild carrier images -> import -> restart
make dev NODE=bff
make status      # mesh litmus (ArgoCD app: __PRODUCT__-local)
make down
```

These delegate to the engine's k3d tooling via the downstream-stack
contract (memql: docs/public/operate/downstream-stacks.md) with this repo
as the carrier, then register the `__PRODUCT__-local` ArgoCD Application
(deploy/k8s/overlays/local -- the bff head). Prereqs: the memql sibling
checkout at `../memql`, `gh` authed (private repo -> ArgoCD needs a
token), current branch PUSHED.

## Engine seams this pack consumes

| Registration | From | What it provides |
|---|---|---|
| `dsl.RegisterTree` | `dsl/{__PRODUCT__,guide,curriculum}/embed.go` | the product DSL (concepts, queries, mutations, tools, prompts, seeds incl. the per-user `assistant` + `assistantRole`) |
| `memql.RegisterPlugin` | `integrations/*` (training, chat, dailyspace, avatardirect, ...) | product Go integrations |
| `memql.RegisterSuggestDomain` | `integrations/__PRODUCT__/suggest` | the product AiSuggest domains |
| `memql.RegisterCapabilitySlug` | `integrations/__PRODUCT__/operator_caps.go` | `__PRODUCT__-takeover`/`-guide`/`-control` -> the 16 operator primitives (operator tag) |
| `memql.RegisterAppProfile` | `integrations/__PRODUCT__/appprofile` | the operator app profile (UI map markdown) + `__PRODUCT__-ui` operator domain |
| `knowledge.RegisterSeedDomain` | `integrations/__PRODUCT__/knowledge_seed.go` | the `__PRODUCT__-ui` knowledge domain + seed corpus |
| `node.RegisterChatReplyConcept` | `integrations/__PRODUCT__/delivery.go` | `v1:__PRODUCT__:canvasState` rides the chat-reply delivery substrate |
| `node.RegisterRoutingRule` | `integrations/__PRODUCT__/routing.go` | cross-node event routing for product concepts |

Byte discipline: every stored/wire identifier registered above
(concept ids, skill slugs, domain ids, seed names) is a data contract --
never change the bytes.

## Deploy / release ownership (decoupling P3)

This repo owns the product's staging/prod overlays
(`deploy/k8s/overlays/`), the product manifests (`deploy/k8s/product/`),
`deploy/rollouts/`, `deploy/gate-browser/`, the release lockfiles
(`releases/`), and the release + product deploy scripts. The overlays
compose the ENGINE's base via a kustomize remote base and restore
deployment-specific values (hostnames, OAuth clients) the engine base
keeps neutral. See znasllc-io/memql#2429 for the cutover runbook.

---

# Product feature notes (moved from the engine repo's CLAUDE.md)

### Canvas state (v1)

The __PRODUCT__ canvas (the center surface of every space) is now a
per-space immutable timeline of `v1:__PRODUCT__:canvasState` rows. The
mutable-scene protocol that lived here previously (with the
`v1:__PRODUCT__:canvas`, `v1:__PRODUCT__:canvas:element`,
`v1:__PRODUCT__:exhibit`, and `v1:__PRODUCT__:scene:update` concepts and
their `presentExhibit` / `dismissExhibit` / `updateScene` mutations)
has been deleted -- those concepts had zero producers and zero
consumers and the new model picked one concept over four.

Schema highlights (the `v1:__PRODUCT__:canvasState` concept body):

- `space` -- target `v1:cognition:space.id` (every viewer of that
  space gets the row, subject to visibility filtering).
- `kind` -- `card` | `document` | `dataview` | `graph`. Picks the
  frontend renderer.
- `data` -- per-kind shape (named `data` to avoid collision with
  the reserved `payload` intrinsic; gotcha #19).
- `visibility` -- `public` (every space participant) | `private`
  (only `forUserId`; always the space owner under v1 permission
  rules).
- `actor` -- `{kind: "agent"|"user"|"system", ...}`. Drives the
  frontend's CanvasAuthorBadge.
- `importance` -- `notify` (pings the canvas bell) | `ambient` (lands
  silently on the timeline). Cognition is the post-hoc authority and
  can promote / coalesce.

Two paths write canvasState rows:

1. **Tool path** (agent presentations, public visibility): the
   `canvas.publish` tool. Invoked by agents from inside their tool
   loop with `kind` + `data` + optional `importance` / `note`.
2. **Frontend direct mutation path** (owner-private welcome cards):
   the `createCanvasState` mutation. The __PRODUCT__
   frontend calls this at the end of every create-modal flow --
   agent.created (AgentsListPanel), group.created (SettingsListPanel),
   and space.created (useCreateAndJoinSpace). All three use the same
   mutation and row shape; the only reason they live on the frontend
   instead of in automations is that they need to stamp the bare-form
   space id (matching what `setActiveSpace` leaves behind) and -- for
   agent / group -- they need active-space context the graph event
   doesn't carry.

Queries: `canvasStatesForSpace` (public), `privateCanvasStatesForViewer`
(per-viewer private). Two queries because the memql query parser
doesn't have an OR operator yet; the frontend merges the streams.
Shape: `canvasStateFull`.

Full design rationale (frontend + backend): __PRODUCT__'s
`docs/canvas/v1-plan.md`.



### Spaces (three-state lifecycle + daily spaces)

`v1:cognition:space` carries `status` ∈ {active, saved, archived,
scheduled} and a `kind` ∈ {regular, daily}.

- **active** -- working space, default state.
- **saved** -- user manually preserved. Never auto-deletes.
- **archived** -- hidden from the active list. `archivedAt` +
  `expiresAt` are stamped at archive time
  (`archivedAt + User.preferences.archiveRetentionDays`); the
  `purgeExpiredArchivedSpaces` cron (daily 02:00 UTC) hard-deletes
  rows whose `expiresAt < now`. The query is a plain expiresAt
  comparison -- no per-row user lookup at sweep time. Bumping
  `archiveRetentionDays` from 30 to 60 rescues currently-archived
  rows because the cron reads expiresAt that was stamped under the
  current preference.
- **scheduled** -- future-dated meeting. Untouched by the purge.

`kind=daily` is a per-user singleton provisioned client-side
(`useDailySpace` on __PRODUCT__), keyed by `(userHash, dailyDateKey)`
where dateKey is computed in the user's local timezone. Daily spaces
are private, pinned at the top of the active list, and rolled over
each day per `User.preferences.dailySpaceRolloverAction`
(`archive` default, or `save`).

`User.preferences` carries the lifecycle controls: `timezone` (IANA
name), `archiveRetentionDays` (30 default, 60 picker), and
`dailySpaceEnabled` toggle. __PRODUCT__ Control settings persist server-
side too: `cursorTweenMs`, `takeoverMode` (clean / dim),
`interactivePace` (quick / steady / deliberate).

Mutations: `createSpace`, `archiveSpace`, `saveSpace`,
`restoreSpace`, `deleteSpaceNow`, `createDailySpace`. Queries:
`activeSpaces`, `savedSpaces`, `archivedSpaces`,
`expiredArchivedSpaces`, `allArchivedSpacesAcrossUsers`.

**Location (post-#2038):** the `space` concept and ALL of these
mutations + queries moved OUT of engine core into the __PRODUCT__ pack
(`memql-bff-__PRODUCT__/dsl/__PRODUCT__/{mutations,queries}.memql`),
id-preserving (ids stay `v1:cognition:space*`; names unchanged). The
pure engine no longer loads the `space` concept, so engine-repo tests
cannot exercise them -- that coverage lives in the pack repo. The core
participant/session/utterance mutations that stayed (joinSpaceAsHuman,
leaveSpace, addAgentToSpace, ...) remain in
`dsl/cognition/mutations.memql`.

