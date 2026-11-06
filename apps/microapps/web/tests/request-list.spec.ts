import { test, expect } from "@playwright/test";
import type { components } from "../src/api";

test("pending inbox, expandable history, active connections, and deep links", async ({
  page,
}) => {
  const now = Math.floor(Date.now() / 1000);
  const requests: components["schemas"]["RequestView"][] = [
    {
      id: "pending",
      operation: "ssh.connect",
      state: "pending",
      reason: "Inspect the host",
      requester: "robots",
      created: now,
      expires: now + 600,
      result: null,
    },
    {
      id: "active",
      operation: "ssh.connect",
      state: "claimed",
      reason: "Check service status",
      requester: "robots",
      created: now - 30,
      expires: now + 600,
      result: null,
    },
    {
      id: "old",
      operation: "demo.verify",
      state: "completed",
      reason: "An earlier check",
      requester: "robots",
      created: now - 60,
      expires: now + 600,
      result: "Verified",
    },
  ];
  await page.clock.install();
  await page.route("**/api/session", (route) =>
    route.fulfill({ json: { csrf: "test", vapid_public: "" } }),
  );
  await page.route("**/api/requests", (route) =>
    route.fulfill({ json: requests }),
  );
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  const history = page
    .locator("details")
    .filter({ has: page.locator("summary", { hasText: "History" }) });
  const progress = page
    .locator("details")
    .filter({ has: page.locator("summary", { hasText: "In progress" }) });
  await expect(page.locator(".request:visible")).toHaveCount(1);
  await expect(history).not.toHaveAttribute("open");
  await expect(progress).not.toHaveAttribute("open");
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme });
    for (const width of [320, 390]) {
      await page.setViewportSize({ width, height: 844 });
      const padding = await page
        .locator(".request")
        .first()
        .evaluate((button) => {
          const row = button.getBoundingClientRect();
          return [
            button.firstElementChild!.getBoundingClientRect().left - row.left,
            row.right - button.lastElementChild!.getBoundingClientRect().right,
          ];
        });
      expect(Math.min(...padding)).toBeGreaterThanOrEqual(16);
      expect(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      ).toBe(true);
      await page.screenshot({
        path: `/tmp/approvals-inbox-${width}-${colorScheme}.png`,
      });
    }
  }
  await history.locator("summary").click();
  await expect(
    history.getByRole("button", { name: /Permission check/ }),
  ).toBeVisible();
  requests[2].reason = "Updated on refresh";
  await page.clock.fastForward(5000);
  await expect(history).toHaveAttribute("open");
  await history.getByRole("button").click();
  await expect(page.getByText("Updated on refresh")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Approve", exact: true }),
  ).toHaveCount(0);
  await page.goto("/?request=old");
  await expect(page.getByText("Updated on refresh")).toBeVisible();
  await page.getByRole("button", { name: "Requests", exact: true }).click();
  await expect(history).toHaveAttribute("open");
  await progress.locator("summary").click();
  await expect(progress.getByRole("button")).toBeVisible();
  await page.locator(".request-list > ul .request").click();
  await expect(
    page.getByRole("button", { name: "Approve", exact: true }),
  ).toBeVisible();
  requests[0].state = "expired";
  await page.clock.fastForward(5000);
  await expect(
    page.getByRole("button", { name: "Approve", exact: true }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Requests", exact: true }).click();
  await expect(
    page.getByText("No pending requests", { exact: true }),
  ).toBeVisible();
  await expect(history.getByRole("button")).toHaveCount(2);
});
