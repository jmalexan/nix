# Operating robots

## Environment

- Login: `robot` on `robots`, via Rex or ordinary SSH (`ssh robot@robots`).
- Development: `/home/robot/dev`; 2 vCPUs, 8 GiB guest RAM ceiling, persistent 64 GiB disk.
- Memory: free-page reporting returns unused guest pages to NASA automatically;
  the guest always sees 8 GiB, but host RAM is shared and not reserved. Compressed
  swap (up to 2 GiB logical capacity) buffers brief concurrent-agent/build spikes.
- Tools: Git, Nix/flakes, fish, direnv, tmux, Codex, Claude Code, bubblewrap,
  `github-bot`, and `nasa-approved-access`. Use a project's Nix development shell
  or `nix shell` for additional tools. The account has no sudo.
- Context: `robot-guide` prints this reference. Global Codex instructions are in
  `~/.codex/AGENTS.md`; Claude Code reads the same guide as `~/.claude/CLAUDE.md`.
  Start a new agent session after changing the deployed guide. A non-default
  `CODEX_HOME` needs equivalent instructions; do not copy personal auth/config.
- These files are versioned in `jmalexan/nix` under `hosts/nasa/vms/context/` and
  installed by Nix/Home Manager. Propose lasting updates there, not by editing
  generated symlinks. Store project-specific knowledge inside that project.

## Git repositories

Inspect `/etc/robot/repositories.json`. To start the configured infrastructure repo:

```sh
mkdir -p ~/dev
cd ~/dev
git clone https://github.com/jmalexan/nix.git
cd nix
git switch -c robot/topic
github-bot git push -u origin robot/topic
```

The clone is public. The push example is for an authorized completed change;
`github-bot` uses the infrastructure App, scoped to this repository. Follow the
repo's `AGENTS.md` and `docs/deployments.md` when preparing its release PR.

For another public repo, `git clone https://github.com/OWNER/REPO.git` needs no
credential. Pushing requires separately provisioned access. Delivery can be a
branch only; do not automatically create PRs. For another person's private repo,
the proposed broker would use the user's existing collaborator access from a
trusted system, allowing selected Git operations without returning credentials
to robots. That broker and a general coding App are not deployed yet.

## NASA and applications

| System | Entry point | Access here |
| --- | --- | --- |
| Approve | https://approve.nasa.jmalexan.com | Requester credential; human approves on their device |
| Updates | https://updates.nasa.jmalexan.com | Dashboard; releases still use the Nix PR workflow |
| NASA host | `nasa-approved-access --reason 'Specific task' -- COMMAND` | Explicit phone approval, dedicated account, no sudo, 15-minute limit |
| Other NASA apps | HTTPS routes in `hosts/nasa/services/nginx.nix` | Consult their repo docs/API; additional credentials are not implied |
| Personal home/Mac/HTPC | Separate environments | No direct agent access |

Use authenticated app APIs first. For host files or operations an API cannot
perform, the packaged approval client is available from any directory; the
repository's `tools/nasa-access.py --approved` honors the same requester path.
Only the request-creation token is present. It cannot approve or claim requests.
The old copied `nasa-journalctl` directory is not mounted in robots. Do not claim
local host logs exist here; consult available APIs or request approved access
when host logs are needed.

NASA HTTPS, the approved gate, DNS, and public web/package downloads are allowed.
The host firewall and `tag:agent` policy block ordinary host SSH/Rex and other
private-network access. An access failure is not permission to change that policy.

CI deploys approved Nix changes and checks guest readiness. Updating the guest
configuration restarts robots, so save work before an owner merges such a release.
The full recovery/migration guide is `docs/agent-vm.md` in the Nix repo.

## Current scope and follow-ups

The private collaborator-repo Git broker is a future service, not an available
command. AI tool authentication must be configured intentionally for this
workspace; no personal login directory is preloaded. App tokens are added only
for the particular app/task that needs them.

Approve/Updates design follow-ups and notification actions remain documented in
`docs/microapp-design-followups.md`; do not lose them during infrastructure work.
