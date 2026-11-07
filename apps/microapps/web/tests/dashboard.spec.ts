import { test, expect } from "@playwright/test";
import { readFile } from "node:fs/promises";

const dashboardRoot = new URL(
  "../../../../hosts/nasa/services/updates-dashboard/",
  import.meta.url,
);
const sharedRoot = new URL("../src/shared/", import.meta.url);
const checkedAt = "2026-11-05T10:30:00Z";
const releases = [
  {
    name: "home-assistant",
    repository: "ghcr.io/home-assistant/home-assistant",
    currentTag: "2026.10.4",
    availableTag: "2026.11.0",
    status: "update",
    releaseNotesUrl: "https://example.test/release",
  },
  {
    name: "frigate",
    repository: "ghcr.io/blakeblackshear/frigate",
    currentTag: "0.17.2",
    availableTag: "0.17.2",
    status: "current",
  },
];
const status = {
  reports: {
    releases: { checkedAt, items: releases },
    digests: {
      checkedAt,
      items: releases.map((item) => ({ ...item, status: "current" })),
    },
    nix: {
      checkedAt,
      status: "ok",
      counts: { update: 2 },
      inputsChanged: true,
      hosts: [
        {
          name: "nasa",
          status: "ok",
          changes: "curl: 8.16.0 → 8.17.0\ngit: 2.51.0 → 2.51.1",
        },
      ],
    },
    actions: {
      checkedAt,
      items: [
        {
          name: "actions/checkout",
          currentRef: "v4",
          availableRef: "v5",
          status: "update",
        },
      ],
    },
  },
  actions: {
    csrfToken: "test-csrf",
    prConfigured: true,
    jobs: {},
    pullRequests: {},
  },
  history: [
    { checkedAt, title: "Containers", status: "ok", counts: { update: 1 } },
  ],
};

test("shared dashboard components, responsive tables, filters, and scan confirmation", async ({
  page,
}) => {
  const posts: unknown[] = [];
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("console", (msg) => {
    if (msg.type() === "error") pageErrors.push(msg.text());
  });
  await page.route("http://dashboard.test/**", async (route) => {
    const pathname = new URL(route.request().url()).pathname;
    if (pathname === "/api/session")
      return route.fulfill({ json: { csrf: "test-csrf" } });
    if (pathname === "/auth.js")
      return route.fulfill({
        contentType: "text/javascript",
        body: await readFile(
          new URL("../dist-auth/auth.js", import.meta.url),
          "utf8",
        ),
      });
    if (pathname === "/api/status") return route.fulfill({ json: status });
    if (pathname === "/api/actions") {
      expect(route.request().headers()["x-csrf-token"]).toBe("test-csrf");
      posts.push(route.request().postDataJSON());
      return route.fulfill({ json: { ok: true } });
    }
    if (pathname === "/component-shadow.css")
      return route.fulfill({
        contentType: "text/css",
        body: await readFile(
          new URL("component-shadow.css", sharedRoot),
          "utf8",
        ),
      });
    if (pathname === "/styles.css") {
      const parts = await Promise.all([
        readFile(new URL("tokens.css", sharedRoot), "utf8"),
        readFile(new URL("components.css", sharedRoot), "utf8"),
        readFile(new URL("styles.css", dashboardRoot), "utf8"),
      ]);
      return route.fulfill({ contentType: "text/css", body: parts.join("\n") });
    }
    if (
      [
        "/icon.svg",
        "/icon-192.png",
        "/icon-512.png",
        "/manifest.webmanifest",
      ].includes(pathname)
    ) {
      return route.fulfill({
        contentType: pathname.endsWith(".svg")
          ? "image/svg+xml"
          : pathname.endsWith(".png")
            ? "image/png"
            : "application/manifest+json",
        body: await readFile(new URL("public" + pathname, dashboardRoot)),
      });
    }
    const file = pathname === "/" ? "index.html" : pathname.slice(1);
    if (!["index.html", "app.js", "components.js"].includes(file))
      return route.abort();
    return route.fulfill({
      headers: {
        "Content-Security-Policy": "default-src 'self'; style-src 'self'",
      },
      contentType: file.endsWith("js") ? "text/javascript" : "text/html",
      body: await readFile(
        new URL(file, file === "components.js" ? sharedRoot : dashboardRoot),
        "utf8",
      ),
    });
  });
  await page.goto("http://dashboard.test/");
  await expect(
    page.getByRole("heading", { name: "System updates" }),
  ).toBeVisible();
  const containerSection = page.getByRole("region", {
    name: "Containers",
    exact: true,
  });
  await expect(
    containerSection.getByText("Changes", { exact: true }),
  ).toBeVisible();
  await expect(
    containerSection.getByRole("button", { name: "Run scan" }),
  ).toBeVisible();
  await expect(
    containerSection.getByRole("button", { name: "Updates", exact: true }),
  ).toBeVisible();
  const containers = containerSection.getByRole("table", {
    name: "Container versions",
  });
  await expect(
    containers.getByText("Home Assistant", { exact: true }),
  ).toBeVisible();
  await expect(containers.getByText("Frigate", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "All", exact: true }).click();
  await expect(containers.getByText("Frigate", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Attention", exact: true }).click();
  await expect(page.getByText("No errors", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Updates", exact: true }).click();
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme });
    for (const width of [320, 390, 1100]) {
      await page.setViewportSize({ width, height: 844 });
      expect(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      ).toBe(true);
      await expect(page.locator("app-toolbar")).toHaveCSS(
        "background-color",
        colorScheme === "dark" ? "rgb(16, 30, 48)" : "rgb(245, 247, 250)",
      );
      for (const button of await page.getByRole("button").all()) {
        expect((await button.boundingBox())!.height).toBeGreaterThanOrEqual(44);
      }
      await page.screenshot({
        path: `/tmp/updates-${width}-${colorScheme}.png`,
        fullPage: true,
      });
    }
  }
  const scanHistory = page.locator("details");
  await expect(scanHistory).not.toHaveAttribute("open");
  await scanHistory.locator("summary").focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("table", { name: "Scan history" })).toBeVisible();
  await page.getByRole("button", { name: "All", exact: true }).click();
  await expect(scanHistory).toHaveAttribute("open");
  const nixSection = page.getByRole("region", { name: "Nix package forecast" });
  await nixSection.getByRole("button", { name: "Run scan" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  expect(posts).toEqual([]);
  await nixSection.getByRole("button", { name: "Run scan" }).click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Run scan" })
    .click();
  await expect.poll(() => posts).toEqual([{ action: "scan", target: "nix" }]);
  expect(pageErrors).toEqual([]);
});
