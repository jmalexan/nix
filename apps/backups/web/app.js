import "./components.js";
import { api, showSignIn } from "./auth.js";

const root = document.querySelector("#content");
const connection = document.querySelector("#connection");
const signOut = document.querySelector("#sign-out");
let session = null;
let busy = false;

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function date(value) {
  return value
    ? new Date(value * 1000).toLocaleString(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      })
    : "Not recorded";
}
function bytes(value) {
  if (value == null) return "Unknown";
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return `${value.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[i]}`;
}
function panel(title) {
  const section = el("section", undefined, "ui-panel");
  section.append(el("h2", title));
  return section;
}
function pairs(parent, values) {
  const dl = el("dl");
  for (const [key, value] of values) dl.append(el("dt", key), el("dd", value));
  parent.append(dl);
}
function list(parent, values) {
  const ul = el("ul");
  for (const value of values) ul.append(el("li", value));
  parent.append(ul);
}
function table(parent, headings, rows) {
  const wrap = el("div", undefined, "table-scroll");
  const table = el("table");
  const head = el("tr");
  headings.forEach((h) => head.append(el("th", h)));
  const thead = el("thead");
  thead.append(head);
  table.append(thead);
  const body = el("tbody");
  rows.forEach((row) => {
    const tr = el("tr");
    row.forEach((v, index) => {
      const cell = el("td", v);
      cell.dataset.label = headings[index];
      tr.append(cell);
    });
    body.append(tr);
  });
  table.append(body);
  wrap.append(table);
  parent.append(wrap);
}
/** @param {import("./api").components["schemas"]["Status"]} status */
function render(status) {
  const content = document.createDocumentFragment();
  const health = panel(
    status.alerts.length ? "Needs attention" : "Protection is current",
  );
  if (status.alerts.length) {
    health.classList.add("alerts");
    if (status.alerts.some((a) => a.severity === "error"))
      health.classList.add("error");
    list(
      health,
      status.alerts.map((a) => a.message),
    );
  }
  const report = status.report;
  health.append(
    el(
      "p",
      report
        ? `Collected ${date(report.collected_at)}`
        : "Waiting for collector",
      "muted",
    ),
  );
  content.append(health);
  if (!report) {
    root.replaceChildren(content);
    return;
  }
  const grid = el("div", undefined, "grid");
  for (const pool of report.pools) {
    const p = panel(pool.name);
    const row = el("div", undefined, "row");
    row.append(el("p", `${pool.capacity}% used`, "big"));
    const chip = el("app-status");
    chip.setAttribute("state", pool.health === "ONLINE" ? "ok" : "error");
    chip.setAttribute("label", pool.health);
    row.append(chip);
    p.append(row);
    const progress = el("progress");
    progress.max = 100;
    progress.value = pool.capacity;
    progress.setAttribute("aria-label", `${pool.name} capacity`);
    p.append(progress);
    pairs(p, [
      ["Used / total", `${bytes(pool.allocated)} / ${bytes(pool.size)}`],
      ["Free", bytes(pool.free)],
      ["Last completed scrub", date(pool.scrub_at)],
      ["Data errors", pool.data_errors],
    ]);
    p.append(el("p", pool.scan, "muted"));
    const detail = el("details");
    detail.append(el("summary", "Devices and errors"));
    table(
      detail,
      ["Device", "State", "Read", "Write", "Checksum"],
      pool.disks.map((d) => [d.name, d.state, d.read, d.write, d.checksum]),
    );
    p.append(detail);
    grid.append(p);
  }
  const offsite = panel("Offsite · Backblaze B2");
  const active = ["active", "activating"].includes(report.backup_state);
  pairs(offsite, [
    [
      "Current activity",
      active
        ? "Backup running"
        : report.backup_state === "inactive"
          ? "Idle"
          : report.backup_state,
    ],
    [
      "Last attempt",
      report.backup.result === "success" ? "Completed" : report.backup.result,
    ],
    ["Last successful completion", date(report.backup.last_success)],
    ["Next backup", report.next_backup],
    ["Retained snapshots", report.retained_snapshots],
    ["Latest available snapshot", date(report.snapshots[0]?.time)],
  ]);
  grid.append(offsite);
  content.append(grid);
  const datasets = panel("Datasets and local snapshots");
  table(
    datasets,
    ["Dataset", "Used", "Snapshots", "Latest automatic", "Offsite coverage"],
    report.datasets.map((d) => [
      d.name,
      bytes(d.used),
      d.snapshot_count,
      d.snapshots_enabled ? date(d.latest_automatic) : "Disabled",
      d.offsite,
    ]),
  );
  content.append(datasets);
  const recovery = panel("Recovery confidence");
  list(recovery, [status.verification, status.restore_test]);
  recovery.append(
    el(
      "p",
      "Successful backups and retained snapshots do not prove that a restore has been tested.",
      "muted",
    ),
  );
  content.append(recovery);
  const coverage = panel("Backup coverage");
  coverage.append(
    el("p", report.repository, "path"),
    el("h3", "Included paths"),
  );
  list(coverage, report.paths);
  const exclusions = el("details");
  exclusions.append(
    el("summary", "Exclusions and retention"),
    el("h3", "Excluded"),
  );
  list(exclusions, report.exclusions);
  exclusions.append(el("h3", "Retention"));
  list(exclusions, report.retention);
  coverage.append(exclusions);
  content.append(coverage);
  const snapshots = panel("Recent offsite snapshots");
  table(
    snapshots,
    ["Created", "Snapshot", "Processed", "Duration"],
    report.snapshots.map((s) => [
      date(s.time),
      s.id.slice(0, 12),
      bytes(s.bytes_processed),
      s.duration == null ? "Unknown" : `${Math.round(s.duration)} sec`,
    ]),
  );
  content.append(snapshots);
  const runs = panel("Recent backup attempts");
  if (report.history.length)
    table(
      runs,
      ["Finished", "Result", "Exit status"],
      report.history.map((r) => [
        date(r.finished),
        r.result,
        r.exit_status || "Unknown",
      ]),
    );
  else
    runs.append(
      el("p", "Run history starts with the next scheduled backup.", "muted"),
    );
  content.append(runs);
  root.replaceChildren(content);
}
function signedOut() {
  session = null;
  signOut.hidden = true;
  connection.hidden = true;
  showSignIn(root, (value) => {
    session = value;
    signOut.hidden = false;
    load();
  });
}
async function load() {
  if (busy || !session) return;
  busy = true;
  const current = session;
  try {
    const response = await fetch("/api/status");
    if (current !== session) return;
    if (response.status === 401) {
      signedOut();
      return;
    }
    if (!response.ok)
      throw new Error(
        "Unable to refresh storage status. Displayed data may be out of date.",
      );
    const status = await response.json();
    if (current !== session) return;
    render(status);
    connection.hidden = true;
  } catch (error) {
    if (current === session) {
      connection.textContent = error.message;
      connection.hidden = false;
    }
  } finally {
    busy = false;
  }
}
signOut.onclick = async () => {
  try {
    await api("/logout", {}, session.csrf);
    signedOut();
  } catch (error) {
    connection.textContent = error.message;
    connection.hidden = false;
  }
};
try {
  session = await api("/session");
  signOut.hidden = false;
  await load();
} catch {
  signedOut();
}
setInterval(() => {
  if (!document.hidden) load();
}, 30000);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) load();
});
