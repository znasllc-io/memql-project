// pages/Login.tsx -- the magic-link login screen + the /auth/callback handler.
//
// Two modes in one route-aware component: if the URL carries a `?token=` (the
// magic-link landing), complete the login; otherwise show the email form that
// requests a link.

import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { completeLogin, requestMagicLink } from "../lib/auth/identity";
import { useSession } from "../context/Session";

export default function Login() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { setSession } = useSession();
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<"idle" | "sending" | "sent" | "completing" | "error">("idle");
  const [error, setError] = useState("");

  const linkToken = params.get("token");

  useEffect(() => {
    if (!linkToken) return;
    setStatus("completing");
    completeLogin(linkToken)
      .then((session) => {
        setSession(session);
        navigate("/", { replace: true });
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setStatus("error");
      });
  }, [linkToken, navigate, setSession]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus("sending");
    setError("");
    try {
      await requestMagicLink(email);
      setStatus("sent");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      setStatus("error");
    }
  }

  if (linkToken) {
    return (
      <main className="card">
        <h1>Signing you in…</h1>
        {status === "error" ? <p className="error">{error}</p> : <p>Completing your magic link.</p>}
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
            {status === "sending" ? "Sending…" : "Send magic link"}
          </button>
        </form>
      )}
      {status === "error" && <p className="error">{error}</p>}
    </main>
  );
}
