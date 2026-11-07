import { defineConfig } from "@playwright/test";
import { fileURLToPath } from "node:url";
export default defineConfig({
  testDir: "tests",
  workers: 1,
  use: {
    baseURL: "http://localhost:5173",
    launchOptions: {
      executablePath: process.env.CHROMIUM_PATH,
      args: ["--no-sandbox"],
    },
  },
  webServer: [
    {
      command: "python ../backend/tests/serve.py",
      env: {
        PYTHONPATH: fileURLToPath(new URL("../backend", import.meta.url)),
      },
      url: "http://localhost:5173/health",
      reuseExistingServer: false,
    },
    {
      command: "python ../backend/tests/serve_updates.py",
      env: {
        PYTHONPATH: fileURLToPath(new URL("../backend", import.meta.url)),
      },
      url: "http://localhost:5174/health",
      reuseExistingServer: false,
    },
  ],
});
