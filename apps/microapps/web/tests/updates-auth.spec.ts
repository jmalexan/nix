import { test, expect } from "@playwright/test";

test("Updates password enrollment, remembered session, protected actions and logout", async ({
  page,
  request,
}) => {
  const origin = "http://localhost:5174";
  expect((await request.get(origin + "/api/status")).status()).toBe(401);
  expect(
    (await request.get(origin + "/pipeline/reports/nix.json")).status(),
  ).toBe(401);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(origin);
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Run scan", exact: true }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Set up this app" }).click();
  await page.getByLabel("Setup code").fill("u".repeat(32));
  await page
    .getByLabel("New password", { exact: true })
    .fill("a long password saved in Bitwarden");
  await page
    .getByLabel("Confirm password")
    .fill("a long password saved in Bitwarden");
  await page.getByRole("button", { name: "Create password" }).click();
  await expect(
    page.getByRole("button", { name: "Sign out", exact: true }),
  ).toBeVisible();
  const response = page.waitForResponse((r) =>
    r.url().endsWith("/api/actions"),
  );
  await page
    .getByRole("button", { name: "Run scan", exact: true })
    .first()
    .click();
  expect((await response).status()).toBe(202);
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Sign out", exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({
    path: "/tmp/updates-authenticated.png",
    fullPage: true,
  });
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(async () => (await fetch("/api/status")).status),
  ).toBe(401);
  await page.screenshot({ path: "/tmp/updates-signin.png", fullPage: true });
});
