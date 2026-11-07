import { api } from "../api-client";
import { signIn, createPasskey } from "./passkeys";

export { api };
export type Session = { csrf: string };

export function showSignIn(
  root: HTMLElement,
  onSignedIn: (session: Session) => void,
) {
  root.innerHTML = `<section class="signin ui-panel" aria-label="Sign in">
    <div class="signin-icon"><app-icon name="lock"></app-icon></div>
    <p role="alert" class="ui-message" hidden></p>
    <p role="status" class="ui-message" hidden></p>
    <button class="ui-button ui-button--primary" id="passkey-login">Sign in with passkey</button>
    <button class="ui-button ui-button--quiet" id="passkey-setup" aria-expanded="false">Set up this app</button>
    <form hidden><label>Setup code<input class="ui-input" type="password" autocomplete="off" required></label>
    <button class="ui-button ui-button--primary" type="submit">Create passkey</button></form>
  </section>`;
  const form = root.querySelector("form")!;
  const input = root.querySelector("input")!;
  const error = root.querySelector<HTMLElement>('[role="alert"]')!;
  const notice = root.querySelector<HTMLElement>('[role="status"]')!;
  const setup = root.querySelector<HTMLButtonElement>("#passkey-setup")!;
  async function run(operation: () => Promise<void>) {
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
  }
  setup.onclick = () => {
    form.hidden = !form.hidden;
    setup.setAttribute("aria-expanded", String(!form.hidden));
  };
  root.querySelector<HTMLButtonElement>("#passkey-login")!.onclick = () =>
    run(async () => {
      await signIn(api);
      onSignedIn(await api<Session>("/session"));
    });
  form.onsubmit = (event) => {
    event.preventDefault();
    void run(async () => {
      await createPasskey(api, input.value);
      input.value = "";
      form.hidden = true;
      setup.setAttribute("aria-expanded", "false");
      notice.textContent = "Passkey created. Sign in to continue.";
      notice.hidden = false;
    });
  };
}
