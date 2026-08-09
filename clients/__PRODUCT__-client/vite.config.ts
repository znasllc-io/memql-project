import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Vite config for the __PRODUCT__ shell. In dev, /memql is proxied to the bff
// front door (MEMQL_HTTP_URL, default https://bff.__DOMAIN__) so the browser
// talks same-origin; in the built image the ingress does the routing.
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
