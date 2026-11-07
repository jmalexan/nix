import { test, expect } from "@playwright/test";
import { generateKeyPairSync } from "node:crypto";
test("password enrollment, remembered login, mobile resize, and one execution", async ({
  page,
  request,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await page.getByRole("button", { name: "Set up this app" }).click();
  await page.getByLabel("Setup code").fill("e".repeat(32));
  await page
    .getByLabel("New password", { exact: true })
    .fill("a long password saved in Bitwarden");
  await page
    .getByLabel("Confirm password")
    .fill("a long password saved in Bitwarden");
  await page.getByRole("button", { name: "Create password" }).click();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  const response = await request.post("/api/requests", {
    headers: { Authorization: "Bearer " + "r".repeat(32) },
    data: {
      operation: "demo.verify",
      reason: "Verify a request stays selected when the screen expands.",
    },
  });
  expect(response.status()).toBe(201);
  const item = await response.json();
  await expect(
    page.getByRole("button", { name: /Permission check/ }),
  ).toBeVisible({ timeout: 10000 });
  await page.getByRole("button", { name: /Permission check/ }).click();
  await expect(
    page.getByRole("button", { name: "Approve", exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.setViewportSize({ width: 900, height: 700 });
  await expect(page.getByText(item.reason)).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({
    path: "/tmp/microapps-approvals.png",
    fullPage: true,
  });
  await page.getByRole("button", { name: "Approve", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Approve", exact: true }),
  ).toHaveCount(0);
  expect(
    (
      await request.post(`/api/worker/${item.id}/verify`, {
        headers: { Authorization: "Bearer " + "w".repeat(32) },
      })
    ).status(),
  ).toBe(200);
  expect(
    (
      await request.post(`/api/worker/${item.id}/verify`, {
        headers: { Authorization: "Bearer " + "w".repeat(32) },
      })
    ).status(),
  ).toBe(409);
  await page.reload();
  await expect(page.getByRole("button", { name: "Settings" })).toBeVisible();
  const { publicKey } = generateKeyPairSync("ed25519");
  const jwk = publicKey.export({ format: "jwk" });
  const keyBytes = Buffer.from(jwk.x!, "base64url");
  const blob = Buffer.concat([
    Buffer.from([0, 0, 0, 11]),
    Buffer.from("ssh-ed25519"),
    Buffer.from([0, 0, 0, 32]),
    keyBytes,
  ]);
  const connection = await request.post("/api/requests", {
    headers: { Authorization: "Bearer " + "r".repeat(32) },
    data: {
      operation: "ssh.connect",
      reason: "Inspect filesystem permissions",
      connection: { public_key: "ssh-ed25519 " + blob.toString("base64") },
    },
  });
  expect(connection.status()).toBe(201);
  const sshItem = await connection.json();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`/?request=${sshItem.id}`);
  await expect(
    page.getByRole("heading", { name: "NASA connection" }),
  ).toBeVisible();
  await expect(page.getByText("1 connection · 15 min")).toBeVisible();
  await expect(
    page.getByText("nasa-automation", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText("Read-only · No sudo")).toBeVisible();
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme });
    await expect(page.locator("app-toolbar")).toHaveCSS(
      "background-color",
      colorScheme === "dark" ? "rgb(16, 30, 48)" : "rgb(245, 247, 250)",
    );
    const approve = page.getByRole("button", { name: "Approve", exact: true });
    expect((await approve.boundingBox())!.height).toBeGreaterThanOrEqual(44);
    await page.screenshot({ path: `/tmp/approvals-phone-${colorScheme}.png` });
  }
  await page.getByRole("button", { name: "Requests", exact: true }).click();
  await expect(
    page.getByRole("button", { name: /NASA connection/ }),
  ).toBeVisible();
  await page.getByRole("button", { name: /NASA connection/ }).click();
  await page.setViewportSize({ width: 1100, height: 800 });
  await page.screenshot({ path: "/tmp/approvals-desktop-dark.png" });
  await page.setViewportSize({ width: 390, height: 844 });

  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.getByRole("button", { name: "Approve", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Approve", exact: true }),
  ).toHaveCount(0);
  const claimed = await request.post(`/api/gate/${sshItem.id}/claim`, {
    headers: { Authorization: "Bearer " + "g".repeat(32) },
  });
  expect(claimed.status()).toBe(200);
  await expect(page.getByText(/Ends by/)).toBeVisible({
    timeout: 10000,
  });
  await page.screenshot({
    path: "/tmp/microapps-connection.png",
    fullPage: true,
  });
  const pushScope = {
    repository: "owner/project",
    branch: "robot/browser-test",
    commit: "a".repeat(40),
    expected: "0".repeat(40),
  };
  const pushRequest = await request.post("/api/requests", {
    headers: { Authorization: "Bearer " + "r".repeat(32) },
    data: {
      operation: "git.push",
      reason: "Publish browser-tested change",
      push: pushScope,
    },
  });
  expect(pushRequest.status()).toBe(201);
  const pushItem = await pushRequest.json();
  await page.goto(`/?request=${pushItem.id}`);
  await expect(
    page.getByRole("heading", { name: "Git push", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("owner/project", { exact: true })).toBeVisible();
  await expect(page.getByText(pushScope.commit, { exact: true })).toBeVisible();
  await expect(page.getByText("New branch", { exact: true })).toBeVisible();
  await page.setViewportSize({ width: 320, height: 740 });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({ path: "/tmp/approve-git-push.png", fullPage: true });
  await page.getByRole("button", { name: "Approve", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Approve", exact: true }),
  ).toHaveCount(0);
  const pushClaim = await request.post(`/api/git-broker/${pushItem.id}/claim`, {
    headers: { Authorization: "Bearer " + "b".repeat(32) },
    data: pushScope,
  });
  expect(pushClaim.status()).toBe(200);
  expect(
    (
      await request.post(`/api/git-broker/${pushItem.id}/claim`, {
        headers: { Authorization: "Bearer " + "b".repeat(32) },
        data: pushScope,
      })
    ).status(),
  ).toBe(409);
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(
    page.getByRole("button", { name: "Sign in", exact: true }),
  ).toBeVisible();
});
