import { test, expect } from "@playwright/test";

test("Backups shared account, short URLs, private reports, mobile layout and failed refresh", async ({
  page,
  context,
  request,
}) => {
  const origin = "https://backups:5177";
  const password = "one shared password for NASA apps";
  const probe = "https://localhost:5177";
  expect(
    (
      await request.get(probe + "/api/status", {
        headers: { Host: "backups:5177" },
      })
    ).status(),
  ).toBe(401);
  expect(
    (
      await request.get(probe + "/report.json", {
        headers: { Host: "backups:5177" },
      })
    ).status(),
  ).toBe(404);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(origin);
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Set up account" }),
  ).toBeHidden();
  await expect(
    page.getByRole("heading", { name: "Backup coverage" }),
  ).toHaveCount(0);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Storage and backups are healthy" }),
  ).toBeVisible();
  await expect(page).toHaveURL(origin + "/");
  await expect(
    page.getByRole("heading", { name: "Datasets and local snapshots" }),
  ).toBeVisible();
  await expect(page.getByText("Not configured", { exact: true })).toBeVisible();
  await expect(page.getByText("Not scheduled", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Recovery checks" }),
  ).toBeVisible();
  await page.getByText("How to check recovery", { exact: true }).click();
  await expect(
    page.getByText(/Restore a small selection of important files/),
  ).toBeVisible();
  await expect(
    page.getByText(/Running a check does not update this dashboard/),
  ).toBeVisible();
  await expect(page.getByText("1800 sec", { exact: true })).toBeVisible();
  await expect(
    page.getByText("Not stored in snapshot", { exact: true }),
  ).toHaveCount(2);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({ path: "/tmp/backups-mobile.png", fullPage: true });
  await page.reload();
  await expect(
    page.getByRole("heading", { name: "Storage and backups are healthy" }),
  ).toBeVisible();
  // The same account signs in at the full hostname, with a separate session.
  const full = await context.newPage();
  await full.goto("https://backups.example.test:5177");
  await expect(
    full.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  await full.getByLabel("Password", { exact: true }).fill(password);
  await full.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(
    full.getByRole("heading", { name: "Storage and backups are healthy" }),
  ).toBeVisible();
  await page.setViewportSize({ width: 1440, height: 1000 });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({ path: "/tmp/backups-desktop.png", fullPage: true });
  await page.route("**/api/status", (route) =>
    route.fulfill({ status: 503, body: "Unavailable" }),
  );
  await page.evaluate(() =>
    document.dispatchEvent(new Event("visibilitychange")),
  );
  await expect(page.getByRole("alert")).toContainText("may be out of date");
  await page.unroute("**/api/status");
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(async () => (await fetch("/api/status")).status),
  ).toBe(401);
  await full.reload();
  await expect(
    full.getByRole("heading", { name: "Storage and backups are healthy" }),
  ).toBeVisible();
});
