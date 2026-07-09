#!/usr/bin/env bash
set -euo pipefail

shopt -s dotglob
cp dotfiles/* ~

ID_ED25519_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL68+PiHa4+qSZNaj3MtqX7ZA3wL9M/2R/lVT2nqo9KS yiyu@galago"
mkdir -p ~/.ssh
echo "$ID_ED25519_PUB" >>~/.ssh/authorized_keys
sudo mkdir -p /var/empty
sudo "$(command -v ssh-keygen)" -A
sudo "$(command -v sshd)"

cloudflared tunnel run --token "$CLOUDFLARED_TOKEN" &

sleep 5h 59m
