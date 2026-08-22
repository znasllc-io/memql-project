import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite config for the __PRODUCT__ "web" client surface. In dev, /memql is
// proxied to the bff so the browser talks SAME-ORIGIN -- which is what the app
// assumes everywhere (see MemqlClientOptions.httpUrl); in a cluster the
// app.<domain> Ingress does the same routing.
//
// The proxy TARGET is a dev-server-only value, and bff.<domain> is the right
// one LOCALLY: the local front door serves the bff's HTTP surface there. The
// cloud entry does not (that host is raw gRPC), which is exactly why the app
// itself must not name it.
const MEMQL_HTTP_URL = process.env.MEMQL_HTTP_URL ?? "https://bff.__DOMAIN__";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@": "/src" },
  },
  server: {
    host: "0.0.0.0",
    port: 8080,
    proxy: {
      "/memql": { target: MEMQL_HTTP_URL, changeOrigin: true, secure: false, ws: true },
    },
  },
  build: {
    outDir: "dist",
    sourcemap: true,
  },
});
