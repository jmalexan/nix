import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  IonApp,
  IonButton,
  IonContent,
  IonHeader,
  IonPage,
  IonTitle,
  IonToolbar,
  setupIonicReact,
} from "@ionic/react";
import {
  startAuthentication,
  startRegistration,
} from "@simplewebauthn/browser";
import "@ionic/react/css/core.css";
import "@ionic/react/css/normalize.css";
import "@ionic/react/css/structure.css";
import "@ionic/react/css/typography.css";
import "./theme.css";
import type { components } from "./api";

type Approval = components["schemas"]["RequestView"];
type Session = components["schemas"]["SessionView"];
setupIonicReact();
async function api<T>(path: string, body?: unknown, csrf?: string): Promise<T> {
  const response = await fetch("/api" + path, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      ...(csrf ? { "X-CSRF-Token": csrf } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    const value = await response.json();
    throw new Error(
      typeof value.detail === "string"
        ? value.detail
        : "Request could not be completed",
    );
  }
  return response.json();
}
function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [requests, setRequests] = useState<Approval[]>([]);
  const [selected, setSelected] = useState<string | null>(
    new URLSearchParams(location.search).get("request"),
  );
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [ready, setReady] = useState(false);
  const [enrolling, setEnrolling] = useState(false);
  const [token, setToken] = useState("");
  const [notice, setNotice] = useState("");
  async function refresh() {
    setRequests(await api<Approval[]>("/requests"));
  }
  useEffect(() => {
    api<Session>("/session")
      .then(setSession)
      .catch(() => {})
      .finally(() => setReady(true));
    if ("serviceWorker" in navigator)
      navigator.serviceWorker.register("/sw.js").catch(() => {});
  }, []);
  useEffect(() => {
    if (!session) return;
    refresh().catch((e) => setError(e.message));
    const timer = setInterval(
      () => refresh().catch((e) => setError(e.message)),
      5000,
    );
    return () => clearInterval(timer);
  }, [session]);
  async function run(fn: () => Promise<void>) {
    setBusy(true);
    setError("");
    try {
      await fn();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Unable to connect");
    } finally {
      setBusy(false);
    }
  }
  async function login() {
    await run(async () => {
      const ceremony = await api<{
        challenge_id: string;
        options: Parameters<typeof startAuthentication>[0]["optionsJSON"];
      }>("/auth/login/options", {});
      const credential = await startAuthentication({
        optionsJSON: ceremony.options,
      });
      await api("/auth/login/verify", {
        challenge_id: ceremony.challenge_id,
        credential,
      });
      setSession(await api<Session>("/session"));
      setNotice("");
    });
  }
  async function enroll() {
    await run(async () => {
      const ceremony = await api<{
        challenge_id: string;
        options: Parameters<typeof startRegistration>[0]["optionsJSON"];
      }>("/auth/enroll/options", { token });
      const credential = await startRegistration({
        optionsJSON: ceremony.options,
      });
      await api("/auth/enroll/verify", {
        challenge_id: ceremony.challenge_id,
        credential,
      });
      setToken("");
      setEnrolling(false);
      setNotice("Passkey created. Sign in to continue.");
    });
  }
  async function notifications() {
    await run(async () => {
      if (!("PushManager" in window))
        throw new Error(
          "Add this app to your Home Screen, then open it there to enable notifications.",
        );
      const permission = await Notification.requestPermission();
      if (permission !== "granted")
        throw new Error(
          "Notifications were not enabled. You can change permission in Settings.",
        );
      const registration = await navigator.serviceWorker.ready;
      const key = session!.vapid_public;
      const raw = atob(
        key.replace(/-/g, "+").replace(/_/g, "/") +
          "=".repeat((4 - (key.length % 4)) % 4),
      );
      const subscription =
        (await registration.pushManager.getSubscription()) ||
        (await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: Uint8Array.from(raw, (c) => c.charCodeAt(0)),
        }));
      await api("/subscriptions", subscription.toJSON(), session!.csrf);
      setNotice("Notifications enabled on this device.");
    });
  }
  const active = requests.find((r) => r.id === selected);
  return (
    <IonApp>
      <IonPage>
        <IonHeader>
          <IonToolbar>
            <IonTitle>Approvals</IonTitle>
          </IonToolbar>
        </IonHeader>
        <IonContent>
          <main>
            <div className="intro">
              <h1>Review access requests</h1>
              <p>
                Review what is being requested before allowing it to proceed.
              </p>
            </div>
            {error && (
              <p role="alert" className="error">
                {error}
              </p>
            )}
            {notice && (
              <p role="status" className="notice">
                {notice}
              </p>
            )}
            {!ready ? (
              <p>Checking your session…</p>
            ) : !session ? (
              <section className="signin">
                <h2>Welcome back</h2>
                <p>
                  Use your passkey to sign in. This device will remember you for
                  30 days.
                </p>
                <IonButton disabled={busy} onClick={login}>
                  Sign in with passkey
                </IonButton>
                <button
                  className="text-button"
                  onClick={() => setEnrolling(!enrolling)}
                >
                  Set up this app
                </button>
                {enrolling && (
                  <form
                    onSubmit={(e) => {
                      e.preventDefault();
                      enroll();
                    }}
                  >
                    <label>
                      Setup code
                      <input
                        type="password"
                        autoComplete="off"
                        value={token}
                        onChange={(e) => setToken(e.target.value)}
                      />
                    </label>
                    <IonButton type="submit" disabled={busy || !token}>
                      Create passkey
                    </IonButton>
                  </form>
                )}
              </section>
            ) : (
              <>
                <div className="settings">
                  {session.vapid_public && (
                    <IonButton
                      fill="outline"
                      disabled={busy}
                      onClick={notifications}
                    >
                      Enable notifications
                    </IonButton>
                  )}
                  <IonButton
                    fill="clear"
                    disabled={busy}
                    onClick={() =>
                      run(async () => {
                        await api("/logout", {}, session.csrf);
                        setSession(null);
                        setRequests([]);
                      })
                    }
                  >
                    Sign out
                  </IonButton>
                </div>
                <div className="workspace">
                  <section aria-label="Requests">
                    <h2>Requests</h2>
                    {requests.length === 0 ? (
                      <div className="empty">
                        <h3>Nothing needs your attention</h3>
                        <p>New requests will appear here.</p>
                      </div>
                    ) : (
                      <ul>
                        {requests.map((r) => (
                          <li key={r.id}>
                            <button
                              className={
                                "request " +
                                (r.id === selected ? "selected" : "")
                              }
                              onClick={() => setSelected(r.id)}
                            >
                              <span>
                                <strong>
                                  {r.operation === "ssh.connect"
                                    ? "NASA connection"
                                    : "Permission check"}
                                </strong>
                                <small>
                                  {new Date(r.created * 1000).toLocaleString()}
                                </small>
                              </span>
                              <span className={"state " + r.state}>
                                {r.state}
                              </span>
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                  </section>
                  <section className="detail" aria-live="polite">
                    {active ? (
                      <>
                        <h2>
                          {active.operation === "ssh.connect"
                            ? "NASA connection"
                            : "Permission check"}
                        </h2>
                        <p className="reason">{active.reason}</p>
                        <dl>
                          <dt>Requested by</dt>
                          <dd>{active.requester}</dd>
                          <dt>What this allows</dt>
                          <dd>
                            {active.connection
                              ? "One connection to NASA for up to 15 minutes. Host files are read-only, with temporary scratch space. Reconnecting needs a new approval."
                              : "A harmless verification that approval was received. No host connection is opened."}
                          </dd>
                          {active.connection && (
                            <>
                              <dt>Account</dt>
                              <dd>{active.connection.account} — no sudo</dd>
                            </>
                          )}
                          <dt>
                            {active.connection_deadline
                              ? "Connection ends by"
                              : "Approval expires"}
                          </dt>
                          <dd>
                            {new Date(
                              (active.connection_deadline ?? active.expires) *
                                1000,
                            ).toLocaleString()}
                          </dd>
                          <dt>Status</dt>
                          <dd>{active.state}</dd>
                        </dl>
                        {active.result && <p>{active.result}</p>}
                        {active.state === "pending" && (
                          <div className="decisions">
                            <IonButton
                              color="medium"
                              fill="outline"
                              disabled={busy}
                              onClick={() =>
                                run(async () => {
                                  await api(
                                    `/requests/${active.id}/decision`,
                                    { decision: "deny" },
                                    session.csrf,
                                  );
                                  await refresh();
                                })
                              }
                            >
                              Deny
                            </IonButton>
                            <IonButton
                              disabled={busy}
                              onClick={() =>
                                run(async () => {
                                  await api(
                                    `/requests/${active.id}/decision`,
                                    {
                                      decision: "approve",
                                      connection: active.connection,
                                    },
                                    session.csrf,
                                  );
                                  await refresh();
                                })
                              }
                            >
                              Approve
                            </IonButton>
                          </div>
                        )}
                      </>
                    ) : (
                      <p>Select a request to review its details.</p>
                    )}
                  </section>
                </div>
              </>
            )}
          </main>
        </IonContent>
      </IonPage>
    </IonApp>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
