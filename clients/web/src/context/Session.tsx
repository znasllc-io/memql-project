// context/Session.tsx -- app-wide session + memQL client.
//
// Holds the identity session (from the magic-link flow) and lazily builds a
// MemqlClient bound to the bff front door + the session token. Product screens
// read the client via useMemql() and the session via useSession().

import { createContext, useContext, useMemo, useState, type ReactNode } from "react";
import { MemqlClient } from "../lib/memql/client";
import { loadSession, logout as clearSession, type Session } from "../lib/auth/identity";

// SAME ORIGIN BY DEFAULT. Empty means "dial the origin this bundle was served
// from" -- the front door that serves the SPA also routes /memql to the product
// bff, in dev via the Vite proxy and in a cluster via the app.<domain> Ingress.
// Naming bff.<domain> here would work locally and break in the cloud, where
// that host is the RAW gRPC ingress (see MemqlClientOptions.httpUrl).
const BFF_HTTP_URL: string = (import.meta.env.VITE_MEMQL_HTTP_URL as string | undefined) ?? "";

interface SessionContextValue {
  session: Session | null;
  setSession: (s: Session | null) => void;
  logout: () => void;
  client: MemqlClient;
}

const SessionContext = createContext<SessionContextValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(() => loadSession());

  const client = useMemo(
    () => new MemqlClient({ httpUrl: BFF_HTTP_URL, token: session?.token }),
    [session?.token],
  );

  const value: SessionContextValue = {
    session,
    setSession,
    logout: () => {
      clearSession();
      setSession(null);
    },
    client,
  };

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionContextValue {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error("useSession must be used within <SessionProvider>");
  return ctx;
}

export const useMemql = (): MemqlClient => useSession().client;
