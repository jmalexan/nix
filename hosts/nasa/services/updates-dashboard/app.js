const content = document.querySelector("#content");
const refreshButton = document.querySelector("#refresh");
const tabs = [...document.querySelectorAll("[data-tab]")];

let dashboard = null;
let activeTab = "overview";
let containerFilter = "all";

function element(tag, options = {}, ...children) {
  const node = document.createElement(tag);
  if (options.className) node.className = options.className;
  if (options.text !== undefined) node.textContent = options.text;
  if (options.colSpan) node.colSpan = options.colSpan;
  for (const child of children.flat()) {
    if (child !== null && child !== undefined) node.append(child);
  }
  return node;
}

function chip(status, label) {
  const names = {
    update: "Update available",
    current: "Current",
    error: "Check failed",
    ok: "Healthy",
    partial: "Partial",
    failed: "Failed",
    missing: "Not scanned",
  };
  return element("span", { className: `chip ${status}`, text: label || names[status] || status });
}

function formatDate(value) {
  if (!value) return "Not scanned yet";
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function shortDigest(value) {
  if (!value) return "—";
  const [algorithm, hash] = value.split(":");
  return hash ? `${algorithm}:${hash.slice(0, 12)}…` : value.slice(0, 16);
}

function reports() {
  return dashboard?.reports || {};
}

function mergedContainers() {
  const services = new Map();
  for (const [reportType, report] of Object.entries({
    release: reports().releases,
    digest: reports().digests,
  })) {
    for (const item of report?.items || []) {
      const service = services.get(item.name) || {
        name: item.name,
        repository: item.repository,
        currentTag: item.currentTag,
        currentDigest: item.currentDigest,
      };
      service[reportType] = item;
      services.set(item.name, service);
    }
  }
  const weight = (service) => {
    if (service.release?.status === "update" || service.digest?.status === "update") return 0;
    if (service.release?.status === "error" || service.digest?.status === "error") return 1;
    return 2;
  };
  return [...services.values()].sort(
    (left, right) => weight(left) - weight(right) || left.name.localeCompare(right.name),
  );
}

function sectionHeader(title, caption, extra = null) {
  return element(
    "div",
    { className: "section-header" },
    element("div", {}, element("h2", { text: title }), element("p", { className: "section-caption", text: caption })),
    extra,
  );
}

function emptyState(title, description, command = null) {
  const children = [element("strong", { text: title }), element("span", { text: description })];
  if (command) children.push(element("code", { text: command }));
  return element("section", { className: "empty-state" }, children);
}

function metric(label, value, kind) {
  return element(
    "div",
    { className: `metric ${kind}` },
    element("span", { className: "metric-label", text: label }),
    element("span", { className: "metric-value", text: String(value) }),
  );
}

function scanCard(report, title) {
  if (!report) {
    return element(
      "article",
      { className: "scan-card" },
      element("div", { className: "scan-card-top" }, element("h3", { text: title }), chip("missing")),
      element("p", { text: "Waiting for its first scheduled or manual run." }),
    );
  }
  const counts = report.counts || {};
  return element(
    "article",
    { className: "scan-card" },
    element("div", { className: "scan-card-top" }, element("h3", { text: title }), chip(report.status)),
    element("p", { text: `Last checked ${formatDate(report.checkedAt)}` }),
    element("p", { text: `${counts.update || 0} updates · ${counts.error || 0} errors` }),
  );
}

function updateCard(service, kind) {
  const item = service[kind];
  const digest = kind === "digest";
  const current = digest ? shortDigest(item.currentDigest) : item.currentTag;
  const available = digest ? shortDigest(item.availableDigest) : item.availableTag;
  return element(
    "article",
    { className: "update-card" },
    element("div", { className: "update-card-top" }, element("h3", { text: service.name }), chip("update", digest ? "Digest changed" : "New release")),
    element("p", { className: "repository", text: service.repository }),
    element(
      "div",
      { className: "version-change" },
      element("span", { text: current }),
      element("span", { className: "arrow", text: "→" }),
      element("span", { text: available }),
    ),
  );
}

function renderOverview() {
  const containers = mergedContainers();
  const releaseUpdates = containers.filter((service) => service.release?.status === "update");
  const digestUpdates = containers.filter((service) => service.digest?.status === "update");
  const errors = containers.filter(
    (service) => service.release?.status === "error" || service.digest?.status === "error",
  );
  const current = containers.filter(
    (service) => service.release?.status === "current" && service.digest?.status === "current",
  );
  const cards = [
    ...releaseUpdates.map((service) => updateCard(service, "release")),
    ...digestUpdates.map((service) => updateCard(service, "digest")),
  ];

  const body = element("div", { className: "stack" });
  body.append(
    element(
      "section",
      { className: "metrics" },
      metric("Updates detected", cards.length, "update"),
      metric("Fully current", current.length, "current"),
      metric("Checks needing attention", errors.length, "error"),
    ),
    sectionHeader("Available changes", "Release and digest changes are shown separately."),
  );
  body.append(
    cards.length
      ? element("section", { className: "cards" }, cards)
      : emptyState("Nothing pending", "The latest completed container scans found no changes."),
    sectionHeader("Scan health", "When each source last produced a usable report."),
    element(
      "section",
      { className: "cards" },
      scanCard(reports().releases, "Container releases"),
      scanCard(reports().digests, "Container digests"),
      scanCard(reports().nix, "Nix flake forecast"),
    ),
  );
  return body;
}

function filterButtons() {
  const group = element("div", { className: "filters" });
  for (const [value, label] of [["all", "All"], ["updates", "Updates"], ["attention", "Attention"]]) {
    const button = element("button", {
      className: `filter-button${containerFilter === value ? " active" : ""}`,
      text: label,
    });
    button.type = "button";
    button.addEventListener("click", () => {
      containerFilter = value;
      render();
    });
    group.append(button);
  }
  return group;
}

function statusCell(item, digest = false) {
  const cell = element("td");
  if (!item) return cell.append(chip("missing")), cell;
  cell.append(chip(item.status, digest && item.status === "update" ? "Digest changed" : null));
  if (item.error) cell.append(element("div", { className: "error-text", text: item.error }));
  return cell;
}

function renderContainers() {
  let containers = mergedContainers();
  if (containerFilter === "updates") {
    containers = containers.filter(
      (service) => service.release?.status === "update" || service.digest?.status === "update",
    );
  } else if (containerFilter === "attention") {
    containers = containers.filter(
      (service) => service.release?.status === "error" || service.digest?.status === "error",
    );
  }

  const body = element("div", { className: "stack" });
  body.append(sectionHeader("Containers", "Installed values compared with upstream registries.", filterButtons()));
  if (!containers.length) {
    body.append(emptyState("No matching services", "Try a different filter or run the container scans."));
    return body;
  }

  const table = element("table");
  table.append(
    element(
      "thead",
      {},
      element(
        "tr",
        {},
        ...["Service", "Installed", "Available", "Release", "Digest"].map((label) => element("th", { text: label })),
      ),
    ),
  );
  const tableBody = element("tbody");
  for (const service of containers) {
    const available = service.release?.availableTag || service.currentTag;
    tableBody.append(
      element(
        "tr",
        {},
        element("td", {}, element("div", { className: "service-name", text: service.name }), element("div", { className: "repository", text: service.repository })),
        element("td", { className: "version", text: service.currentTag || "—" }),
        element("td", { className: "version", text: available || "—" }),
        statusCell(service.release),
        statusCell(service.digest, true),
      ),
    );
  }
  table.append(tableBody);
  body.append(element("section", { className: "panel table-scroll" }, table));
  return body;
}

function renderNix() {
  const report = reports().nix;
  const body = element("div", { className: "stack" });
  body.append(sectionHeader("Nix package forecast", "Exact system closure changes after a temporary flake update."));
  if (!report) {
    body.append(
      emptyState(
        "No forecast yet",
        "This runs weekly because it evaluates and builds both hosts.",
        "sudo systemctl start updates-dashboard-nix-report.service",
      ),
    );
    return body;
  }
  body.append(scanCard(report, "Latest Nix scan"));
  if (report.error) body.append(emptyState("Forecast failed", report.error));
  for (const host of report.hosts || []) {
    body.append(
      element(
        "section",
        { className: "panel nix-host" },
        element("header", {}, element("h3", { text: host.name }), chip(host.status)),
        element("pre", { text: host.changes || "No closure changes." }),
      ),
    );
  }
  return body;
}

function renderHistory() {
  const body = element("div", { className: "stack" });
  body.append(sectionHeader("Scan history", "The most recent 100 completed scan attempts."));
  if (!dashboard.history?.length) {
    body.append(emptyState("No history yet", "Completed scans will appear here."));
    return body;
  }
  const table = element("table");
  table.append(
    element("thead", {}, element("tr", {}, ...["When", "Scan", "Result", "Updates", "Errors"].map((label) => element("th", { text: label })))),
  );
  const tableBody = element("tbody");
  for (const item of dashboard.history) {
    tableBody.append(
      element(
        "tr",
        {},
        element("td", { className: "timestamp", text: formatDate(item.checkedAt) }),
        element("td", { className: "service-name", text: item.title }),
        element("td", {}, chip(item.status)),
        element("td", { text: String(item.counts?.update || 0) }),
        element("td", { text: String(item.counts?.error || 0) }),
      ),
    );
  }
  table.append(tableBody);
  body.append(element("section", { className: "panel table-scroll" }, table));
  return body;
}

function render() {
  if (!dashboard) return;
  const views = { overview: renderOverview, containers: renderContainers, nix: renderNix, history: renderHistory };
  content.replaceChildren(views[activeTab]());
  tabs.forEach((tab) => tab.setAttribute("aria-selected", String(tab.dataset.tab === activeTab)));
}

async function load() {
  refreshButton.disabled = true;
  refreshButton.textContent = "Refreshing…";
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) throw new Error(`Dashboard API returned ${response.status}`);
    dashboard = await response.json();
    render();
  } catch (error) {
    content.replaceChildren(emptyState("Could not load reports", error.message));
  } finally {
    refreshButton.disabled = false;
    refreshButton.textContent = "Refresh";
  }
}

tabs.forEach((tab) => tab.addEventListener("click", () => {
  activeTab = tab.dataset.tab;
  render();
}));
refreshButton.addEventListener("click", load);
load();
