{
  description = "gha runners";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=master";
    flake-utils.url = "github:numtide/flake-utils";
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      nix-index-database,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        nix-index-db = nix-index-database.packages.${system}.nix-index-with-db;
      in
      {
        packages.default = pkgs.cloudflared;
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            cloudflared
            openssh
            nix-index-db
          ];
          shellHook = ''
            source ${nix-index-db}/etc/profile.d/command-not-found.sh
          '';
        };
      }
    );
}
