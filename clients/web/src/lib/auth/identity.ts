// lib/auth/identity.ts -- sign-in for the __PRODUCT__ shell.
//
// Magic link is the FRONT of an OAuth 2.1 authorization-code flow with PKCE,
// not a flow of its own. That is the whole shape of this file, and the reason
// it is bigger than "POST an email, get a token back":
//
//   1. startLogin(email) mints a PKCE verifier + a CSRF `state`, stores both in
//      this browser, and POSTs {email, clientId, redirectURI, state,
//      codeChallenge, codeChallengeMethod} to identity. All six fields are
//      required-or-load-bearing: identity 400s with `missing_field` unless
//      email + clientId + redirectURI are all present, because it stamps the
//      OAuth context onto the magic-link row at ISSUE time.
//   2. Identity emails a link to its OWN /auth/complete. That endpoint is GET,
//      it is opened by the person clicking the link, and it does not return
//      JSON -- it 302-redirects the browser to the redirectURI registered for
//      the clientId, carrying ?code=<authCode>&state=<echo>.
//   3. completeLogin(code, state) lands back here on /auth/callback, checks the
//      state against the one this browser stored, and exchanges the code at
//      POST /oauth/token with the verifier. That returns the access token.
//
// The verifier is what replaces a client secret: this SPA ships as static
// JavaScript, so anything embedded in the bundle is readable by anyone who can
// load it. PKCE binds the authorization code to a secret that never left this
// browser, so a code lifted out of a redirect URL, a referrer header or a proxy
// log cannot be redeemed by whoever lifted it.
//
// The clientId is "app" and the redirect URI is <this origin>/auth/callback:
// the engine DERIVES that registration from the cluster's MEMQL_DOMAIN
// (component/envregistry/domain.go -> MEMQL_IDENTITY_REGISTERED_CLIENTS), so
// there is nothing to register by hand -- but identity matches redirect_uri by
// EXACT string, so the SPA must be served at https://app.<domain> for the match
// to hold.
//
// These endpoints are HTTP by necessity (OAuth redirects and browser form posts
// have no gRPC form); everything else in the app rides gRPC via the WS bridge.

// Same-origin by default: the front door that serves this SPA also proxies
// /oauth/token, /auth/refresh, /auth/logout and /.well-known/jwks.json to
// identity. Only the magic-link POST needs identity's own origin, because the
// front door does not proxy /auth/magic-link.
const IDENTITY_BASE_URL: string =
  (import.meta.env.VITE_IDENTITY_BASE_URL as string | undefined) ??
  "https://identity.__DOMAIN__";

// The OAuth client id identity derives for a product SPA. Not configurable
// here on purpose -- it is one half of a registration the engine composes, and
// the other half (the redirect URI) is computed below from window.location.
const CLIENT_ID = "app";

const TOKEN_STORAGE_KEY = "__PRODUCT__.session.token";
const PENDING_STORAGE_KEY = "__PRODUCT__.session.pending";

export interface Session {
  token: string;
  userId: string;
  refreshToken?: string;
}

interface PendingLogin {
  verifier: string;
  state: string;
  redirectURI: string;
}

/** The redirect URI identity registers for this SPA: this origin + /auth/callback. */
export function redirectURI(): string {
  return `${window.location.origin}/auth/callback`;
}

// --- PKCE (RFC 7636) -----------------------------------------------------

function requireCrypto(): Crypto {
  // Web Crypto is unavailable on an insecure origin that is not localhost.
  // Failing loudly HERE is the point: the silent alternative is a sign-in
  // button that throws deep inside the redirect and reads as an app bug rather
  // than "this page must be served over HTTPS".
  const c = globalThis.crypto;
  if (!c?.subtle || typeof c.getRandomValues !== "function") {
    throw new Error(
      "Web Crypto is unavailable, so sign-in cannot generate a PKCE verifier. " +
        "Serve this app over HTTPS (or from localhost) -- crypto.subtle is " +
        "restricted to secure contexts.",
    );
  }
  return c;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  // Unpadded base64url (RFC 4648 s5); RFC 7636 s4.2 requires the padding gone.
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// 32 random bytes -> 43 base64url characters, the low end of RFC 7636's
// 43..128 range precisely because that is 32 bytes of entropy.
function randomToken(bytes = 32): string {
  const buf = new Uint8Array(bytes);
  requireCrypto().getRandomValues(buf);
  return base64Url(buf);
}

// BASE64URL(SHA256(ASCII(verifier))). The digest is over the verifier's ASCII
// BYTES, not the raw random bytes it was encoded from -- a difference that
// produces a challenge the server rejects with no clue as to why.
async function s256(verifier: string): Promise<string> {
  const digest = await requireCrypto().subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64Url(new Uint8Array(digest));
}

// --- the flow ------------------------------------------------------------

/**
 * Step 1: ask identity to email a sign-in link, carrying this browser's OAuth
 * context. Resolves once the request is accepted -- identity answers 200 with
 * the same shape whether or not the address is known, so a caller learns
 * nothing about who is registered.
 */
export async function startLogin(email: string): Promise<void> {
  const verifier = randomToken();
  const state = randomToken();
  const redirect = redirectURI();
  const pending: PendingLogin = { verifier, state, redirectURI: redirect };
  // localStorage, not sessionStorage: the link may well be opened in a NEW TAB
  // (that is what clicking a link in a mail client does), and sessionStorage
  // does not cross tabs.
  localStorage.setItem(PENDING_STORAGE_KEY, JSON.stringify(pending));

  const res = await fetch(`${IDENTITY_BASE_URL}/auth/magic-link`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      email,
      clientId: CLIENT_ID,
      redirectURI: redirect,
      state,
      codeChallenge: await s256(verifier),
      codeChallengeMethod: "S256",
    }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`magic-link request failed (${res.status})${detail ? `: ${detail}` : ""}`);
  }
}

/**
 * Step 3: exchange the authorization code identity redirected back with. Call
 * this from the /auth/callback route with the `code` and `state` query params.
 */
export async function completeLogin(code: string, state: string): Promise<Session> {
  const raw = localStorage.getItem(PENDING_STORAGE_KEY);
  if (!raw) {
    throw new Error("no sign-in is in progress in this browser; request a new link");
  }
  let pending: PendingLogin;
  try {
    pending = JSON.parse(raw) as PendingLogin;
  } catch {
    throw new Error("the stored sign-in context is unreadable; request a new link");
  }
  // The state check is what stops an attacker feeding this app a code of their
  // own choosing (OAuth 2.0 s10.12, login CSRF). It is NOT interchangeable with
  // the verifier and neither substitutes for the other.
  if (state !== pending.state) {
    throw new Error("sign-in state did not match; request a new link");
  }

  const res = await fetch(`${IDENTITY_BASE_URL}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grant_type: "authorization_code",
      code,
      client_id: CLIENT_ID,
      redirect_uri: pending.redirectURI,
      code_verifier: pending.verifier,
    }),
  });
  // The verifier is spent either way -- destroy it before anything can throw.
  localStorage.removeItem(PENDING_STORAGE_KEY);
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`token exchange failed (${res.status})${detail ? `: ${detail}` : ""}`);
  }
  const body = (await res.json()) as { access_token: string; refresh_token?: string };
  const session: Session = {
    token: body.access_token,
    userId: subjectOf(body.access_token),
    refreshToken: body.refresh_token,
  };
  localStorage.setItem(TOKEN_STORAGE_KEY, JSON.stringify(session));
  return session;
}

// subjectOf reads the `sub` claim out of the access token for display. The
// token is NOT verified here and must not be trusted for any decision -- the
// engine verifies every bearer against the JWKS on each call, which is the only
// verification that counts. This is a label, nothing more.
function subjectOf(jwt: string): string {
  const parts = jwt.split(".");
  if (parts.length < 2) return "";
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/"))) as {
      sub?: string;
    };
    return payload.sub ?? "";
  } catch {
    return "";
  }
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

/** Clear the persisted session and any half-finished sign-in. */
export function logout(): void {
  localStorage.removeItem(TOKEN_STORAGE_KEY);
  localStorage.removeItem(PENDING_STORAGE_KEY);
}
