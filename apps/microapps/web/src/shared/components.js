// Framework-neutral components used by both React and the static dashboard.
const shadowStyles = `<link rel="stylesheet" href="${new URL("./component-shadow.css", import.meta.url).href}">`;

class AppToolbar extends HTMLElement {
  static observedAttributes = ["heading"];
  constructor() {
    super();
    this.attachShadow({ mode: "open" }).innerHTML = `
      ${shadowStyles}
      <header class="toolbar"><h1></h1><div class="actions"><slot></slot></div></header>`;
  }
  connectedCallback() {
    this.attributeChangedCallback();
  }
  attributeChangedCallback() {
    this.shadowRoot.querySelector("h1").textContent =
      this.getAttribute("heading") || "";
  }
}

const states = {
  pending: ["Pending", "accent"],
  approved: ["Approved", "accent"],
  claimed: ["In use", "accent"],
  completed: ["Done", "success"],
  denied: ["Denied", "muted"],
  expired: ["Expired", "muted"],
  update: ["Update", "warning"],
  current: ["Current", "success"],
  ok: ["Healthy", "success"],
  error: ["Error", "danger"],
  failed: ["Failed", "danger"],
  partial: ["Partial", "warning"],
  missing: ["Not scanned", "muted"],
};
class AppStatus extends HTMLElement {
  static observedAttributes = ["state", "label"];
  constructor() {
    super();
    this.attachShadow({ mode: "open" }).innerHTML = `
      ${shadowStyles}<span class="status"></span>`;
  }
  connectedCallback() {
    this.attributeChangedCallback();
  }
  attributeChangedCallback() {
    const state = this.getAttribute("state") || "";
    const [label, tone] = states[state] || [state, "muted"];
    const span = this.shadowRoot.querySelector("span");
    span.textContent = this.getAttribute("label") || label;
    span.className = `status ${tone}`;
  }
}

const icons = {
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  back: '<path d="m14 6-6 6 6 6"/>',
  bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/>',
  logout: '<path d="M9 4H4v16h5M10 12h11m-4-4 4 4-4 4"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3M12 14v3"/>',
};
class AppIcon extends HTMLElement {
  static observedAttributes = ["name"];
  constructor() {
    super();
    this.attachShadow({ mode: "open" });
  }
  connectedCallback() {
    this.setAttribute("aria-hidden", "true");
    this.attributeChangedCallback();
  }
  attributeChangedCallback() {
    this.shadowRoot.innerHTML = `${shadowStyles}
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${icons[this.getAttribute("name")] || ""}</svg>`;
  }
}
class AppEmpty extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: "open" }).innerHTML = `
      ${shadowStyles}<slot></slot>`;
  }
}

for (const [name, component] of Object.entries({
  "app-toolbar": AppToolbar,
  "app-status": AppStatus,
  "app-icon": AppIcon,
  "app-empty": AppEmpty,
})) {
  if (!customElements.get(name)) customElements.define(name, component);
}

export function buttonClass(variant = "default") {
  return `ui-button${variant === "default" ? "" : ` ui-button--${variant}`}`;
}
