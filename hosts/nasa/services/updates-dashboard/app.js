const content = document.querySelector("#content");
const refreshButton = document.querySelector("#refresh");

let dashboard = null;
let containerFilter = "all";

const serviceNames = {
  bookorbit: "BookOrbit",
  "bookorbit-postgres": "BookOrbit database",
  "eufy-security-ws": "Eufy Security",
  flaresolverr: "FlareSolverr",
  frigate: "Frigate",
  go2rtc: "go2rtc",
  "home-assistant": "Home Assistant",
  "immich-machine-learning": "Immich machine learning",
  "immich-postgres": "Immich database",
  "immich-public-proxy": "Immich public proxy",
  "immich-redis": "Immich cache",
  "immich-server": "Immich server",
  "music-assistant": "Music Assistant",
  "ring-mqtt": "Ring MQTT",
  romm: "RomM",
  "romm-db": "RomM database",
};

function element(tag, options = {}, ...children) {
  const node = document.createElement(tag);
  if (options.className) node.className = options.className;
  if (options.text !== undefined) node.textContent = options.text;
  if (options.colSpan) node.colSpan = options.colSpan;
  if (options.dataLabel) node.dataset.label = options.dataLabel;
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

function serviceName(value) {
  return serviceNames[value] || value;
}

function countLabel(count, singular) {
  return `${count} ${singular}${count === 1 ? "" : "s"}`;
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

function sectionHeader(title, caption, extra = null, metadata = null) {
  const heading = element("div", {}, element("h2", { text: title }));
  if (caption) heading.append(element("p", { className: "section-caption", text: caption }));
  if (metadata) heading.append(metadata);
  return element(
    "div",
    { className: "section-header" },
    heading,
    extra,
  );
}

function scanTime(label, report) {
  return element(
    "span",
    {},
    element("strong", { text: label }),
    ` ${formatDate(report?.checkedAt)}`,
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
      element("p", { text: "No completed scan" }),
    );
  }
  const counts = report.counts || {};
  const updates = counts.update || 0;
  const errors = counts.error || 0;
  return element(
    "article",
    { className: "scan-card" },
    element("div", { className: "scan-card-top" }, element("h3", { text: title }), chip(report.status)),
    element("p", { text: formatDate(report.checkedAt) }),
    element("p", { text: `${countLabel(updates, "update")}, ${countLabel(errors, "error")}` }),
  );
}

function renderSummary() {
  const containers = mergedContainers();
  const changes = containers.reduce(
    (count, service) => count
      + Number(service.release?.status === "update")
      + Number(service.digest?.status === "update"),
    0,
  );
  const errors = containers.filter(
    (service) => service.release?.status === "error" || service.digest?.status === "error",
  );
  const current = containers.filter(
    (service) => service.release?.status === "current" && service.digest?.status === "current",
  );
  return element(
    "section",
    { className: "metrics" },
    metric("Changes", changes, "update"),
    metric("Current", current.length, "current"),
    metric("Errors", errors.length, "error"),
  );
}

function filterButtons() {
  const group = element("div", { className: "filters" });
  for (const [value, label] of [["all", "All"], ["updates", "Updates"], ["attention", "Attention"]]) {
    const button = element("button", {
      className: `filter-button${containerFilter === value ? " active" : ""}`,
      text: label,
    });
    button.type = "button";
    button.setAttribute("aria-pressed", String(containerFilter === value));
    button.addEventListener("click", () => {
      containerFilter = value;
      render();
    });
    group.append(button);
  }
  return group;
}

function statusCell(item, digest = false) {
  const cell = element("td", { dataLabel: digest ? "Digest" : "Release" });
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
  body.append(
    sectionHeader(
      "Containers",
      "Current tags and pinned digests compared with registries.",
      filterButtons(),
      element(
        "div",
        { className: "scan-times" },
        scanTime("Releases", reports().releases),
        scanTime("Digests", reports().digests),
      ),
    ),
  );
  if (!containers.length) {
    body.append(emptyState("No matching services", "Try a different filter or run the container scans."));
    return body;
  }

  const table = element("table", { className: "container-table" });
  table.setAttribute("aria-label", "Container versions");
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
        element("td", { dataLabel: "Service" }, element("div", { className: "service-name", text: serviceName(service.name) }), element("div", { className: "repository", text: service.repository })),
        element("td", { className: "version", dataLabel: "Installed", text: service.currentTag || "—" }),
        element("td", { className: "version", dataLabel: "Available", text: available || "—" }),
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
  body.append(sectionHeader("Nix package forecast", "Package versions after a temporary flake update."));
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
  const body = element(
    "details",
    { className: "history-disclosure" },
    element(
      "summary",
      { className: "history-summary" },
      element(
        "span",
        { className: "history-summary-copy" },
        element("span", { className: "history-title", text: "Scan history" }),
        element("span", { className: "section-caption", text: "The last 100 scans." }),
      ),
    ),
  );
  if (!dashboard.history?.length) {
    body.append(emptyState("No history yet", "Completed scans will appear here."));
    return body;
  }
  const table = element("table");
  table.setAttribute("aria-label", "Scan history");
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
  content.replaceChildren(
    element(
      "div",
      { className: "page-stack" },
      renderSummary(),
      renderContainers(),
      renderNix(),
      renderHistory(),
    ),
  );
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

refreshButton.addEventListener("click", load);
load();
