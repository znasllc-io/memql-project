// App.tsx -- routes for the __PRODUCT__ shell.
//
// Public: /login (+ the /auth/callback magic-link landing routes here too).
// Protected (require a session): / (query round-trip) and /live (subscription).

import { Navigate, Route, Routes } from "react-router-dom";
import { SessionProvider, useSession } from "./context/Session";
import Login from "./pages/Login";
import Home from "./pages/Home";
import Live from "./pages/Live";

function RequireSession({ children }: { children: React.ReactNode }) {
  const { session } = useSession();
  if (!session) return <Navigate to="/login" replace />;
  return <>{children}</>;
}

export default function App() {
  return (
    <SessionProvider>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/auth/callback" element={<Login />} />
        <Route
          path="/"
          element={
            <RequireSession>
              <Home />
            </RequireSession>
          }
        />
        <Route
          path="/live"
          element={
            <RequireSession>
              <Live />
            </RequireSession>
          }
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </SessionProvider>
  );
}
