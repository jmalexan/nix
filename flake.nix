{
  description = "nix system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";
    home-manager-stable.url = "github:nix-community/home-manager/release-25.11";
    home-manager-stable.inputs.nixpkgs.follows = "nixpkgs";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, agenix, disko, nix-darwin, home-manager, home-manager-stable, claude-code-nix, ... }:
    let
      mkUnstable = system: import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };

      linuxSystem = "x86_64-linux";
      darwinSystem = "aarch64-darwin";

      nixosSpecialArgs = {
        pkgs-unstable = mkUnstable linuxSystem;
        claude-code-pkg = claude-code-nix.packages.${linuxSystem}.default;
        inherit agenix home-manager-stable;
      };
      darwinSpecialArgs = {
        pkgs-unstable = mkUnstable darwinSystem;
        claude-code-pkg = claude-code-nix.packages.${darwinSystem}.default;
        inherit agenix;
      };

      commonModules = [ ./modules/common.nix ./modules/auto-upgrade.nix ./modules/trust-private-ca.nix agenix.nixosModules.default ];
    in
    {
      # Run `nix develop` to get a shell with secrets management tools.
      devShells.${linuxSystem}.default = nixpkgs.legacyPackages.${linuxSystem}.mkShell {
        packages = [ agenix.packages.${linuxSystem}.default ];
      };
      devShells.${darwinSystem}.default = nixpkgs.legacyPackages.${darwinSystem}.mkShell {
        packages = [ agenix.packages.${darwinSystem}.default ];
      };

      # Bare-metal NixOS host (replaces TrueNAS).
      # Deploy with: nixos-rebuild switch --flake .#nasa
      nixosConfigurations.nasa = nixpkgs.lib.nixosSystem {
        system = linuxSystem;
        specialArgs = nixosSpecialArgs;
        modules = commonModules ++ [
          ./hosts/nasa/default.nix
          disko.nixosModules.disko
          ./hosts/nasa/disko.nix
          home-manager-stable.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jmalexan = import ./home/linux.nix;
          }
        ];
      };

      # Home-theater PC (Minisforum UM760, AMD Radeon 780M).
      # Tracks nixos-unstable so we get Plasma 6.7 (Bigscreen) plus the newest
      # kernel/Mesa/amdgpu HDR work; nasa/book stay on stable nixpkgs.
      # Deploy with: nixos-rebuild switch --flake .#htpc
      nixosConfigurations.htpc = nixpkgs-unstable.lib.nixosSystem {
        system = linuxSystem;
        specialArgs = nixosSpecialArgs;
        modules = commonModules ++ [
          ./hosts/htpc/default.nix
          disko.nixosModules.disko
          ./hosts/htpc/disko.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jmalexan = import ./home/linux.nix;
          }
        ];
      };

      # macOS (Apple Silicon) MacBook.
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
            home-manager.users.jmalexan = import ./home/book.nix;
          }
        ];
      };
    };
}
