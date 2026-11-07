import { defineConfig } from "vite";
export default defineConfig({
  build: {
    outDir: "dist-auth",
    lib: {
      entry: "src/shared/auth-panel.ts",
      formats: ["es"],
      fileName: () => "auth.js",
    },
  },
});
