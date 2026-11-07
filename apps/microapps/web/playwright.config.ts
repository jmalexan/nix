import { defineConfig } from "@playwright/test";
import { fileURLToPath } from "node:url";
export default defineConfig({
  testDir: "tests",
  workers: 1,
  use: {
    baseURL: "http://localhost:5173",
    ignoreHTTPSErrors: true,
    launchOptions: {
      executablePath: process.env.CHROMIUM_PATH,
      args: [
        "--no-sandbox",
        "--no-proxy-server",
        "--host-resolver-rules=MAP approve 127.0.0.1, MAP approve.example.test 127.0.0.1, MAP updates 127.0.0.1, MAP updates.example.test 127.0.0.1",
      ],
    },
  },
  webServer: [
    {
      command: "python ../backend/tests/serve_password.py",
      env: {
        PYTHONPATH: fileURLToPath(new URL("../backend", import.meta.url)),
      },
      port: 5175,
      reuseExistingServer: false,
    },
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
