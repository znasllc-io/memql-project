// lib/auth/identity.ts -- the identity magic-link flow for the __PRODUCT__
// shell. Talks to the in-house identity service at https://identity.__DOMAIN__
// (magic-link is the primary login path; the service issues a JWT the app then
// carries as a bearer to the bff).
//
// Flow:
//   1. requestMagicLink(email) -> identity emails a single-use link.
//   2. the link lands the browser on /auth/callback?token=... (SPA route).
//   3. completeLogin(token) exchanges it for a session JWT, stored locally.
//
// Endpoints are the documented identity HTTP surface (OAuth/magic-link require
// HTTP); everything else in the app rides gRPC via the WS bridge.

const IDENTITY_BASE_URL: string =
  (import.meta.env.VITE_IDENTITY_BASE_URL as string | undefined) ??
  "https://identity.__DOMAIN__";

const TOKEN_STORAGE_KEY = "__PRODUCT__.session.token";

export interface Session {
  token: string;
  userId: string;
}

/** Request a magic-link email for the given address. */
export async function requestMagicLink(email: string): Promise<void> {
  const res = await fetch(`${IDENTITY_BASE_URL}/auth/magic-link`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email }),
  });
  if (!res.ok) {
    throw new Error(`magic-link request failed (${res.status})`);
  }
}

/** Exchange a magic-link token for a session JWT and persist it. */
export async function completeLogin(linkToken: string): Promise<Session> {
  const res = await fetch(`${IDENTITY_BASE_URL}/auth/complete`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: linkToken }),
  });
  if (!res.ok) {
    throw new Error(`login completion failed (${res.status})`);
  }
  const body = (await res.json()) as { accessToken: string; userId: string };
  const session: Session = { token: body.accessToken, userId: body.userId };
  localStorage.setItem(TOKEN_STORAGE_KEY, JSON.stringify(session));
  return session;
}

/** Load a persisted session, or null. */
export function loadSession(): Session | null {
  const raw = localStorage.getItem(TOKEN_STORAGE_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as Session;
  } catch {
    return null;
  }
}

/** Clear the persisted session. */
export function logout(): void {
  localStorage.removeItem(TOKEN_STORAGE_KEY);
}
