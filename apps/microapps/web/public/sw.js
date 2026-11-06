// No authenticated responses or decisions are cached or queued offline.
self.addEventListener("push", (event) => {
  const data = event.data?.json() || {};
  event.waitUntil(
    self.registration.showNotification("Approval requested", {
      body: "Open Approvals to review a pending request.",
      icon: "/icon-192.png",
      tag: data.request_id || "approvals",
      data: { request_id: data.request_id },
    }),
  );
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const id = event.notification.data?.request_id;
  const url = new URL("/", self.location.origin);
  if (typeof id === "string") url.searchParams.set("request", id);
  event.waitUntil(clients.openWindow(url.href));
});
