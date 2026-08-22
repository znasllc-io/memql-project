// lib/memql/client.ts -- a thin, self-contained memQL client for the starter
// shell. It rides the WebSocket bridge (`/memql/ws`) that tunnels to the
// engine's MemqlService.Stream.
//
// WHY THIS EXISTS RATHER THAN THE SDK. The engine publishes
// @znasllc-io/memql-sdk-core (Connection / QueryClient / SubscriptionManager --
// the same primitives, typed and complete) to GITHUB PACKAGES, which needs a
// NODE_AUTH_TOKEN to install. A freshly stamped product must `npm install &&
// tsc && vite build` with no publish or token precondition, so the starter
// carries this shim instead. Swap it for the SDK -- or for the generated
// @__PRODUCT_ORG__/__PRODUCT__-sdk that layers typed methods on it -- as soon
// as the product has registry credentials; the shapes below are deliberately
// the SDK's, so the swap is an import change.
//
// THE WIRE IS PROTOBUF, NOT AD-HOC JSON. The bridge decodes every text frame
// as protojson of `MemqlClientMessage` (component/server/memqlws/handler.go),
// and it decodes with DiscardUnknown -- so a frame the engine does not
// recognise is not rejected, it unmarshals to an EMPTY message and is answered
// by silence. That is why the envelope names below (`executeQuery`,
// `subscribe`, `unsubscribe`, and the SCREAMING_SNAKE enum spellings) are not
// stylistic: an invented field name produces a request that hangs forever with
// nothing logged on either side.
//
// BARE IDS: every id that crosses this seam is a bare short slug. This client
// never composes, parses, or compares canonical `v1:` ids -- the engine
// bare-ifies at its wire seams and resolves bare inbound args server-side. When
// results mix concepts, key rows by (concept, id), never by id alone.

/** A graph node as it arrives on the wire: bare id + concept + opaque payload. */
export interface Node {
  id: string;
  concept: string;
  payload: Record<string, unknown>;
}

/** A stable key for a node when concepts mix -- (concept, id), never id alone. */
export const nodeKey = (n: Pick<Node, "concept" | "id">): string => `${n.concept}\x00${n.id}`;

export type Unsubscribe = () => void;

/** The CDC verbs a graph subscription may ask for. */
export type GraphAction = "created" | "updated" | "deleted";

export interface MemqlClientOptions {
  /**
   * Base HTTP(S) URL of the bff. LEAVE IT EMPTY (the default) to dial the
   * origin this bundle was served from, which is what a client surface should
   * do: the front door that served the SPA also routes `/memql` to the product
   * bff, so same-origin removes a whole class of CORS and mis-pointing bugs.
   *
   * Naming an absolute host is the trap this default exists to avoid. In the
   * cloud entry `bff.<domain>` is the RAW gRPC ingress (backend-protocol GRPC,
   * :50051), so a browser WebSocket upgrade sent there hands HTTP/1.1 to an
   * h2c backend and fails with a protocol error naming nothing. Only set this
   * when the SPA really is served from a different origin than the bff.
   */
  httpUrl?: string;
  /** Bearer token from the identity OAuth flow (see lib/auth/identity.ts). */
  token?: string;
}

/** How long a query waits for its reply before rejecting. */
const QUERY_TIMEOUT_MS = 30_000;

/**
 * renderMemQLValue converts a JS value into its MemQL literal form. Mirrors the
 * SDK's sdk/ts/src/client/memqlValue.ts (and sdk/go's renderMemQLValue): object
 * keys are sorted so the same args always produce the same call string.
 */
export function renderMemQLValue(value: unknown): string {
  if (value == null) return "nil";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "nil";
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return `[${value.map(renderMemQLValue).join(", ")}]`;
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const parts = Object.keys(obj)
      .sort()
      .map((k) => `${k}: ${renderMemQLValue(obj[k])}`);
    return `{${parts.join(", ")}}`;
  }
  return JSON.stringify(String(value));
}

/**
 * buildCall composes the `query name(a: 1, b: "x")` string the engine's
 * ExecuteQueryMsg carries. This is what the generated SDK methods emit; hand
 * one only while there is no generated method for the construct.
 */
export function buildCall(name: string, args: Record<string, unknown> = {}): string {
  const parts = Object.keys(args)
    .sort()
    .filter((k) => args[k] !== undefined)
    .map((k) => `${k}: ${renderMemQLValue(args[k])}`);
  return `query ${name}(${parts.join(", ")})`;
}

// --- protojson envelope views -------------------------------------------
// Only the slots this shim emits or consumes. The proto
// (component/grpc/memql.proto) is the source of truth; these mirror the SDK's
// hand-written TS view of it.

interface ServerMessage {
  queryResult?: {
    requestId?: string;
    result?: {
      bundle?: { nodes?: WireNode[] } | null;
      data?: unknown[];
    };
  };
  queryError?: { requestId?: string; error?: { code?: string; message?: string } };
  event?: { subscriptionId?: string; kind?: string; payload?: Record<string, unknown> };
}

interface WireNode {
  id?: string;
  concept?: string;
  payload?: Record<string, unknown>;
}

function nodesFromResult(msg: ServerMessage["queryResult"]): Node[] {
  const result = msg?.result;
  if (!result) return [];
  const bundle = result.bundle?.nodes;
  if (bundle) {
    return bundle.map((n) => ({
      id: n.id ?? "",
      concept: n.concept ?? "",
      payload: n.payload ?? {},
    }));
  }
  if (Array.isArray(result.data)) {
    return result.data
      .filter((r): r is Record<string, unknown> => !!r && typeof r === "object" && !Array.isArray(r))
      .map((r) => ({
        id: typeof r.id === "string" ? r.id : "",
        concept: typeof r.concept === "string" ? r.concept : "",
        payload: r,
      }));
  }
  return [];
}

// The engine flattens a node's payload fields into the CDC event alongside the
// intrinsics and also keeps the whole payload under `payload`; `id` has a
// `nodeId` alias depending on which write path emitted it.
function nodeFromEvent(payload: Record<string, unknown> | undefined): Node {
  const p = payload ?? {};
  const id = typeof p.id === "string" && p.id !== "" ? p.id : typeof p.nodeId === "string" ? p.nodeId : "";
  const inner = p.payload && typeof p.payload === "object" && !Array.isArray(p.payload)
    ? (p.payload as Record<string, unknown>)
    : p;
  return { id, concept: typeof p.concept === "string" ? p.concept : "", payload: inner };
}

const ACTION_WIRE: Record<GraphAction, string> = {
  created: "GRAPH_NODE_ACTION_CREATED",
  updated: "GRAPH_NODE_ACTION_UPDATED",
  deleted: "GRAPH_NODE_ACTION_DELETED",
};

let idSeq = 0;
const nextId = (): string => `r${++idSeq}-${Math.random().toString(36).slice(2, 10)}`;

/**
 * Minimal memQL WS client. Opens one multiplexed connection and correlates
 * request/response by `requestId` and subscription frames by `subscriptionId`.
 * Intentionally small: a starter a product grows into, or discards for the SDK.
 */
export class MemqlClient {
  private ws: WebSocket | null = null;
  private opening: Promise<void> | null = null;
  private readonly pending = new Map<string, { resolve: (n: Node[]) => void; reject: (e: Error) => void }>();
  private readonly subs = new Map<string, (node: Node) => void>();

  constructor(private readonly opts: MemqlClientOptions) {}

  private wsUrl(): string {
    const base = (this.opts.httpUrl ?? "").trim();
    if (base === "") {
      // Same origin as the page: the front door that served this bundle also
      // routes /memql to the product bff.
      const scheme = window.location.protocol === "https:" ? "wss" : "ws";
      return `${scheme}://${window.location.host}/memql/ws`;
    }
    return `${base.replace(/^http/, "ws").replace(/\/$/, "")}/memql/ws`;
  }

  connect(): Promise<void> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return Promise.resolve();
    if (this.opening) return this.opening;
    this.opening = new Promise<void>((resolve, reject) => {
      // AUTH: the bearer token travels in the WebSocket handshake's
      // Sec-WebSocket-Protocol header, never in the URL query string. Per the
      // engine contract (znasllc-io/memql#2511), the first subprotocol entry is
      // the scheme discriminator ("bearer") and the second is the raw JWT
      // credential -- JWTs are valid RFC 6455 subprotocol tokens, so no
      // re-encoding. The engine negotiates the "bearer" entry back on the 101
      // response; browsers abort the handshake if the server does not echo it.
      // No credential ever rides the URL, so nothing leaks into ingress/proxy
      // access logs or browser history. With no token (e.g. pre-login) open the
      // socket with no subprotocols at all.
      const ws = this.opts.token
        ? new WebSocket(this.wsUrl(), ["bearer", this.opts.token])
        : new WebSocket(this.wsUrl());
      this.ws = ws;
      ws.onopen = () => resolve();
      ws.onerror = () => reject(new Error("memql ws connection failed"));
      ws.onclose = () => {
        this.opening = null;
        // Fail every parked request rather than leaving it hanging: a closed
        // socket will never answer, and a promise that never settles reads as
        // a frozen screen with nothing in the console.
        const err = new Error("memql ws closed");
        for (const [, p] of this.pending) p.reject(err);
        this.pending.clear();
      };
      ws.onmessage = (ev) => this.onMessage(ev);
    });
    return this.opening;
  }

  private onMessage(ev: MessageEvent) {
    if (typeof ev.data !== "string") return; // this shim speaks protojson only
    let msg: ServerMessage;
    try {
      msg = JSON.parse(ev.data) as ServerMessage;
    } catch {
      return;
    }

    if (msg.event) {
      const handler = this.subs.get(msg.event.subscriptionId ?? "");
      handler?.(nodeFromEvent(msg.event.payload));
      return;
    }
    if (msg.queryResult) {
      const parked = this.pending.get(msg.queryResult.requestId ?? "");
      if (!parked) return;
      this.pending.delete(msg.queryResult.requestId ?? "");
      parked.resolve(nodesFromResult(msg.queryResult));
      return;
    }
    if (msg.queryError) {
      const parked = this.pending.get(msg.queryError.requestId ?? "");
      if (!parked) return;
      this.pending.delete(msg.queryError.requestId ?? "");
      parked.reject(new Error(msg.queryError.error?.message ?? "query failed"));
    }
  }

  private send(frame: Record<string, unknown>): void {
    this.ws?.send(JSON.stringify(frame));
  }

  /**
   * Run a named query function with bare-id args; resolves with its rows. Arg
   * values are bare ids -- the engine resolves them against the construct's
   * bound concept server-side.
   */
  query(name: string, args: Record<string, unknown> = {}): Promise<Node[]> {
    return new Promise<Node[]>((resolve, reject) => {
      const requestId = nextId();
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`${name}: no reply within ${QUERY_TIMEOUT_MS}ms`));
      }, QUERY_TIMEOUT_MS);
      this.pending.set(requestId, {
        resolve: (n) => {
          clearTimeout(timer);
          resolve(n);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      this.send({ executeQuery: { requestId, query: buildCall(name, args) } });
    });
  }

  /**
   * Subscribe to a concept's CDC stream. STRUCTURED, not a filter string: the
   * engine composes the bus topic from concept + actions and REFUSES a
   * free-text filter for graph subscriptions (znasllc-io/memql#2460). Pass a
   * concept id from the generated `Concepts` map -- never a hand-written topic.
   * `onNode` fires per matching graph node; the node's id is bare.
   */
  subscribeGraph(
    concept: string,
    actions: GraphAction[],
    onNode: (node: Node) => void,
  ): Unsubscribe {
    const subscriptionId = nextId();
    this.subs.set(subscriptionId, onNode);
    this.send({
      subscribe: {
        subscriptionId,
        kind: "SUBSCRIPTION_KIND_GRAPH_EVENTS",
        concept,
        actions: actions.map((a) => ACTION_WIRE[a]),
      },
    });
    return () => {
      this.subs.delete(subscriptionId);
      this.send({ unsubscribe: { subscriptionId } });
    };
  }

  close() {
    this.ws?.close();
    this.ws = null;
    this.opening = null;
  }
}
