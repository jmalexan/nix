# Remaining NASA access paths

The audit and original proposal below are historical. The current design is
[separate personal and agent environments](agent-vm.md): keep `home` personal,
create `robots` with `tag:agent`, and move automation there. **Do not retag `home`
or remove its personal credentials using the superseded proposal below.**

GitHub PR/check requirements, owner-only merges, and the production main-branch
restriction are active. The scoped bot is configured; release workflow and
VM rollout are combined in PR #57, awaiting the owner's merge. The owner reported applying the replacement
[Tailscale policy](tailscale-agent-policy.json), including its tests. Physical
VM/network isolation is prepared in this branch, not yet deployed.

Reviewed on 2026-11-06 after deploying the phone-approved connection gate.
This is a proposed rollout, not a claim that the restrictions below are active.
The gate implementation was committed locally as `d9b7a58`; it has not been
pushed. No NASA connection or permission change was made during this review.

## Observed state

| Path | Evidence | Current consequence |
| --- | --- | --- |
| Forwarded SSH agent | The local access wrapper found no usable agent. | Owner SSH forwarding is not currently available. Reintroducing it restores the owner's existing privileges; it is reserved for explicitly authorized maintenance. |
| Rex over Tailscale | Local Tailscale status shows `home`, `nasa`, `htpc`, and `Book` are untagged and share the same owner ID. `modules/rex.nix` permits that owner's login. | The container has the same identity that Rex accepts from the owner's personal devices. No Rex shell was opened to test this. |
| Tailnet policy | The owner supplied the active grant: `src: ["*"], dst: ["*"], ip: ["*"]`. | Adding a narrower grant alone will not restrict the container; the broad grant must be replaced. |
| LAN | The container uses `hostBridge = "br0"`; NASA trusts `br0`, and the container account is in wheel. | Tailscale policy does not filter direct LAN traffic. An IP-based denial for the container is inadequate if its privileged processes can change the source address. |
| GitHub deployment | The production environment API returned no protection rules and no deployment-branch policy. Active ruleset `20579942` protects the default branch only from deletion and non-fast-forward updates. | Ordinary pushes to `main` can reach the automatic deployment job without a human review requirement. |
| Deployment secrets | The production environment contains the SSH key/known-hosts and Tailscale OAuth secrets; the repository-level secret list is empty. Only names and placement were inspected. | The existing credentials are already in the right environment to benefit from a required reviewer, once automation no longer holds owner-level permissions. |
| GitHub identity | The local GitHub credential identifies as `jmalexan`, reports OAuth scopes `gist, read:org, repo`, and the account has repository administrator access. | The automation environment currently holds broad owner-level repository access. It is not a separate, restricted automation identity. |

The GitHub findings came from read-only API calls. The credential itself was not
printed, copied, changed, or exercised to modify protection settings. The tailnet
policy excerpt does not describe any other existing `tagOwners`, tests, SSH,
sharing, or routing settings; preserve those when editing it.

## Proposed Tailscale change

Give only the development container the tag `tag:dev-container`. Leave the Mac
and iPhone as personal, user-owned devices. Merge this tag owner into the existing
`tagOwners` map; preserve the existing CI tag configuration:

```json
"tagOwners": {
  "tag:dev-container": ["me@jmalexan.com"]
}
```

Replace the supplied allow-all **grant**, rather than adding the following beside
it. Keep any other settings until they have been reviewed. These addresses were
read from local Tailscale status and should be confirmed in the admin console:

```json
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["*"],
    "ip": ["*"]
  },
  {
    "src": ["tag:ci"],
    "dst": [
      "100.115.119.21", "fd7a:115c:a1e0::cd3a:7715",
      "100.116.173.35", "fd7a:115c:a1e0::bb3a:ad24"
    ],
    "ip": ["tcp:22"]
  },
  {
    "src": ["tag:dev-container"],
    "dst": ["100.115.119.21", "fd7a:115c:a1e0::cd3a:7715"],
    "ip": ["tcp:443"]
  }
]
```

The first grant preserves user-owned device access, including the owner's access
to Rex in `home`. Once tagged, `home` no longer matches that user-based grant.
The CI grant preserves deployment SSH to NASA and HTPC. The container grant
allows NAS HTTPS APIs, but excludes SSH and Rex. The phone-approved SSH gate
currently uses `10.0.1.10:2222` over the LAN; it is not listening on the Tailscale
address, so this proposal does not pretend to enable that route.
No other tagged peer devices were visible in the local status snapshot; confirm
offline and ephemeral integrations in the admin console before replacing the
wildcard grant.

Merge these tests with existing policy tests and use the Tailscale editor's
validation before saving. Also inspect any existing ACLs/grants for other broad
matches; every applicable allow must be considered.

```json
"tests": [
  {
    "src": "tag:dev-container",
    "accept": ["100.115.119.21:443"],
    "deny": [
      "100.115.119.21:22", "100.115.119.21:7297",
      "100.116.173.35:22", "100.116.173.35:7297",
      "100.70.106.119:22", "100.70.106.119:7297"
    ]
  },
  {
    "src": "tag:ci",
    "accept": ["100.115.119.21:22", "100.116.173.35:22"],
    "deny": ["100.115.119.21:7297"]
  },
  {
    "src": "me@jmalexan.com",
    "accept": [
      "100.115.119.21:22", "100.115.119.21:7297",
      "100.77.194.62:22", "100.77.194.62:7297"
    ]
  }
]
```

This is not yet a validated policy export: the full live policy and its CI tag
ownership were not obtained, and there is no connected tailnet administration
tool in this session. Apply it from a trusted personal device, validate it there,
then assign the tag to the existing `home` device. Do not re-enroll or tag the
personal Mac/iPhone. Tagging changes the device's identity and is the point at
which its existing Rex caller permissions change. Confirm personal-device access
to `home` before ending the trusted maintenance session.

## Direct LAN access

The Tailscale change is only one part of the boundary. A subsequent host-side
network change needs to restrict traffic originating from the container's
host-controlled interface, not merely packets claiming its current IP address.
Prefer an isolated routed network with an allowlist of required LAN services.
If retaining the bridge, the design must cover its forwarding and host-input
paths, IPv4 and IPv6, alternate NAS addresses, and routing via the LAN gateway.

Keep NAS HTTPS and gate port 2222, DNS, necessary app services, internet access
for development, and inbound owner access to the container. Deny direct host
administrator SSH and Rex routes from the container. Review indirect shell
relays through other owner-identified machines as well. Do not deploy an
untested source-IP firewall rule and describe it as this stronger boundary.

No bridge, firewall, source-address, or container-topology change is included in
the current rollout. A separate tested configuration and explicit host activation
permission are required; the existing private network and DNS must keep working.

## GitHub identity and deployment

Replace the owner's broad CLI credential in this container with a distinct
automation identity before relying on GitHub approval as a human boundary. Prefer
a GitHub App installed only on this repository, with content/PR permissions needed
to propose changes and no administration, environment, deployment-review, or
workflow-writing permissions. Review the separate updates-dashboard credential
too; its effective permissions have not been inspected in this audit.

Then require owner/code-owner PR review and successful checks for `main`, dismiss
stale approvals after new changes, require review of the latest push, and provide
no automation bypass. Add the trusted owner as the production environment's required
reviewer. Restrict that environment to `main`; disable administrator bypass for
deployment review. Keep the existing deployment credentials as environment secrets
so they are released only after approval. No duplicate repository-level secrets
were found; review other credentials/workflows before claiming full coverage.

Do not blindly enable GitHub's “Prevent self-review” for the current single-owner
workflow: it could prevent the only owner from approving their own manually
triggered release. A separate automation actor allows meaningful separation;
choose the self-review policy around the supported human release workflow.

A fine-grained token under the owner's account can narrow administrative access,
but it still represents the same human identity. Treat that as an interim
restriction, not equivalent to a separately identified automation actor. Issue
replacement credentials from a trusted device, verify the permitted workflow,
then remove/revoke the owner credential from the container. Never paste tokens
into chat or add them to the repository.

None of these GitHub settings or credentials has been changed. Pushing the local
implementation commit to `main` would currently trigger deployment to NASA and
HTPC after CI succeeds, so the commit remains local pending a publication decision.

## Acceptance before claiming all routes are gated

Verify from the container that owner SSH and Rex cannot establish host sessions
over LAN or Tailscale, including IPv6; do not use a real owner credential to
demonstrate a successful bypass. Verify from the trusted Mac/iPhone that normal
owner access and container access still work. Confirm CI deployment waits for the
human reviewer, and that the container's automation credential cannot change or
satisfy those protection settings. Recheck the phone-approved gate, denial/replay,
and API access after the network changes. Retain an owner-side rollback path.

References: [Tailscale device tags](https://tailscale.com/docs/features/tags),
[grant syntax](https://tailscale.com/docs/reference/syntax/grants),
[Rex principals](https://www.superlogical.com/rex/docs/linux/login-server),
[GitHub OAuth scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps),
[deployment protections](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
