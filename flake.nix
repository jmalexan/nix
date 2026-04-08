{
  description = "nix system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, agenix, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      specialArgs = { inherit pkgs-unstable agenix; };
      commonModules = [ ./configuration.nix agenix.nixosModules.default ];
    in
    {
      # Run `nix develop` to get a shell with secrets management tools.
      devShells.${system}.default = pkgs.mkShell {
        packages = [ agenix.packages.${system}.default ];
      };
      # NixOS VM running inside TrueNAS / the new host.
      nixosConfigurations.nix = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = commonModules ++ [ ./hosts/nix/default.nix ];
      };

      # Bare-metal NixOS host (replaces TrueNAS).
      # Deploy with: nixos-rebuild switch --flake .#nasa
      nixosConfigurations.nasa = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = commonModules ++ [ ./hosts/nasa/default.nix ];
      };
    };
}
