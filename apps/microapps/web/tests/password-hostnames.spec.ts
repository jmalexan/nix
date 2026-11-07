import { test, expect } from "@playwright/test";

test("password sign-in stays on short HTTPS hostname and also works at the full hostname", async ({
  page,
  context,
}) => {
  const password = "a long password saved in Bitwarden";
  const changed = "a changed long password saved in Bitwarden";
  await page.goto("https://approve:5175/?request=example");
  await page.getByRole("button", { name: "Set up this app" }).click();
  await page.getByLabel("Setup code").fill("e".repeat(32));
  await page.getByLabel("New password", { exact: true }).fill(password);
  await page.getByLabel("Confirm password").fill(password);
  await page.getByRole("button", { name: "Create password" }).click();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  expect(new URL(page.url()).hostname).toBe("approve");
  await page.reload();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  const cookies = await context.cookies();
  const session = cookies.find((cookie) => cookie.name === "__Host-microapp");
  expect(session).toMatchObject({
    domain: "approve",
    secure: true,
    httpOnly: true,
    sameSite: "Strict",
  });

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
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Set password", exact: true }).click();
  await page.getByLabel("New password", { exact: true }).fill(changed);
  await page.getByLabel("Confirm password").fill(changed);
  await page.getByRole("button", { name: "Save password" }).click();
  await expect(page.getByRole("status")).toContainText("Password saved");

  await page.goto("https://approve:5175/");
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Incorrect password");
  await page.getByLabel("Password", { exact: true }).fill(changed);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  expect(new URL(page.url()).hostname).toBe("approve");
});
