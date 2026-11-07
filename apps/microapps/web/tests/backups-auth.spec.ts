import { test, expect } from "@playwright/test";

test("Backups passkey, private reports, mobile layout and failed refresh", async ({
  page,
  context,
  request,
}) => {
  const origin = "http://localhost:5175";
  expect((await request.get(origin + "/api/status")).status()).toBe(401);
  expect((await request.get(origin + "/report.json")).status()).toBe(404);
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(origin);
  await expect(
    page.getByRole("button", { name: "Sign in with passkey" }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Backup coverage" }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Set up this app" }).click();
  await page.getByLabel("Setup code").fill("b".repeat(32));
  await page.getByRole("button", { name: "Create passkey" }).click();
  await expect(page.getByRole("status")).toContainText("Passkey created");
  await page.getByRole("button", { name: "Sign in with passkey" }).click();
  await expect(
    page.getByRole("heading", { name: "Protection is current" }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Datasets and local snapshots" }),
  ).toBeVisible();
  await expect(
    page.getByText("No restore test recorded", { exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({ path: "/tmp/backups-mobile.png", fullPage: true });
  await page.reload();
  await expect(
    page.getByRole("heading", { name: "Protection is current" }),
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
    page.getByRole("button", { name: "Sign in with passkey" }),
  ).toBeVisible();
  expect(
    await page.evaluate(async () => (await fetch("/api/status")).status),
  ).toBe(401);
});
