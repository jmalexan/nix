# Architecture and ownership

The flake is organized by ownership rather than by option type:

- `flake.nix` wires inputs, hosts, checks, and developer tooling.
- `lib/vars.nix` contains shared identity, network, domain, and repository data.
- `modules/` contains policy genuinely shared by more than one host.
- `hosts/<host>/default.nix` is the composition root and compatibility-version
  owner for each machine.
- `home/` contains Home Manager policy; host-specific UI behavior stays there.
- `hosts/nasa/services/default.nix` is the explicit NAS service inventory.
- `hosts/nasa/containers/` contains system containers, not application services.

`nasa` uses stable nixpkgs. `htpc` and `Book` use unstable because their desktop
and hardware support benefit from fresher packages. State versions belong to
the host or home profile that first created the corresponding state and should
not be bumped as part of routine upgrades.

Docker is a NAS-level runtime dependency declared once in
`hosts/nasa/services/containers.nix`. Individual service modules own only their
container, persistence, network integration, and adjacent service units. nginx
is the single owner of public virtual hosts and TLS defaults.

The `home` NixOS container is a host-level topology concern. Its module lives in
`hosts/nasa/containers/` and is imported explicitly by the NAS composition root.

The [internal tools platform](internal-tools.md) provides independent
micro apps using reusable styling, application components, and Nix deployment
conventions. It uses FastAPI backends and mobile web clients with push
notifications, iPhone acceptance checks, and an adaptive layout for future
iPhone Duo compatibility. Physical Duo testing is deferred. It includes an
adoption path for System updates and an independently enforced approval service.
The foundation and approval service are deployed on NASA, with physical iPhone
notifications and a live phone-approved SSH connection verified. The
[connection gate](approval-ssh-gate.md) enforces one-use approvals and a bounded
lifetime for its dedicated account. Restrictions on other administrative access
paths remain a separate follow-up.
