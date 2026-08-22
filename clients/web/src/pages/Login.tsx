// pages/Login.tsx -- sign-in + the /auth/callback landing.
//
// Two modes in one route-aware component. With `?code=` in the URL this is the
// OAuth callback: identity has verified the emailed link on its own
// /auth/complete and 302'd the browser back here carrying an authorization code
// -- so exchange it. Without one, show the email form that starts the flow.
//
// NOTE the callback carries `code` + `state`, NOT the magic-link token itself.
// The token never reaches this app: it is consumed by identity, which is what
// lets the same click work whether the person is signing in to this SPA, the
// cockpit, or the portal (see lib/auth/identity.ts for the whole shape).

import { useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { completeLogin, startLogin } from "../lib/auth/identity";
import { useSession } from "../context/Session";

export default function Login() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { setSession } = useSession();
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "completing" | "error">("idle");
  const [error, setError] = useState("");

  const code = params.get("code");
  const state = params.get("state") ?? "";
  // The exchange spends a single-use code, so it must not run twice -- and
  // React StrictMode deliberately runs effects twice in development.
  const exchanged = useRef(false);

  useEffect(() => {
    if (!code || exchanged.current) return;
    exchanged.current = true;
    setStatus("completing");
    completeLogin(code, state)
      .then((session) => {
        setSession(session);
        navigate("/", { replace: true });
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setStatus("error");
      });
  }, [code, state, navigate, setSession]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus("sending");
    setError("");
    try {
      await startLogin(email);
      setStatus("sent");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      setStatus("error");
    }
  }

  if (code) {
    return (
      <main className="card">
        <h1>Signing you in…</h1>
        {status === "error" ? <p className="error">{error}</p> : <p>Completing your sign-in.</p>}
      </main>
    );
  }

  return (
    <main className="card">
      <h1>Sign in to __PRODUCT__</h1>
      {status === "sent" ? (
        <p>Check your email for a sign-in link.</p>
      ) : (
        <form onSubmit={onSubmit}>
          <label>
            Email
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
            />
          </label>
          <button type="submit" disabled={status === "sending"}>
            {status === "sending" ? "Sending…" : "Send sign-in link"}
          </button>
        </form>
      )}
      {status === "error" && <p className="error">{error}</p>}
    </main>
  );
}
