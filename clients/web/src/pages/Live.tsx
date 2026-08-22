// pages/Live.tsx -- ONE subscription example, driven by a GENERATED concept id.
//
// A graph subscription is STRUCTURED: it names a concept and the CDC verbs it
// wants, and the ENGINE composes the bus topic from those
// (znasllc-io/memql#2460 -- a free-text filter is rejected outright for graph
// kinds). So the id comes from the generated `Concepts` map, never a
// hand-written `graph.node...` / `v1:` string. Incoming nodes carry bare ids
// and are keyed by (concept, id).

import { useEffect, useState } from "react";
import { useMemql } from "../context/Session";
import { nodeKey, type Node } from "../lib/memql/client";
import { Concepts } from "../generated/concepts";

export default function Live() {
  const client = useMemql();
  const [nodes, setNodes] = useState<Node[]>([]);
  const [error, setError] = useState("");

  useEffect(() => {
    let unsub: (() => void) | undefined;
    client
      .connect()
      .then(() => {
        unsub = client.subscribeGraph(Concepts.__PRODUCT_ID___GREETING, ["created"], (node) => {
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
        Subscribed to <code>{Concepts.__PRODUCT_ID___GREETING}</code> (created) via the generated
        concept constants.
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
