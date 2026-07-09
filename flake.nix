{
  description = "gha runners";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=master";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = pkgs.cloudflared;
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            cloudflared
            openssh
          ];
        };
      }
    );
}
