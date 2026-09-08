{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };
  outputs = { self, nixpkgs, ... }:
  let
    system = "x86_64-linux";
  in
  {
    nixosConfigurations.gha-qemu = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ({ modulesPath, ... }: {
          imports = [ "${modulesPath}/image/images.nix" ];
        })
        ./configuration.nix
      ];
    };
  };
}