# robots workspace

This environment is the `robots` VM, running as `robot`. NASA is its host;
`home` is Jonathan's separate personal environment. Confirm the actual hostname
when context is unclear. Work in `/home/robot/dev`, using separate project clones.

Read `/etc/robot/systems.md` for available tools/services and
`/etc/robot/repositories.json` for repository access and delivery defaults. Those
files describe capabilities; they do not grant credentials or permission.
Read each project's own instructions before editing it.

The VM is the local execution boundary. Proceed with task-related reads, edits,
commands, installs, builds, tests, and Git operations inside `robots` without
asking for additional confirmation. Preserve unrelated user work. External
read-only operations through available authorized APIs/access paths need no
extra chat approval. Existing credentials and network reachability do not grant
new access; keep the NASA phone-approved connection flow below.

Before an external write, determine whether the user's request or the project's
delivery instructions already authorize that specific action. If so, proceed
without asking again (for example, pushing a requested branch or opening this
repository's required PR). Otherwise obtain approval before changing external
apps, hosts, repositories, infrastructure, or permissions. Ask before work outside
the requested scope. Local permission bypass is not authorization for external
writes. Keep release approval and production controls below intact.

For ordinary projects, follow the user's requested outcome: local edits, a
commit, a pushed branch, or a PR. A pushed branch does not imply creating a PR.
Do not impose the Nix repository's release process on other projects.

For `jmalexan/nix`, use `github-bot` for authenticated Git/GitHub operations.
Prepare a branch and PR. Once the policy in `docs/deployments.md` is activated,
the owner's approval of the current changes authorizes release; auto-merge still
waits for required checks. Do not merge, enable auto-merge, push main, dispatch
production, or change protections without authorization for that specific action.
The owner's administrator exemption is not an agent permission. No routine
maintenance SSH tunnel is needed for releases.

Public repos can be cloned over HTTPS. Use `github-bot` for `jmalexan/nix`.
When configured, `git-broker repositories` lists explicitly allowed collaborator
repos and write namespaces; use `git-broker clone/fetch/push` for those repos.
Broker pushes require phone approval for the exact repository, branch, commit,
and remote tip; use `git-broker push --reason 'Concrete purpose'`. That approval
is the remote-update permission; do not ask for duplicate chat confirmation.
Broker access is a capability, not permission for unrelated work or pushes.
Do not fall back to personal GitHub/SSH credentials, forward an SSH agent, or
assume another repo is authorized because its URL is known.

Use app APIs for app operations. Host operations require the phone-approved
`nasa-approved-access` flow: explain the need and supply a concrete reason. Its
approval is connection permission; do not ask for duplicate chat confirmation.
The session has no sudo and expires. Do not bypass the network boundary.

Keep secrets out of instructions, catalogs, logs, and commits. Ask for missing
access only when the task needs it, after completing independent authorized work.
Prefer concise app text and shared UI components. Preserve unrelated user work.
