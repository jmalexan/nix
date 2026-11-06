const status = document.querySelector("#status");
const form = document.querySelector("#services");
const revoke = document.querySelector("#revoke");

async function api(path, body) {
  const response = await fetch(path, {
    method: body === undefined ? "GET" : "POST",
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: "same-origin",
    redirect: "error",
  });
  if (!response.ok) throw new Error("Open settings from the companion and try again.");
  return response.json();
}

async function start() {
  const ticket = location.hash.slice(1);
  history.replaceState(null, "", "/");
  if (ticket) await api("/v1/web/session", { ticket });
  const settings = await api("/v1/web/settings");
  status.textContent = settings.name;
  for (const [name, enabled] of Object.entries(settings.services)) {
    const label = document.createElement("label");
    label.append(document.createTextNode(name));
    const toggle = document.createElement("input");
    toggle.type = "checkbox";
    toggle.checked = enabled;
    toggle.addEventListener("change", async () => {
      toggle.disabled = true;
      try {
        await api(`/v1/web/services/${encodeURIComponent(name)}`, { enabled: toggle.checked });
        status.textContent = "Saved";
      } catch (error) {
        toggle.checked = !toggle.checked;
        status.textContent = error.message;
      } finally {
        toggle.disabled = false;
      }
    });
    label.append(toggle);
    form.append(label);
  }
  form.hidden = false;
  revoke.hidden = false;
  revoke.addEventListener("click", async () => {
    if (!confirm("Disconnect this device from notifications?")) return;
    revoke.disabled = true;
    try {
      await api("/v1/web/revoke", {});
      form.hidden = true;
      revoke.hidden = true;
      status.textContent = "Device disconnected";
    } catch (error) {
      status.textContent = error.message;
      revoke.disabled = false;
    }
  });
}
start().catch((error) => { status.textContent = error.message; });
