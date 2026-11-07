# Git broker

NASA is configured to activate the broker on the next approved release. The
repository policy and upstream credential are encrypted with agenix. The upstream
credential is retained on NASA; robots receives only the separately generated
broker credential. The existing `github-bot`
identity remains scoped to `jmalexan/nix`.

## Boundary

The trusted host retains the upstream GitHub credential. Robots receives only a
broker credential, which authorizes a configured set of repositories. The broker
accepts aliases, never caller-supplied upstream URLs or command arguments. Each
repository has an explicit read policy and optional top-level write namespaces,
for example `robot/`. An empty namespace list makes a repository read-only.

Clone and fetch return ordinary Git bundles. Push uploads a bundle plus one
branch, commit ID, and expected remote tip. Before contacting GitHub to write,
the broker validates the branch namespace and ref syntax, imported objects,
commit type, complete object graph, and fast-forward ancestry. Uploaded objects
are inspected in disposable bare staging repositories rather than retained in
the upstream caches. An exact upstream
lease rejects races after validation. Every remote push also requires a separate,
explicit, single-use owner approval for the exact repository, branch, new commit,
and expected remote tip. Clone and fetch do not require phone approval. Main/default branches outside the write
namespace, tags, deletions, and history rewrites cannot be pushed. This is an API
policy on the broker, not an instruction that robots can bypass with a Git flag.
GitHub branch protections and organization policies still apply.

The broker runs Git in bare caches without checking out code, running repository
hooks, loading the owner's Git configuration, or exposing a shell. It never runs
builds/tests from repositories. GitHub authentication is supplied only through
the environment of fixed HTTPS GitHub operations. Redirects, SSH, credential
helpers, system/global Git config, and inherited tracing are disabled. No raw
GitHub API proxy, arbitrary `gh` command, merge, PR creation, or deployment
endpoint is exposed. Normal project work and commits happen inside robots.

Private repository names can stay in a root-only JSON allowlist loaded through
systemd credentials rather than appearing in the public Nix repository/store.
The broker's read API reveals only the configured repositories to its client.
Successful operations log repository aliases, branch names and commit IDs, not
source contents, authorization headers, or provider errors. Provider failures
are replaced with fixed error messages. The host service has private state,
resource limits, and bounded transfers. Bare caches are disposable; they are not
an independent backup of upstream repositories or unpushed robot work.

## Client use

After activation and client-token provisioning on robots:

```sh
git-broker repositories
git-broker clone project ~/dev/project
cd ~/dev/project
git switch -c robot/my-change
# Edit, test, and commit with normal local Git.
git-broker fetch
git-broker push --reason "Publish the requested change"
```

The clone's `origin` URL is `broker://project`; it contains no GitHub credential.
Use `git-broker fetch/push` for network operations, and normal `git` for local
status, branches, diff, commit, merge, etc. A push uses the same local/remote
branch name. Fetch updates `origin/*` and tags without changing local branches
or the worktree. Fetch and merge/rebase upstream changes before retrying a stale
push. The broker never automatically creates a PR; follow the project's delivery
instructions and separately authorize any future GitHub API capability.

## Push approvals

The CLI creates a `git.push` request in Approve and prints its phone/web link.
It freezes the bundle and commit before waiting. The owner sees the repository,
branch, full commit, expected tip (or New branch), and reason. Approve and Reject
can be used from native notifications when the complete scope fits; otherwise tap
the notification to review the web page. The existing passkey web flow remains
available. Phone approval is permission for that exact update; no duplicate chat
confirmation is needed for the same update.

The broker, not the CLI, enforces the grant. After validating the bundle and
current upstream branch, it consumes the approval atomically through a host-only
claiming credential. That credential is shared only by Approve and the broker;
it is never a VM credential. The agent's requester token can create requests and
read their status, but cannot approve or claim them. Direct API callers need the
same exact unused grant. Missing approval service/credentials fail closed.

Pending requests expire after ten minutes; an approved request must be claimed
within two minutes and before its original expiry. Claimed pushes have a
three-minute execution deadline. Git and its helper processes are killed on a
timeout. Denial, expiry, changed scope, changed remote tip, or a consumed request
prevents the write. There is no automatic remote-write retry or offline queue.
A network failure can leave the upstream outcome uncertain: fetch to check it,
then obtain a new approval if another push is needed.

The first version transfers full snapshots and history with a 128 MiB default
bundle limit, configurable per broker. It does not support shallow clones,
submodule recursion, Git LFS payloads, empty upstream repositories, tag writes,
branch deletion, or force pushes. Seed empty repositories on a trusted device.
Fetching/pushing large repositories may require a larger reviewed resource limit.

## Activation preparation

For a private outside-collaborator repository, GitHub currently lists
fine-grained PAT support as a limitation. Prefer a repository-scoped GitHub App
or fine-grained credential if the repository owner/access model permits it.
Otherwise use a dedicated expiring classic PAT with the required `repo` scope,
kept only on the trusted host. Organization policy may require SSO authorization
or prohibit that token type. Do not reuse the Nix bot, Updater credential, owner
SSH identity, or a personal token already stored in another environment.

[GitHub token limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations).

Encrypt the upstream token and any private allowlist on the owner's trusted
machine for the existing agenix recipients, as with the APNs key. Transfer only
the ciphertext to robots. Never send plaintext credentials through chat, logs,
source, Git remote URLs, or command-line arguments. NASA provisions a separately
random broker client token through `git-broker-client-credential.service` and
preserves it across deployments. Only that token passes into robots via the
existing VM credential mechanism, installed as robot-owned mode 0600 at
`~/.local/share/git-broker/token`. The upstream token is never a VM credential.
The generated broker token joins the encrypted Restic backup. Restart the broker
and VM after intentionally rotating the client token; restart the broker after
rotating the upstream token. Do not reuse the same credential for both roles.

An example allowlist (not a live repository authorization):

```json
{"project":{"github":"OWNER/REPOSITORY","write_prefixes":["robot/"]}}
```

The Nix module supports `services.gitBroker` with:

- `enable`, `port`, and `maxBundleBytes`;
- exactly one of `repositories` (public config) or `repositoriesFile` (private JSON);
- `clientTokenFile` and `upstreamTokenFile` (root-only mutable/agenix paths);
- `approvalOrigin` and `approvalTokenFile` for the trusted Approve claim API.

NASA's optional route is `https://git-broker.nasa.jmalexan.com`, restricted to
robots, LAN, Tailscale, and loopback. It uses the existing private TLS setup and
adds no broad host/network access. Client TLS verification is mandatory.
The encrypted policy and upstream credential are declared in NASA's service
inventory. Activation provisions the broker client token, delivers it to the VM,
and installs the client and catalog discovery. Deployment health checks require
both the broker service and guest readiness. The VM integration is tested with
fake credentials across two boots. Repository checks do not exercise live
collaborator access. After deployment, verify the authenticated repository list
and clone/fetch access before starting project work.

## Checks

`nix build .#checks.x86_64-linux.git-broker` runs local bare upstream tests and a
real verified-TLS client round trip: clone, fetch, and namespace-limited push.
Tests cover authentication, denied repositories/refs, read-only repositories,
invalid/deletion/non-fast-forward pushes, stale updates, an upstream race,
transfer limits, credential isolation, and sanitized failures. They never use
real account credentials or write to GitHub.

[Git bundle documentation](https://git-scm.com/docs/git-bundle).
