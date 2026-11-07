{
  description = "nix system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager-stable.url = "github:nix-community/home-manager/release-26.05";
    home-manager-stable.inputs.nixpkgs.follows = "nixpkgs";
    # Declarative KDE Plasma config. Only htpc uses it — it is the supported
    # home for the kglobalshortcutsrc surgery the remote depends on.
    plasma-manager.url = "github:nix-community/plasma-manager";
    plasma-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";
    plasma-manager.inputs.home-manager.follows = "home-manager";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    rex.url = "https://pkgs.superlogical.com/rex/nix/preview.tar.gz";
    rex.inputs.nixpkgs.follows = "nixpkgs";
    # The login server loads the host's PAM modules, so its glibc must match.
    rex-unstable.url = "https://pkgs.superlogical.com/rex/nix/preview.tar.gz";
    rex-unstable.inputs.nixpkgs.follows = "nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      microvm,
      agenix,
      disko,
      nix-darwin,
      home-manager,
      home-manager-stable,
      plasma-manager,
      claude-code-nix,
      rex,
      rex-unstable,
      ...
    }:
    let
      mkUnstable =
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };

      linuxSystem = "x86_64-linux";
      darwinSystem = "aarch64-darwin";
      systems = [
        linuxSystem
        darwinSystem
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      stablePkgs = system: nixpkgs.legacyPackages.${system};
      vars = import ./lib/vars.nix;

      nixosSpecialArgs = {
        pkgs-unstable = mkUnstable linuxSystem;
        claude-code-pkg = claude-code-nix.packages.${linuxSystem}.default;
        inherit
          agenix
          home-manager-stable
          rex
          vars
          ;
      };
      darwinSpecialArgs = {
        pkgs-unstable = mkUnstable darwinSystem;
        claude-code-pkg = claude-code-nix.packages.${darwinSystem}.default;
        inherit agenix vars;
      };

      commonModules = [
        ./modules/common.nix
        agenix.nixosModules.default
      ];

      packageDiff = (stablePkgs linuxSystem).writeShellApplication {
        name = "package-diff";
        runtimeInputs = [ (stablePkgs linuxSystem).nix ];
        text = ''
          host="''${1:?usage: package-diff <nasa|htpc>}"
          case "$host" in
            nasa | htpc) ;;
            *) echo "unknown NixOS host: $host" >&2; exit 2 ;;
          esac

          echo "Building the current main and working-tree closures for $host..." >&2
          old=$(nix build --no-link --print-out-paths \
            "${vars.repository}#nixosConfigurations.$host.config.system.build.toplevel")
          new=$(nix build --no-link --print-out-paths \
            ".#nixosConfigurations.$host.config.system.build.toplevel")
          nix store diff-closures "$old" "$new"
        '';
      };
    in
    {
      # Run `nix develop` to get a shell with secrets management tools.
      devShells = forAllSystems (
        system:
        let
          pkgs = stablePkgs system;
        in
        {
          microapps = pkgs.mkShell {
            packages = [
              (import ./apps/microapps { inherit pkgs; }).python
              pkgs.nodejs
              pkgs.ruff
              pkgs.nixfmt
            ];
          };
          notifications = pkgs.mkShell {
            packages = [
              (import ./apps/notifications { inherit pkgs; }).python
              pkgs.ruff
              pkgs.nixfmt
              pkgs.nodejs
              pkgs.librsvg
              pkgs.actionlint
            ];
          };
          default = pkgs.mkShell {
            packages = [
              agenix.packages.${system}.default
              pkgs.deadnix
              pkgs.nixfmt
              pkgs.statix
            ];
          };
        }
      );

      formatter = forAllSystems (system: (stablePkgs system).nixfmt);

      packages = forAllSystems (
        system:
        let
          platform = import ./apps/microapps { pkgs = stablePkgs system; };
        in
        {
          github-bot = import ./tools/github-bot.nix { pkgs = stablePkgs system; };
          approvals = platform.server;
          approvals-web = platform.frontend;
          nasa-approved-access = platform.access;
          notifications = (import ./apps/notifications { pkgs = stablePkgs system; }).server;
          notifications-admin = (import ./apps/notifications { pkgs = stablePkgs system; }).admin;
        }
      );

      nixosModules.microapps = import ./modules/microapps.nix;
      nixosModules.approval-ssh-gate = import ./modules/approval-ssh-gate.nix;
      nixosModules.notification-bridge = import ./modules/notification-bridge.nix;

      checks = forAllSystems (
        system:
        let
          pkgs = stablePkgs system;
        in
        {
          microapps = (import ./apps/microapps { inherit pkgs; }).tests;
          microapps-web = (import ./apps/microapps { inherit pkgs; }).frontend;
          notifications = (import ./apps/notifications { inherit pkgs; }).tests;
          lint =
            pkgs.runCommand "nix-config-lint"
              {
                nativeBuildInputs = [
                  pkgs.deadnix
                  pkgs.findutils
                  pkgs.nixfmt
                  pkgs.nodejs
                  (pkgs.python3.withPackages (ps: [ ps.cryptography ]))
                  pkgs.ruff
                ];
              }
              ''
                cp -R ${self} source
                chmod -R u+w source
                cd source
                deadnix --fail .
                find . -name '*.nix' -print0 | xargs -0 nixfmt --check
                ruff check --select E4,E7,E9,F,I hosts/nasa/services/updates-dashboard/*.py
                ruff format --check hosts/nasa/services/updates-dashboard/*.py
                PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
                  hosts/nasa/services/updates-dashboard/test_dashboard.py
                ruff check --select E4,E7,E9,F,I tools/deployment-plan.py tools/test_deployment_plan.py tools/github-bot.py tools/test_github_bot.py tools/ci-reuse.py tools/test_ci_reuse.py
                ruff format --check tools/deployment-plan.py tools/test_deployment_plan.py tools/github-bot.py tools/test_github_bot.py tools/ci-reuse.py tools/test_ci_reuse.py
                PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tools/test_deployment_plan.py tools/test_github_bot.py tools/test_ci_reuse.py
                ruff check --select E4,E7,E9,F,I tests/agent_network.py
                ruff format --check tests/agent_network.py
                node --check hosts/nasa/services/updates-dashboard/app.js
                ruff check --select E4,E7,E9,F,I apps/microapps/backend apps/microapps/tests apps/microapps/export_api.py tools/nasa-access.py tools/test_nasa_access.py
                ruff format --check apps/microapps/backend apps/microapps/tests apps/microapps/export_api.py tools/nasa-access.py tools/test_nasa_access.py
                PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tools/test_nasa_access.py
                ruff check --select E4,E7,E9,F,I apps/notifications/backend apps/notifications/export_api.py apps/notifications/ios/signing.py apps/notifications/ios/Tests
                ruff format --check apps/notifications/backend apps/notifications/export_api.py apps/notifications/ios/signing.py apps/notifications/ios/Tests
                PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s apps/notifications/ios/Tests -p 'test_*.py'
                node --check apps/notifications/web/settings.js
                touch "$out"
              '';
        }
        // nixpkgs.lib.optionalAttrs (system == linuxSystem) {
          approval-ssh-gate = import ./apps/microapps/tests/gate-vm.nix { inherit pkgs; };
          agent-network = import ./tests/agent-network.nix { inherit pkgs; };
          agent-guest = import ./tests/agent-guest.nix {
            inherit pkgs nixpkgs microvm;
            specialArgs = nixosSpecialArgs;
          };
        }
      );

      apps.${linuxSystem}.package-diff = {
        type = "app";
        program = "${packageDiff}/bin/package-diff";
        meta.description = "Compare installed package versions with the deployed main branch";
      };

      # Bare-metal NixOS host (replaces TrueNAS).
      # Deploy with: nixos-rebuild switch --flake .#nasa
      nixosConfigurations.nasa = nixpkgs.lib.nixosSystem {
        system = linuxSystem;
        specialArgs = nixosSpecialArgs;
        modules = commonModules ++ [
          microvm.nixosModules.host
          ./hosts/nasa/default.nix
          ./modules/ssh-deploy.nix
          ./modules/trust-private-ca.nix
          disko.nixosModules.disko
          ./hosts/nasa/disko.nix
          home-manager-stable.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit vars; };
            home-manager.users.jmalexan = import ./home/linux.nix;
          }
        ];
      };

      # Home-theater PC (Minisforum UM760, AMD Radeon 780M).
      # Tracks nixos-unstable so we get Plasma 6.7 (Bigscreen) plus the newest
      # kernel/Mesa/amdgpu HDR work; nasa stays on stable nixpkgs.
      # Deploy with: nixos-rebuild switch --flake .#htpc
      nixosConfigurations.htpc = nixpkgs-unstable.lib.nixosSystem {
        system = linuxSystem;
        specialArgs = nixosSpecialArgs // {
          rex = rex-unstable;
        };
        modules = commonModules ++ [
          ./hosts/htpc/default.nix
          ./modules/ssh-deploy.nix
          ./modules/trust-private-ca.nix
          disko.nixosModules.disko
          ./hosts/htpc/disko.nix
          home-manager.nixosModules.home-manager
          (
            { pkgs, ... }:
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit vars; };
              home-manager.users.jmalexan = import ./home/htpc.nix;
              home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ];
              # Runtime-written files such as jellyfin-mpv-shim/input.conf can
              # conflict repeatedly. Rotate existing .hm-bak files to numbered
              # backups so unattended activation preserves every copy without
              # failing on a backup left by an earlier deployment.
              home-manager.backupCommand = pkgs.writeShellScript "home-manager-backup" ''
                exec ${pkgs.coreutils}/bin/mv --backup=numbered --no-target-directory -- "$1" "$1.hm-bak"
              '';
            }
          )
        ];
      };

      # macOS (Apple Silicon) MacBook. nix-darwin and Home Manager both follow
      # nixpkgs-unstable; this keeps the desktop/tooling host current while nasa
      # remains on the stable release branch.
      # Attr matches the hostname ("Book") so `darwin-rebuild switch --flake .`
      # resolves it automatically; the explicit form still works:
      # Deploy with: darwin-rebuild switch --flake .#Book
      darwinConfigurations.Book = nix-darwin.lib.darwinSystem {
        specialArgs = darwinSpecialArgs;
        modules = [
          ./hosts/book/default.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit vars; };
            home-manager.users.jmalexan = import ./home/book.nix;
          }
        ];
      };
    };
}
