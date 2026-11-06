import { test, expect, type Page } from "@playwright/test";

// Browser API doubles exercise setup state, not real push delivery or iPhone installation.
async function notificationBrowser(
  page: Page,
  permission: NotificationPermission,
  subscribed = false,
  supported = true,
) {
  await page.addInitScript(
    ({ permission, subscribed, supported }) => {
      const key = "notification-test-state";
      if (!localStorage.getItem(key))
        localStorage.setItem(key, JSON.stringify({ permission, subscribed }));
      const read = () => JSON.parse(localStorage.getItem(key)!);
      if (!supported) {
        delete (window as any).Notification;
        return;
      }
      Object.defineProperty(window, "Notification", {
        configurable: true,
        value: {
          get permission() {
            return read().permission;
          },
          async requestPermission() {
            localStorage.setItem(
              key,
              JSON.stringify({ ...read(), permission: "granted" }),
            );
            return "granted";
          },
        },
      });
      Object.defineProperty(window, "PushManager", {
        configurable: true,
        value: class {},
      });
      const subscription = {
        toJSON: () => ({
          endpoint: "https://fcm.googleapis.com/fcm/send/test",
          keys: { p256dh: "test", auth: "test" },
        }),
      };
      const registration = {
        pushManager: {
          async getSubscription() {
            return read().subscribed ? subscription : null;
          },
          async subscribe(options: PushSubscriptionOptionsInit) {
            if (!options.userVisibleOnly || !options.applicationServerKey)
              throw new Error("Missing push options");
            localStorage.setItem(
              key,
              JSON.stringify({ ...read(), subscribed: true }),
            );
            return subscription;
          },
        },
      };
      Object.defineProperty(navigator, "serviceWorker", {
        configurable: true,
        value: {
          register: async () => registration,
          ready: Promise.resolve(registration),
        },
      });
    },
    { permission, subscribed, supported },
  );
  await page.route("**/api/session", (route) =>
    route.fulfill({
      json: { csrf: "notification-csrf", vapid_public: "BAAA" },
    }),
  );
  await page.route("**/api/requests", (route) => route.fulfill({ json: [] }));
}

for (const permission of ["default", "granted"] as const) {
  test(`setup needed without subscription, even with ${permission} permission`, async ({
    page,
  }) => {
    await notificationBrowser(page, permission);
    const subscriptions: unknown[] = [];
    await page.route("**/api/subscriptions", (route) => {
      expect(route.request().headers()["x-csrf-token"]).toBe(
        "notification-csrf",
      );
      subscriptions.push(route.request().postDataJSON());
      return route.fulfill({ json: { ok: true } });
    });
    await page.goto("/");
    await page.getByRole("button", { name: "Enable notifications" }).click();
    await expect(
      page.getByRole("complementary", { name: "Notification setup" }),
    ).toHaveCount(0);
    expect(subscriptions).toHaveLength(1);
    await page.reload();
    await expect.poll(() => subscriptions.length).toBe(2);
    await expect(
      page.getByRole("complementary", { name: "Notification setup" }),
    ).toHaveCount(0);
    await page.getByRole("button", { name: "Settings" }).click();
    await expect(page.getByRole("button", { name: "Sign out" })).toBeVisible();
    await expect(
      page.getByRole("button", { name: /notifications/i }),
    ).toHaveCount(0);
  });
}

test("existing subscription is reconciled; failed saves remain retryable", async ({
  page,
}) => {
  await notificationBrowser(page, "granted", true);
  let fail = true;
  let saved = 0;
  await page.route("**/api/subscriptions", (route) => {
    if (fail)
      return route.fulfill({ status: 503, json: { detail: "Try again" } });
    saved++;
    return route.fulfill({ json: { ok: true } });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Enable notifications" }).click();
  await expect(page.getByRole("alert")).toHaveText("Try again");
  fail = false;
  await page.getByRole("button", { name: "Enable notifications" }).click();
  await expect(
    page.getByRole("complementary", { name: "Notification setup" }),
  ).toHaveCount(0);
  expect(saved).toBe(1);
});

for (const state of ["denied", "unsupported"] as const) {
  test(`setup guidance when notifications are ${state}`, async ({ page }) => {
    await notificationBrowser(
      page,
      state === "denied" ? "denied" : "default",
      false,
      state !== "unsupported",
    );
    await page.goto("/");
    const helper = page.getByRole("complementary", {
      name: "Notification setup",
    });
    await expect(helper).toContainText(
      state === "denied" ? "Settings" : "Home Screen",
    );
    await expect(helper.getByRole("button")).toHaveCount(0);
  });
}
