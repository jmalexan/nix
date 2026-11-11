// Run after starting previews; uses this checkout's Playwright dependency.
import { createRequire } from "node:module";
import { mkdir } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const require = createRequire(
  new URL("../../apps/microapps/web/package.json", import.meta.url),
);
const { chromium, expect } = require("@playwright/test");
const names = process.argv.slice(2);
if (!names.length) throw new Error("Pass one or more running preview names");
const output = process.env.PREVIEW_SCREENSHOTS || ".local/preview-screenshots";
await mkdir(output, { recursive: true });
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH,
  args: ["--no-sandbox", "--no-proxy-server"],
});
try {
  const context = await browser.newContext({ serviceWorkers: "block" });
  // For local verification before NASA's route is deployed. The browser retains
  // real HTTPS origins/cookies; only network transport goes through loopback.
  if (process.env.PREVIEW_ROUTER_URL) {
    await context.route(
      "https://*.preview.nasa.jmalexan.com/**",
      async (route) => {
        const url = new URL(route.request().url());
        const response = await route.fetch({
          url: process.env.PREVIEW_ROUTER_URL + url.pathname + url.search,
          headers: { ...route.request().headers(), host: url.host },
        });
        await route.fulfill({ response });
      },
    );
  }
  for (const name of names) {
    if (!/^[a-z][a-z0-9-]{0,39}$/.test(name))
      throw new Error("Invalid preview name");
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(String(error)));
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(`https://${name}.preview.nasa.jmalexan.com`);
    // A session in another preview must not sign this one in.
    await expect(page.getByLabel("Password", { exact: true })).toBeVisible();
    await page
      .getByLabel("Password", { exact: true })
      .fill("preview");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page.getByLabel("Password", { exact: true })).toHaveCount(0);
    expect(
      await page.evaluate(async () => (await fetch("/api/session")).status),
    ).toBe(200);
    await page.screenshot({
      path: `${output}/${name}-phone.png`,
      fullPage: true,
    });
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.screenshot({
      path: `${output}/${name}-desktop.png`,
      fullPage: true,
    });
    if (process.env.PREVIEW_REFRESH_CLI) {
      await page.waitForTimeout(2000);
      const reloaded = page.waitForEvent("load", { timeout: 60000 });
      await promisify(execFile)(process.env.PREVIEW_REFRESH_CLI, [
        "refresh",
        name,
      ]);
      await reloaded;
      console.log(`${name}: automatic reload after refresh passed`);
    }
    await page.reload();
    await expect(page.getByLabel("Password", { exact: true })).toHaveCount(0);
    expect(errors).toEqual([]);
    console.log(
      `${name}: sign-in, remembered session, separate origin, phone/desktop passed`,
    );
    await page.close();
  }
  await context.close();
} finally {
  await browser.close();
}
