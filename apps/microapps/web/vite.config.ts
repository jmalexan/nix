import { defineConfig } from "vite";
export default defineConfig({
  // Shadow-root styles must remain same-origin assets under the production CSP.
  build: { assetsInlineLimit: 0 },
  server: {
    port: 5173,
    proxy: {
      "/api": { target: "http://localhost:8092" },
      "/health": { target: "http://localhost:8092" },
    },
  },
});
