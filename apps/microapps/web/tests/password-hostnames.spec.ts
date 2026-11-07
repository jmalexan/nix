import { test, expect } from "@playwright/test";

test("one account signs in directly to both tools and short/full HTTPS hostnames", async ({
  page,
  context,
}) => {
  const password = "one account password saved in Bitwarden";
  await page.goto("https://approve:5175/?request=example");
  await page
    .getByRole("button", { name: "Set up account", exact: true })
    .click();
  await page.getByLabel("Setup code").fill("e".repeat(32));
  await page.getByLabel("New password", { exact: true }).fill(password);
  await page.getByLabel("Confirm password").fill(password);
  await page
    .locator("#password-enroll")
    .getByRole("button", { name: "Create account" })
    .click();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  expect(new URL(page.url()).hostname).toBe("approve");
  await page.reload();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  const session = (await context.cookies()).find(
    (cookie) => cookie.name === "__Host-microapp",
  );
  expect(session).toMatchObject({
    domain: "approve",
    secure: true,
    httpOnly: true,
    sameSite: "Strict",
  });
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(
    page.getByRole("button", { name: "Set password", exact: true }),
  ).toHaveCount(0);

  await page.goto("https://updates:5176/");
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Set up account", exact: true }),
  ).toBeHidden();
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Sign out", exact: true }),
  ).toBeVisible();
  expect(new URL(page.url()).hostname).toBe("updates");
  await expect(
    page.getByRole("button", { name: "Set password", exact: true }),
  ).toHaveCount(0);
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Sign out", exact: true }),
  ).toBeVisible();

  await page.goto("https://approve.example.test:5175/");
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Password", { exact: true })).toHaveAttribute(
    "autocomplete",
    "current-password",
  );
  await expect(
    page.getByLabel("Username", { exact: true }).first(),
  ).toHaveAttribute("autocomplete", "username");
  await page.getByLabel("Password", { exact: true }).fill("incorrect password");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Incorrect password");
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Sign out", exact: true }).click();

  // Signing out of one app does not revoke the other app's host-only session.
  await page.goto("https://updates:5176/");
  await expect(
    page.getByRole("button", { name: "Sign out", exact: true }),
  ).toBeVisible();
  await page.goto("https://updates.example.test:5176/");
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Sign out", exact: true }),
  ).toBeVisible();
});
