// lib/memql/client.ts -- a thin, self-contained memQL client for the starter
// shell. It rides the WebSocket bridge (`${httpUrl}/memql/ws`) that tunnels to
// the engine's MemqlService.Stream. A real product REPLACES this with the
// generated @__PRODUCT_ORG__/__PRODUCT__-sdk (its Connection / QueryClient give
// typed query+subscription methods over the same bridge); this starter keeps
// zero external SDK dependency so the shell builds standalone.
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

export interface MemqlClientOptions {
  /** Base HTTP(S) URL of the bff front door, e.g. https://bff.__DOMAIN__ */
  httpUrl: string;
  /** Bearer token from the identity magic-link flow (see lib/auth/identity.ts). */
  token?: string;
}

/**
 * Minimal memQL WS client. Opens one multiplexed connection and correlates
 * request/response + subscription frames by id. Intentionally small: a starter
 * a product grows into, or discards for the SDK.
 */
export class MemqlClient {
  private ws: WebSocket | null = null;
  private nextId = 1;
  private readonly pending = new Map<string, (payload: unknown) => void>();
  private readonly subs = new Map<string, (node: Node) => void>();

  constructor(private readonly opts: MemqlClientOptions) {}

  private wsUrl(): string {
    const base = this.opts.httpUrl.replace(/^http/, "ws").replace(/\/$/, "");
    // SECURITY (known risk, engine-gated -- znasllc-io/memql#2511): the bearer
    // token rides the WS URL as a `?token=` query param. URLs are routinely
    // logged by ingresses, reverse proxies, and browser history, so the token can
    // leak into access logs. The WS handshake contract is engine-owned, so the
    // template cannot move the token off the URL until the engine accepts an
    // alternative (a Sec-WebSocket-Protocol bearer subprotocol or a short-lived
    // ticket exchange) -- tracked in znasllc-io/memql#2511. MITIGATION until then:
    // configure the ingress/proxy fronting /memql/ws to DROP the query string
    // from its access-log format (see client/README.md "WebSocket auth" note).
    const q = this.opts.token ? `?token=${encodeURIComponent(this.opts.token)}` : "";
    return `${base}/memql/ws${q}`;
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.wsUrl());
      this.ws = ws;
      ws.onopen = () => resolve();
      ws.onerror = () => reject(new Error("memql ws connection failed"));
      ws.onmessage = (ev) => this.onMessage(ev);
    });
  }

  private onMessage(ev: MessageEvent) {
    let msg: { id?: string; type?: string; result?: unknown; node?: Node };
    try {
      msg = JSON.parse(typeof ev.data === "string" ? ev.data : "");
    } catch {
      return;
    }
    if (msg.type === "cdc" && typeof msg.id === "string" && msg.node) {
      this.subs.get(msg.id)?.(msg.node);
      return;
    }
    if (typeof msg.id === "string" && this.pending.has(msg.id)) {
      const resolve = this.pending.get(msg.id)!;
      this.pending.delete(msg.id);
      resolve(msg.result);
    }
  }

  private send(frame: Record<string, unknown>): string {
    const id = String(this.nextId++);
    this.ws?.send(JSON.stringify({ id, ...frame }));
    return id;
  }

  /**
   * Run a named query function with bare-id args; resolves with its typed rows.
   * Arg values are bare ids -- the engine resolves them against the construct's
   * bound concept server-side.
   */
  query<T = Node[]>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    return new Promise((resolve) => {
      const id = this.send({ type: "query", fn, args });
      this.pending.set(id, (payload) => resolve(payload as T));
    });
  }

  /**
   * Subscribe to a CDC filter (from generated CDCFilters / filterFor -- never a
   * hand-written topic). `onNode` fires per matching graph node; the node's id
   * is bare.
   */
  subscribe(filter: string, onNode: (node: Node) => void): Unsubscribe {
    const id = this.send({ type: "subscribe", filter });
    this.subs.set(id, onNode);
    return () => {
      this.subs.delete(id);
      this.ws?.send(JSON.stringify({ id, type: "unsubscribe" }));
    };
  }

  close() {
    this.ws?.close();
    this.ws = null;
  }
}
