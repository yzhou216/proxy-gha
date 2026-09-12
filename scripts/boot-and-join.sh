#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: boot-and-join.sh <qcow2-image> [stage]}"
stage="${2:-all}"

WORK="${WORK:-/nix/vm}"
sudo mkdir -p "$WORK" "$WORK/share"
sudo chown -R "$(id -u):$(id -g)" "$WORK"
transcript="$WORK/boot-transcript.${stage}.log"

mark() {
  echo "[$(date -u +%H:%M:%S)] $*"
}

fetch_token() {
  aud_enc=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$TS_AUDIENCE")
  curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$aud_enc" | jq -r .value
}

put_token() {
  local token
  token=$(fetch_token)
  test -n "$token" || { mark "token: empty token"; return 1; }
  printf '%s' "$token" > "$WORK/share/id-token" 2>/dev/null || {
    mark "token: direct write failed, retrying via sudo tee"
    printf '%s' "$token" | sudo tee "$WORK/share/id-token" >/dev/null
  }
  local size
  size=$(wc -c < "$WORK/share/id-token")
  mark "token: wrote ${size} bytes to $WORK/share/id-token"
}

stage_token() {
  mark "token: share=$WORK/share"
  printf '%s' "$TS_OAUTH_CLIENT_ID" > "$WORK/share/client-id"
  put_token
  mark "token: ok"
}

stage_qemu() {
  mark "qemu: installing qemu-system-x86 and qemu-utils via apt"
  sudo apt-get update -qq
  sudo apt-get install -y -qq --no-install-recommends qemu-system-x86 qemu-utils
  command -v qemu-system-x86_64 qemu-img >/dev/null
  mark "qemu: ok $(qemu-system-x86_64 --version | head -1)"
}

stage_disk() {
  command -v qemu-img >/dev/null
  df -h / /nix
  mark "disk: copying $image"
  cp --reflink=auto "$image" "$WORK/image.qcow2"
  chmod +w "$WORK/image.qcow2"
  qemu-img resize "$WORK/image.qcow2" 130G
  ls -l "$WORK/image.qcow2"
  mark "disk: ok size=$(du -h "$WORK/image.qcow2" | cut -f1)"
}

reclaim_token() {
  if [ -n "${TS_API_KEY:-}" ]; then
    printf '%s' "$TS_API_KEY"
    return 0
  fi
  if [ -z "${TS_OAUTH_SECRET:-}" ] || [ -z "${TS_RECLAIM_CLIENT_ID:-}" ]; then
    return 1
  fi
  body=$(curl -sS \
    -d "client_id=$TS_RECLAIM_CLIENT_ID" \
    -d "client_secret=$TS_OAUTH_SECRET" \
    -d "scope=devices:core" \
    https://api.tailscale.com/api/v2/oauth/token)
  printf '%s' "$body" | jq -r '.access_token // ""'
}

stage_reclaim() {
  if [ -z "${TS_TAILNET:-}" ]; then
    mark "reclaim: skipped (TS_TAILNET not set)"
    return 0
  fi
  token=$(reclaim_token) || true
  if [ -z "$token" ]; then
    mark "reclaim: skipped (unable to obtain access token)"
    return 0
  fi
  base="https://api.tailscale.com/api/v2/tailnet/-/devices"
  mark "reclaim: listing devices from $base"
  devices=$(curl -sS -H "Authorization: Bearer $token" "$base")
  ids=$(printf '%s' "$devices" | jq -r '
    .devices[]
    | select((.hostname == "gha-qemu" or .name == "gha-qemu") and ((.tags // []) | index("tag:ci")))
    | .id
  ' 2>/dev/null || true)
  if [ -z "$ids" ]; then
    mark "reclaim: no stale gha-qemu device found"
    return 0
  fi
  mark "reclaim: deleting devices:"
  printf '%s\n' "$ids"
  for id in $ids; do
    mark "reclaim: deleting device $id"
    curl -sS -X DELETE -H "Authorization: Bearer $token" \
      "https://api.tailscale.com/api/v2/device/$id" > /dev/null
  done
  mark "reclaim: done"
}

stage_boot() {
  command -v qemu-system-x86_64 >/dev/null
  mark "boot: share perms:"
  ls -ld "$WORK" "$WORK/share" 2>&1 | sed 's/^/  /'
  ls -la "$WORK/share" 2>&1 | sed 's/^/  /'
  # Use fixed cpu model.  With -cpu host on AMD runners, svm and ccp CPUID
  # bits pass through and udev autoloads kvm_amd, crashing the guest kernel.
  # shellcheck disable=SC2054 # QEMU expects a single comma-joined arg
  accel=(-accel tcg,thread=multi)
  test -e /dev/kvm && accel=(-accel kvm -cpu qemu64)
  mark "boot: accel=${accel[*]} starting qemu"
  qemu-system-x86_64 \
    "${accel[@]}" \
    -m 2048 \
    -smp 4 \
    -drive file="$WORK/image.qcow2",if=virtio,format=qcow2 \
    -nic user,model=virtio,hostfwd=tcp::2222-:22 \
    -virtfs local,path="$WORK/share",mount_tag=share,security_model=none \
    -display none -serial file:"$WORK/qemu.log" > "$WORK/qemu.out" 2> "$WORK/qemu.err" &
  qemu_pid=$!

  vm_ready=no
  ok=no
  deadline=$((SECONDS + 1200))
  while [ $SECONDS -lt $deadline ]; do
    put_token || { mark "boot: token write failed, retrying"; sleep 10; continue; }
    if grep -q VM-READY "$WORK/qemu.log" 2>/dev/null; then
      vm_ready=yes
    fi
    if [ -f "$WORK/share/login-ok" ]; then
      ok=yes
      break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      mark "boot: qemu exited early"
      break
    fi
    sleep 10
  done
  mark "boot: vm_ready=$vm_ready login=$ok"
  for f in login-status qemu.err qemu.log; do
    mark "=== $f ==="
    tail -60 "$WORK/$f" 2>/dev/null || true
  done
  keepalive="${TS_KEEPALIVE_SECONDS:-21540}"
  if [ "$ok" = yes ]; then
    mark "boot: VM joined tailnet, keeping alive ${keepalive}s"
    sleep "$keepalive"
  fi
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
  test "$ok" = yes
}

set -x
exec > >(tee "$transcript") 2>&1

case "$stage" in
  token) stage_token ;;
  reclaim) stage_reclaim ;;
  qemu) stage_qemu ;;
  disk) stage_disk ;;
  boot) stage_boot ;;
  all) stage_token && stage_reclaim && stage_qemu && stage_disk && stage_boot ;;
  *) echo "unknown stage $stage" >&2; exit 2 ;;
esac