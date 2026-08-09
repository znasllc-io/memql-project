// pages/Home.tsx -- ONE typed query round-trip.
//
// Calls a named query function over the memQL client and renders the rows. The
// query args are BARE ids (the engine resolves them against the construct's
// bound concept server-side); result rows carry bare ids too, and are keyed by
// (concept, id) via nodeKey since a real screen mixes concepts.

import { useEffect, useState } from "react";
import { useMemql, useSession } from "../context/Session";
import { nodeKey, type Node } from "../lib/memql/client";

export default function Home() {
  const client = useMemql();
  const { session, logout } = useSession();
  const [rows, setRows] = useState<Node[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let live = true;
    client
      .connect()
      // Replace `queryMySpaces` with one of the product's generated query
      // functions once the SDK is wired; the shape (bare-id args -> bare-id
      // rows) is identical.
      .then(() => client.query<Node[]>("queryMySpaces", { ownerUserId: session?.userId }))
      .then((result) => {
        if (live) setRows(result ?? []);
      })
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [client, session?.userId]);

  return (
    <main className="card">
      <header className="row">
        <h1>__PRODUCT__</h1>
        <button onClick={logout}>Sign out</button>
      </header>
      <nav>
        <a href="/live">Live subscription example →</a>
      </nav>
      <h2>My spaces</h2>
      {loading && <p>Loading…</p>}
      {error && <p className="error">{error}</p>}
      {!loading && !error && rows.length === 0 && <p>No rows yet.</p>}
      <ul>
        {rows.map((n) => (
          <li key={nodeKey(n)}>
            <code>{n.id}</code> — {String(n.payload.name ?? n.concept)}
          </li>
        ))}
      </ul>
    </main>
  );
}
