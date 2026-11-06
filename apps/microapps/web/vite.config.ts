import { defineConfig } from "vite";
export default defineConfig({
  server: {
    port: 5173,
    proxy: {
      "/api": { target: "http://localhost:8092" },
      "/health": { target: "http://localhost:8092" },
    },
  },
});
