# NAS access from the home development container

Use application APIs first. BookOrbit's local session helper covers library
queries, metadata, requests, release searches and its configured download client.
Use `nasa-journalctl` for NAS service logs. Neither needs an SSH connection.

Use SSH when a concrete task needs an operation those interfaces cannot perform,
such as verifying host filesystem/inode identity or hardlinking downloaded books
into the manga library. Repository instructions require the agent to explain that
need before using the fallback. The user requires explicit permission before
opening a NASA SSH connection, even when credentials are available. Repository
editing and local tests do not authorize a host connection. Approval in the phone
app is explicit connection permission; it does not require duplicate chat approval.

The [phone-approved gate](approval-ssh-gate.md) is deployed and verified. Prefer
`tools/nasa-access.py --approved --reason '...' -- <command>` requests one
connection as `nasa-automation`, without a forwarded agent. It has no sudo,
read-only host files, and a 15-minute host-enforced maximum. Reconnecting requires
a fresh approval. There is no automatic fallback to administrator access.

For privileged maintenance outside that account's scope, obtain explicit
permission for the legacy connection and use the forwarded-agent workflow below.

## Legacy maintenance connection

From a computer whose existing SSH agent has a NAS-authorized key loaded:

```sh
ssh -A jmalexan@home.nasa.lan
```

Leave that session open while NAS work is in progress. This forwards an agent,
not the private key. Agent forwarding lets processes running as your user in the
development container authenticate with the forwarded key while it is available;
it is not a restricted NAS service account. Closing the session removes that
forwarded access. The helper does not save a NAS password or private key.

If the agent has no identities, load your usual NAS identity on the originating
computer, not inside the development container. Never paste credentials into chat.

## Run a specific operation

From this repository in the home container:

```sh
nix shell --inputs-from . nixpkgs#python3 --command python3 tools/nasa-access.py \
  --reason 'Verify same-filesystem storage; BookOrbit does not expose host inode information' \
  -- stat -c '%d %i %n' /Data/smb/Torrents/BookOrbit /Data/smb/Media/Manga
```

Use `--dry-run` to review a command without connecting. If multiple forwarded
agents are active, select one with `--agent PATH`. The wrapper discovers owned
agent sockets in both `/tmp/ssh-*/agent.*` and `~/.ssh/agent/`, as well as the
socket named by `SSH_AUTH_SOCK`.

The target is `jmalexan@10.0.1.10`, the NAS address already trusted in this
environment's SSH known-hosts file. SSH host-key checking is mandatory. A changed
host key is an identity issue to resolve through a trusted channel, never a reason
to disable checking. The wrapper disables forwarding onward to the NAS and uses
only the selected agent for authentication. It does not change NAS authorization.

The wrapper records the reason, executable, command digest and exit status in
`.local/nasa-access/events.jsonl` (mode `600`). It does not record arguments,
stdin or output, which may contain credentials. Keep secrets out of reason text
and command-line arguments. A start event without an end means the connection or
client was interrupted; inspect the operation's actual result before retrying.

For file changes, prefer a bounded script with a preview, no overwrites, and an
explicit verification step. Verify hardlinks by matching device and inode numbers,
not merely by comparing names, sizes or checksums. Library and download paths
inside separate Docker bind mounts can reject hardlinks even when their host
paths are on one filesystem; creating the links through host paths avoids that
mount boundary without exposing a broader Docker mount.

This wrapper makes the access workflow repeatable and auditable. It is not a
security boundary or command allowlist: the forwarded key retains its existing
NAS permissions. A permanently available restricted account would be a separate
design and provisioning change.
