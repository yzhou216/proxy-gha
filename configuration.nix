{ pkgs, ... }:
{
  virtualisation.diskSize = 10 * 1024;
  boot.growPartition = true;
  boot.kernelModules = [ "9p" "9pnet_virtio" ];
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "9p" "9pnet_virtio" ];
  boot.kernelParams = [ "console=ttyS0,115200" ];
  systemd.network.enable = true;
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "*";
    networkConfig.DHCP = "yes";
  };
  fileSystems."/share" = {
    device = "share";
    fsType = "9p";
    options = [ "trans=virtio" "version=9p2000.L" "cache=loose" ];
  };
  services.tailscale.enable = true;
  networking.hostName = "gha-qemu";
  users.users.yiyu = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$yM8t/1VCAl66Y7XD$dmvt7Xq6iGLU3uJ9lcpUvr/7PZxt7IzYsoZbm4s42pejndU4IAMW4YbP4JcQK5KxI5DzSwLjPFCYY/OETznnO1";
  };
  systemd.services.ts-login = {
    description = "Tailscale login with secrets from the 9p share";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      set -x
      for i in $(seq 1 40); do
        test -f /share/client-id -a -f /share/id-token && break
        sleep 3
      done
      for i in $(seq 1 20); do
        CLIENT_ID=$(cat /share/client-id 2>/dev/null)
        ID_TOKEN=$(cat /share/id-token 2>/dev/null)
        if test -n "$CLIENT_ID" -a -n "$ID_TOKEN"; then
          if /run/current-system/sw/bin/tailscale up \
            --client-id="$CLIENT_ID?preauthorized=true&ephemeral=true" \
            --id-token="$ID_TOKEN" \
            --advertise-tags=tag:ci \
            --hostname=gha-qemu \
            --ssh; then
            touch /share/login-ok
            break
          fi
        fi
        sleep 5
      done
      /run/current-system/sw/bin/tailscale status > /share/login-status 2>&1 || true
    '';
  };
  systemd.services.vm-ready = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = "echo VM-READY > /dev/console";
  };
  environment.systemPackages = with pkgs; [
  ];
}