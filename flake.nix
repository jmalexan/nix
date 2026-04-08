{
  description = "nix system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, ... }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      specialArgs = { inherit pkgs-unstable; };
      commonModules = [ ./configuration.nix ];
    in
    {
      # NixOS VM running inside TrueNAS / the new host.
      nixosConfigurations.nix = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = commonModules ++ [ ./hosts/nix/default.nix ];
      };

      # Bare-metal NixOS host (replaces TrueNAS).
      # Deploy with: nixos-rebuild switch --flake .#nixhost
      nixosConfigurations.nixhost = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = commonModules ++ [ ./hosts/nixhost/default.nix ];
      };
    };
}
