// pages/Live.tsx -- ONE subscription example, driven by GENERATED topic
// constants.
//
// Subscribes to a concept's CDC stream using a filter from the generated
// `CDCFilters` / `filterFor` surface (src/generated/concepts.ts, the sdk-gen
// A3 shape) -- NEVER a hand-written `graph.node...`/`v1:` string. Incoming
// nodes carry bare ids and are keyed by (concept, id).

import { useEffect, useState } from "react";
import { useMemql } from "../context/Session";
import { nodeKey, type Node } from "../lib/memql/client";
import { CDCFilters, Concepts, filterFor } from "../generated/concepts";

export default function Live() {
  const client = useMemql();
  const [nodes, setNodes] = useState<Node[]>([]);
  const [error, setError] = useState("");

  useEffect(() => {
    let unsub: (() => void) | undefined;
    client
      .connect()
      .then(() => {
        // Two equivalent ways to name the filter, both from the generated
        // surface -- a named constant, or the helper over a Concepts id:
        //   CDCFilters.__PRODUCT___GREETING_CREATED
        //   filterFor(Concepts.__PRODUCT___GREETING, "created")
        const filter = CDCFilters.__PRODUCT___GREETING_CREATED;
        void filterFor(Concepts.__PRODUCT___GREETING, "created"); // shown for reference
        unsub = client.subscribe(filter, (node) => {
          setNodes((prev) => [node, ...prev].slice(0, 50));
        });
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
    return () => unsub?.();
  }, [client]);

  return (
    <main className="card">
      <header className="row">
        <h1>Live: greetings</h1>
        <a href="/">← Home</a>
      </header>
      <p>
        Subscribed to <code>{CDCFilters.__PRODUCT___GREETING_CREATED}</code> via the generated
        filter constants.
      </p>
      {error && <p className="error">{error}</p>}
      <ul>
        {nodes.map((n) => (
          <li key={nodeKey(n)}>
            <code>{n.id}</code> — {String(n.payload.message ?? "")}
          </li>
        ))}
      </ul>
    </main>
  );
}
