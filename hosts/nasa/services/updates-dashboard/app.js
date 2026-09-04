const content = document.querySelector("#content");
const nixScanDialog = document.querySelector("#nix-scan-confirm");
const confirmNixScan = document.querySelector("#confirm-nix-scan");

let dashboard = null;
let containerFilter = "all";
let loadInProgress = false;
let actionMessage = null;
const pendingActions = new Set();

const AUTO_REFRESH_INTERVAL = 5_000;

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
  if (options.href) node.href = options.href;
  if (options.title) node.title = options.title;
  if (options.disabled) node.disabled = true;
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

function actions() {
  return dashboard?.actions || {};
}

function resultKey(kind, target) {
  return `${kind}--${target.replace(/[^A-Za-z0-9_.-]+/g, "--")}`;
}

function externalLink(label, href, className = "") {
  const link = element("a", { className, href, text: label });
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  return link;
}

function actionButton(label, handler, options = {}) {
  const button = element("button", {
    className: options.className || "action-button",
    text: label,
    title: options.title,
    disabled: options.disabled,
  });
  button.type = "button";
  button.addEventListener("click", handler);
  return button;
}

function jobRunning(target) {
  return ["queued", "active", "activating", "reloading"].includes(actions().jobs?.[target]);
}

async function requestAction(payload, pendingKey, successMessage) {
  if (pendingActions.has(pendingKey)) return;
  pendingActions.add(pendingKey);
  actionMessage = null;
  render();
  try {
    const response = await fetch("/api/actions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Update-CSRF": actions().csrfToken,
      },
      body: JSON.stringify(payload),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || `Action API returned ${response.status}`);
    actionMessage = { status: "ok", text: successMessage };
  } catch (error) {
    actionMessage = { status: "error", text: error.message };
    pendingActions.delete(pendingKey);
  }
  render();
}

function scanButton(target, confirm = false) {
  const pendingKey = `scan:${target}`;
  const running = jobRunning(target) || pendingActions.has(pendingKey);
  return actionButton(
    running ? "Running…" : "Run scan",
    () => {
      if (confirm) {
        nixScanDialog.showModal();
      } else {
        requestAction(
          { action: "scan", target },
          pendingKey,
          `${target[0].toUpperCase()}${target.slice(1)} scan queued.`,
        );
      }
    },
    { disabled: running },
  );
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

function scanTime(label, report, target) {
  return element(
    "span",
    { className: "scan-time" },
    element(
      "span",
      {},
      element("strong", { text: label }),
      ` ${formatDate(report?.checkedAt)}`,
    ),
    scanButton(target),
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

function pullRequestControl(kind, target) {
  const result = actions().pullRequests?.[resultKey(kind, target)];
  const pendingKey = `pr:${kind}:${target}`;
  if (result?.status === "complete" && result.url) {
    return externalLink("View PR", result.url, "action-link");
  }
  const running = ["queued", "running"].includes(result?.status)
    || pendingActions.has(pendingKey);
  const configured = actions().prConfigured !== false;
  const label = running ? "Creating…" : result?.status === "failed" ? "Retry PR" : "Create PR";
  return actionButton(
    label,
    () => requestAction(
      { action: "create-pr", kind, target },
      pendingKey,
      "Pull request creation queued.",
    ),
    {
      disabled: running || !configured,
      title: !configured
        ? "Configure the GitHub token on NASA to enable pull requests."
        : result?.error,
    },
  );
}

function containerPrTarget(service) {
  const group = service.release?.updateGroup || service.digest?.updateGroup;
  if (!group) return service.name;
  return mergedContainers()
    .filter((candidate) => (
      candidate.release?.updateGroup || candidate.digest?.updateGroup
    ) === group)
    .map((candidate) => candidate.name)
    .sort()[0] || service.name;
}

function availableVersionCell(service, available) {
  const cell = element("td", { className: "version", dataLabel: "Available" });
  cell.append(element("span", { text: available || "—" }));
  if (service.release?.status === "update" && service.release.releaseNotesUrl) {
    cell.append(
      externalLink("Release notes", service.release.releaseNotesUrl, "release-link"),
    );
  }
  if (service.release?.status === "update" && service.release.externalReleaseNotesUrl) {
    cell.append(
      externalLink(
        "Release post",
        service.release.externalReleaseNotesUrl,
        "release-link",
      ),
    );
  }
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
        scanTime("Releases", reports().releases, "releases"),
        scanTime("Digests", reports().digests, "digests"),
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
        ...["Service", "Installed", "Available", "Release", "Digest", "Action"].map((label) => element("th", { text: label })),
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
        availableVersionCell(service, available),
        statusCell(service.release),
        statusCell(service.digest, true),
        element(
          "td",
          { dataLabel: "Action" },
          service.release?.status === "update" || service.digest?.status === "update"
            ? pullRequestControl("container", containerPrTarget(service))
            : element("span", { className: "muted", text: "—" }),
        ),
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
  body.append(
    sectionHeader(
      "Nix package forecast",
      "Package versions after a temporary flake update.",
      element(
        "div",
        { className: "section-actions" },
        scanButton("nix", true),
        report?.inputsChanged === true ? pullRequestControl("nix", "nix") : null,
      ),
    ),
  );
  if (!report) {
    body.append(
      emptyState(
        "No forecast yet",
        "The nightly scan evaluates and builds both hosts.",
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

function renderActions() {
  const report = reports().actions;
  const body = element("div", { className: "stack" });
  body.append(
    sectionHeader(
      "GitHub Actions",
      "Version channels used by repository workflows.",
      null,
      element(
        "div",
        { className: "scan-times" },
        scanTime("Last scan", report, "actions"),
      ),
    ),
  );
  if (!report) {
    body.append(emptyState("No Action scan yet", "Run the scan to check workflow dependencies."));
    return body;
  }
  if (report.error) body.append(emptyState("Action scan failed", report.error));
  if (!report.items?.length) {
    body.append(emptyState("No workflow actions found", "No external versioned actions were detected."));
    return body;
  }

  const table = element("table", { className: "action-table" });
  table.setAttribute("aria-label", "GitHub Action versions");
  table.append(
    element(
      "thead",
      {},
      element(
        "tr",
        {},
        ...["Workflow action", "Installed", "Available", "Status", "Action"].map(
          (label) => element("th", { text: label }),
        ),
      ),
    ),
  );
  const tableBody = element("tbody");
  for (const item of report.items) {
    const available = element("td", { className: "version", dataLabel: "Available" });
    available.append(element("span", { text: item.availableRef || "—" }));
    if (item.status === "update" && item.releaseNotesUrl) {
      available.append(externalLink("Release notes", item.releaseNotesUrl, "release-link"));
    }
    tableBody.append(
      element(
        "tr",
        {},
        element("td", { dataLabel: "Workflow action" }, element("div", { className: "service-name", text: item.name })),
        element("td", { className: "version", dataLabel: "Installed", text: item.currentRef || "—" }),
        available,
        element("td", { dataLabel: "Status" }, chip(item.status), item.error ? element("div", { className: "error-text", text: item.error }) : null),
        element(
          "td",
          { dataLabel: "Action" },
          item.status === "update"
            ? pullRequestControl("action", item.name)
            : element("span", { className: "muted", text: "—" }),
        ),
      ),
    );
  }
  table.append(tableBody);
  body.append(element("section", { className: "panel table-scroll" }, table));
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
  const historyOpen = content.querySelector(".history-disclosure")?.open || false;
  const page = element(
    "div",
    { className: "page-stack" },
    renderSummary(),
    actionMessage
      ? element("p", { className: `action-message ${actionMessage.status}`, text: actionMessage.text })
      : null,
    renderContainers(),
    renderNix(),
    renderActions(),
    renderHistory(),
  );
  const history = page.querySelector(".history-disclosure");
  if (history) history.open = historyOpen;
  content.replaceChildren(page);
}

async function load() {
  if (loadInProgress) return;
  loadInProgress = true;
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) throw new Error(`Dashboard API returned ${response.status}`);
    const latest = await response.json();
    const hadPendingAction = pendingActions.size > 0;
    pendingActions.clear();
    if (!dashboard || hadPendingAction || JSON.stringify(latest) !== JSON.stringify(dashboard)) {
      dashboard = latest;
      render();
    }
  } catch (error) {
    if (!dashboard) content.replaceChildren(emptyState("Could not load reports", error.message));
  } finally {
    loadInProgress = false;
  }
}

window.setInterval(() => {
  if (!document.hidden) load();
}, AUTO_REFRESH_INTERVAL);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) load();
});
confirmNixScan.addEventListener("click", () => requestAction(
  { action: "scan", target: "nix" },
  "scan:nix",
  "Nix scan queued.",
));
load();
