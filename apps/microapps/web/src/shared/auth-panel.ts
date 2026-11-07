import { api } from "../api-client";
import { signIn } from "./passkeys";

export { api };
export type Session = { csrf: string };

type AuthMethods = { password: boolean; passkey: boolean; setup: boolean };

const username = `<label>Username<input class="ui-input" name="username" autocomplete="username" value="owner" readonly></label>`;
const password = (label: string, name: string, autocomplete: string) =>
  `<label>${label}<input class="ui-input" type="password" name="${name}" autocomplete="${autocomplete}" ${autocomplete === "new-password" ? 'minlength="15"' : ""} maxlength="1024" required></label>`;

function actionRunner(root: HTMLElement) {
  const error = root.querySelector<HTMLElement>('[role="alert"]')!;
  return async (operation: () => Promise<void>) => {
    error.hidden = true;
    root.querySelectorAll("button").forEach((b) => (b.disabled = true));
    try {
      await operation();
    } catch (e) {
      error.textContent = e instanceof Error ? e.message : "Unable to connect";
      error.hidden = false;
    } finally {
      root.querySelectorAll("button").forEach((b) => (b.disabled = false));
    }
  };
}

export function showSignIn(
  root: HTMLElement,
  onSignedIn: (session: Session) => void,
) {
  root.innerHTML = `<section class="signin ui-panel" aria-label="Sign in">
    <div class="signin-icon"><app-icon name="lock"></app-icon></div>
    <p role="alert" class="ui-message" hidden></p>
    <form id="password-login">${username}${password("Password", "password", "current-password")}
      <button class="ui-button ui-button--primary" type="submit">Sign in</button></form>
    <button class="ui-button ui-button--quiet" id="passkey-login" hidden>Sign in with passkey</button>
    <button class="ui-button ui-button--quiet" id="password-setup" aria-expanded="false" hidden>Set up this app</button>
    <form id="password-enroll" hidden>${username}
      <label>Setup code<input class="ui-input" name="token" type="password" autocomplete="off" maxlength="256" required></label>
      ${password("New password", "password", "new-password")}
      ${password("Confirm password", "confirm", "new-password")}
      <button class="ui-button ui-button--primary" type="submit">Create password</button></form>
  </section>`;
  const run = actionRunner(root);
  const setup = root.querySelector<HTMLButtonElement>("#password-setup")!;
  const enroll = root.querySelector<HTMLFormElement>("#password-enroll")!;
  const login = root.querySelector<HTMLFormElement>("#password-login")!;
  const passkey = root.querySelector<HTMLButtonElement>("#passkey-login")!;
  void run(async () => {
    const methods = await api<AuthMethods>("/auth/methods");
    passkey.hidden = !methods.passkey;
    setup.hidden = !methods.setup;
  });
  setup.onclick = () => {
    enroll.hidden = !enroll.hidden;
    login.hidden = !enroll.hidden;
    setup.setAttribute("aria-expanded", String(!enroll.hidden));
  };
  passkey.onclick = () =>
    run(async () => {
      await signIn(api);
      onSignedIn(await api<Session>("/session"));
    });
  login.onsubmit = (event) => {
    event.preventDefault();
    void run(async () => {
      const data = new FormData(login);
      await api("/auth/password/login", { password: data.get("password") });
      login.reset();
      onSignedIn(await api<Session>("/session"));
    });
  };
  enroll.onsubmit = (event) => {
    event.preventDefault();
    void run(async () => {
      const data = new FormData(enroll);
      if (data.get("password") !== data.get("confirm"))
        throw new Error("Passwords do not match");
      await api("/auth/password/enroll", {
        token: data.get("token"),
        password: data.get("password"),
      });
      enroll.reset();
      onSignedIn(await api<Session>("/session"));
    });
  };
}

export function showPasswordSettings(
  root: HTMLElement,
  session: Session,
  onSaved: (session: Session) => void,
  onCancel: () => void,
) {
  root.innerHTML = `<section class="signin ui-panel" aria-label="Set password">
    <h2>Set password</h2><p role="alert" class="ui-message" hidden></p>
    <form>${username}${password("New password", "password", "new-password")}
      ${password("Confirm password", "confirm", "new-password")}
      <button class="ui-button ui-button--primary" type="submit">Save password</button>
      <button class="ui-button ui-button--quiet" type="button">Cancel</button></form>
  </section>`;
  const form = root.querySelector("form")!;
  const run = actionRunner(root);
  root.querySelector<HTMLButtonElement>('[type="button"]')!.onclick = onCancel;
  form.onsubmit = (event) => {
    event.preventDefault();
    void run(async () => {
      const data = new FormData(form);
      if (data.get("password") !== data.get("confirm"))
        throw new Error("Passwords do not match");
      await api(
        "/auth/password",
        { password: data.get("password") },
        session.csrf,
      );
      form.reset();
      onSaved(await api<Session>("/session"));
    });
  };
}
