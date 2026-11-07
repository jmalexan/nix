import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { IonApp, IonContent, IonPage, setupIonicReact } from "@ionic/react";
import { signIn, createPasskey } from "./shared/passkeys";
import "@ionic/react/css/core.css";
import "@ionic/react/css/normalize.css";
import "@ionic/react/css/structure.css";
import "@ionic/react/css/typography.css";
import "./theme.css";
import type { components } from "./api";
import {
  Toolbar,
  Status,
  Icon,
  Empty,
  Button,
  Disclosure,
} from "./shared/react";

import { api } from "./api-client";
import { NotificationSetup } from "./notifications";

type Approval = components["schemas"]["RequestView"];
type Session = components["schemas"]["SessionView"];
setupIonicReact();
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
  const [historyOpen, setHistoryOpen] = useState(false);
  const [progressOpen, setProgressOpen] = useState(false);
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
      await signIn(api);
      setSession(await api<Session>("/session"));
      setNotice("");
    });
  }
  async function enroll() {
    await run(async () => {
      await createPasskey(api, token);
      setToken("");
      setEnrolling(false);
      setNotice("Passkey created. Sign in to continue.");
    });
  }
  const active = requests.find((r) => r.id === selected);
  const pending = requests.filter((r) => r.state === "pending");
  const inProgress = requests.filter((r) =>
    ["approved", "claimed"].includes(r.state),
  );
  const past = requests.filter(
    (r) => !["pending", "approved", "claimed"].includes(r.state),
  );
  useEffect(() => {
    if (!active || active.state === "pending") return;
    if (["approved", "claimed"].includes(active.state)) setProgressOpen(true);
    else setHistoryOpen(true);
  }, [active?.id, active?.state]);
  function selectRequest(id: string | null) {
    setSelected(id);
    const url = new URL(location.href);
    if (id) url.searchParams.set("request", id);
    else url.searchParams.delete("request");
    history.replaceState(null, "", url);
  }
  const requestTitle = (r: Approval) =>
    r.operation === "ssh.connect" ? "NASA connection" : "Permission check";
  const shortDate = (seconds: number) =>
    new Intl.DateTimeFormat(undefined, {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    }).format(new Date(seconds * 1000));
  function requestRows(items: Approval[]) {
    return (
      <ul>
        {items.map((r) => (
          <li key={r.id}>
            <button
              className={`request${r.id === selected ? " selected" : ""}`}
              aria-current={r.id === selected ? "true" : undefined}
              onClick={() => selectRequest(r.id)}
            >
              <span>
                <strong>{requestTitle(r)}</strong>
                <time dateTime={new Date(r.created * 1000).toISOString()}>
                  {shortDate(r.created)}
                </time>
              </span>
              <Status state={r.state} />
            </button>
          </li>
        ))}
      </ul>
    );
  }
  return (
    <IonApp>
      <IonPage>
        <Toolbar heading="Approvals">
          {session && (
            <details className="ui-menu">
              <summary
                className="ui-button ui-button--icon"
                role="button"
                aria-label="Settings"
                title="Settings"
              >
                <Icon name="more" />
              </summary>
              <div className="ui-menu-items ui-panel">
                <Button
                  variant="quiet"
                  disabled={busy}
                  onClick={() =>
                    run(async () => {
                      await api("/logout", {}, session.csrf);
                      setSession(null);
                      setRequests([]);
                    })
                  }
                >
                  <Icon name="logout" />
                  Sign out
                </Button>
              </div>
            </details>
          )}
        </Toolbar>
        <IonContent>
          <main>
            {error && (
              <p role="alert" className="ui-message">
                {error}
              </p>
            )}
            {notice && (
              <p role="status" className="ui-message">
                {notice}
              </p>
            )}
            {!ready ? (
              <Empty>Loading…</Empty>
            ) : !session ? (
              <section className="signin ui-panel" aria-label="Sign in">
                <div className="signin-icon">
                  <Icon name="lock" />
                </div>
                <Button variant="primary" disabled={busy} onClick={login}>
                  Sign in with passkey
                </Button>
                <Button
                  variant="quiet"
                  onClick={() => setEnrolling(!enrolling)}
                  aria-expanded={enrolling}
                >
                  Set up this app
                </Button>
                {enrolling && (
                  <form
                    onSubmit={(event) => {
                      event.preventDefault();
                      enroll();
                    }}
                  >
                    <label>
                      Setup code
                      <input
                        className="ui-input"
                        type="password"
                        autoComplete="off"
                        value={token}
                        onChange={(event) => setToken(event.target.value)}
                      />
                    </label>
                    <Button
                      variant="primary"
                      type="submit"
                      disabled={busy || !token}
                    >
                      Create passkey
                    </Button>
                  </form>
                )}
              </section>
            ) : (
              <>
                <NotificationSetup
                  csrf={session.csrf}
                  publicKey={session.vapid_public}
                />
                <div className={`workspace${active ? " detail-open" : ""}`}>
                  <section className="request-list" aria-label="Requests">
                    {pending.length ? (
                      requestRows(pending)
                    ) : (
                      <Empty>No pending requests</Empty>
                    )}
                    {inProgress.length > 0 && (
                      <Disclosure
                        title="In progress"
                        count={inProgress.length}
                        open={progressOpen}
                        onToggle={setProgressOpen}
                      >
                        {requestRows(inProgress)}
                      </Disclosure>
                    )}
                    {past.length > 0 && (
                      <Disclosure
                        title="History"
                        count={past.length}
                        open={historyOpen}
                        onToggle={setHistoryOpen}
                      >
                        {requestRows(past)}
                      </Disclosure>
                    )}
                  </section>
                  <section className="detail ui-panel" aria-live="polite">
                    {active ? (
                      <>
                        <Button
                          className="back-button"
                          variant="quiet"
                          onClick={() => selectRequest(null)}
                        >
                          <Icon name="back" />
                          Requests
                        </Button>
                        <div className="detail-heading">
                          <h2>{requestTitle(active)}</h2>
                          <Status state={active.state} />
                        </div>
                        <p className="reason">{active.reason}</p>
                        {active.connection ? (
                          <dl className="scope">
                            <div>
                              <dt>Access</dt>
                              <dd>Read-only · No sudo</dd>
                            </div>
                            <div>
                              <dt>Limit</dt>
                              <dd>
                                1 connection ·{" "}
                                {active.connection.max_seconds / 60} min
                              </dd>
                            </div>
                            <div>
                              <dt>Account</dt>
                              <dd>{active.connection.account}</dd>
                            </div>
                          </dl>
                        ) : (
                          <p className="muted">Test only · No host access</p>
                        )}
                        <div className="request-meta">
                          <span>From {active.requester}</span>
                          {["pending", "approved", "claimed"].includes(
                            active.state,
                          ) && (
                            <span>
                              {active.connection_deadline
                                ? "Ends by"
                                : active.state === "approved"
                                  ? "Connect by"
                                  : "Expires"}{" "}
                              <time
                                dateTime={new Date(
                                  (active.connection_deadline ??
                                    active.expires) * 1000,
                                ).toISOString()}
                              >
                                {new Intl.DateTimeFormat(undefined, {
                                  hour: "numeric",
                                  minute: "2-digit",
                                }).format(
                                  new Date(
                                    (active.connection_deadline ??
                                      active.expires) * 1000,
                                  ),
                                )}
                              </time>
                            </span>
                          )}
                        </div>
                        {active.result && active.state === "failed" && (
                          <p role="alert" className="ui-message">
                            {active.result}
                          </p>
                        )}
                        {active.state === "pending" && (
                          <div className="decisions">
                            <Button
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
                            </Button>
                            <Button
                              variant="primary"
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
                            </Button>
                          </div>
                        )}
                      </>
                    ) : (
                      <Empty>Select a request</Empty>
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
