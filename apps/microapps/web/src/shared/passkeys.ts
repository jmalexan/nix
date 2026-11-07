import {
  startAuthentication,
  startRegistration,
} from "@simplewebauthn/browser";

type API = <T>(path: string, body?: unknown) => Promise<T>;

export async function signIn(api: API) {
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
}

export async function createPasskey(api: API, token: string) {
  const ceremony = await api<{
    challenge_id: string;
    options: Parameters<typeof startRegistration>[0]["optionsJSON"];
  }>("/auth/enroll/options", { token });
  const credential = await startRegistration({ optionsJSON: ceremony.options });
  await api("/auth/enroll/verify", {
    challenge_id: ceremony.challenge_id,
    credential,
  });
}
