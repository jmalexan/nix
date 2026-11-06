import React, { useEffect, useRef, useState } from "react";
import { api } from "./api-client";
import { Button, Icon } from "./shared/react";

type SetupState = "checking" | "needed" | "enabled" | "denied" | "unsupported";
const supported = () =>
  "Notification" in window &&
  "PushManager" in window &&
  "serviceWorker" in navigator;

export function NotificationSetup({
  csrf,
  publicKey,
}: {
  csrf: string;
  publicKey: string;
}) {
  const [state, setState] = useState<SetupState>("checking");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const operation = useRef(0);
  const enabling = useRef(false);
  useEffect(() => {
    if (!publicKey) return;
    let cancelled = false;
    async function check() {
      if (enabling.current) return;
      const current = ++operation.current;
      try {
        let next: SetupState = "needed";
        if (!supported()) next = "unsupported";
        else if (Notification.permission === "denied") next = "denied";
        else if (Notification.permission === "granted") {
          await navigator.serviceWorker.register("/sw.js");
          const registration = await navigator.serviceWorker.ready;
          const subscription = await registration.pushManager.getSubscription();
          if (cancelled) return;
          if (subscription) {
            // Reconcile an existing browser subscription with server storage.
            await api("/subscriptions", subscription.toJSON(), csrf);
            next = "enabled";
          }
        }
        if (!cancelled && current === operation.current) setState(next);
      } catch {
        if (!cancelled && current === operation.current) setState("needed");
      }
    }
    const onVisible = () => {
      if (!document.hidden) void check();
    };
    void check();
    window.addEventListener("focus", onVisible);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      cancelled = true;
      window.removeEventListener("focus", onVisible);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [csrf, publicKey]);

  async function enable() {
    enabling.current = true;
    ++operation.current;
    setBusy(true);
    setError("");
    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setState(permission === "denied" ? "denied" : "needed");
        return;
      }
      await navigator.serviceWorker.register("/sw.js");
      const registration = await navigator.serviceWorker.ready;
      const raw = atob(
        publicKey.replace(/-/g, "+").replace(/_/g, "/") +
          "=".repeat((4 - (publicKey.length % 4)) % 4),
      );
      const subscription =
        (await registration.pushManager.getSubscription()) ||
        (await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: Uint8Array.from(raw, (c) => c.charCodeAt(0)),
        }));
      await api("/subscriptions", subscription.toJSON(), csrf);
      setState("enabled");
    } catch (e) {
      setError(
        e instanceof Error
          ? e.message
          : "Could not enable notifications. Try again.",
      );
    } finally {
      enabling.current = false;
      setBusy(false);
    }
  }

  if (!publicKey || state === "checking" || state === "enabled") return null;
  return (
    <aside className="notification-setup" aria-label="Notification setup">
      {state === "needed" ? (
        <Button
          className="notification-enable"
          disabled={busy}
          onClick={enable}
        >
          <Icon name="bell" />
          {busy ? "Enabling…" : "Enable notifications"}
        </Button>
      ) : (
        <p className="notification-help ui-panel">
          <Icon name="bell" />
          {state === "denied"
            ? "Allow notifications for Approve in Settings."
            : "For notifications, add Approve to your Home Screen and open it there."}
        </p>
      )}
      {error && (
        <p role="alert" className="ui-message">
          {error}
        </p>
      )}
    </aside>
  );
}
