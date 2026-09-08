#!/usr/bin/env bash
set -euo pipefail

output=$(nix run nixpkgs#nixos-rebuild -- build-image \
  --flake "${GITHUB_WORKSPACE}#gha-qemu" \
  --image-variant qemu \
  --accept-flake-config)
printf '%s\n' "$output" | head -1