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
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, agenix, disko, nix-darwin, home-manager, ... }:
    let
      mkUnstable = system: import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };

      linuxSystem = "x86_64-linux";
      darwinSystem = "aarch64-darwin";

      nixosSpecialArgs = {
        pkgs-unstable = mkUnstable linuxSystem;
        inherit agenix;
      };
      darwinSpecialArgs = {
        pkgs-unstable = mkUnstable darwinSystem;
        inherit agenix;
      };

      commonModules = [ ./configuration.nix agenix.nixosModules.default ];
    in
    {
      # Run `nix develop` to get a shell with secrets management tools.
      devShells.${linuxSystem}.default = nixpkgs.legacyPackages.${linuxSystem}.mkShell {
        packages = [ agenix.packages.${linuxSystem}.default ];
      };
      devShells.${darwinSystem}.default = nixpkgs.legacyPackages.${darwinSystem}.mkShell {
        packages = [ agenix.packages.${darwinSystem}.default ];
      };

      # NixOS VM running inside TrueNAS / the new host.
      nixosConfigurations.nix = nixpkgs.lib.nixosSystem {
        system = linuxSystem;
        specialArgs = nixosSpecialArgs;
        modules = commonModules ++ [
          ./hosts/nix/default.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jmalexan = import ./home/linux.nix;
          }
        ];
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
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jmalexan = import ./home/linux.nix;
          }
        ];
      };

      # macOS (Apple Silicon) MacBook.
      # Deploy with: darwin-rebuild switch --flake .#book
      darwinConfigurations.book = nix-darwin.lib.darwinSystem {
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
