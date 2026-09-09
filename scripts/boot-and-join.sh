#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: boot-and-join.sh <qcow2-image> [stage]}"
stage="${2:-all}"

WORK=/nix/vm
sudo mkdir -p "$WORK" "$WORK/share"
sudo chown "$(id -u):$(id -g)" "$WORK" "$WORK/share"
transcript="$WORK/boot-transcript.log"

mark() {
  echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$transcript"
}

fetch_token() {
  aud_enc=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$TS_AUDIENCE")
  curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$aud_enc" | jq -r .value
}

stage_token() {
  mark "token: share=$WORK/share"
  printf '%s' "$TS_OAUTH_CLIENT_ID" > "$WORK/share/client-id"
  token=$(fetch_token)
  test -n "$token" || { mark "token: empty token"; return 1; }
  printf '%s' "$token" > "$WORK/share/id-token"
  mark "token: ok len=${#token}"
}

stage_qemu() {
  mark "qemu: building nixpkgs#qemu"
  QEMU_BIN=$(nix build --no-link --print-out-paths nixpkgs#qemu --accept-flake-config 2>&1 | tail -1)
  command -v "$QEMU_BIN/bin/qemu-system-x86_64" "$QEMU_BIN/bin/qemu-img" >/dev/null
  mark "qemu: ok $QEMU_BIN"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'QEMU_BIN=%s\n' "$QEMU_BIN" >> "$GITHUB_ENV"
  fi
}

stage_disk() {
  df -h / /nix | tee -a "$transcript"
  mark "disk: copying $image"
  cp --reflink=auto "$image" "$WORK/image.qcow2"
  chmod +w "$WORK/image.qcow2"
  qemu-img resize "$WORK/image.qcow2" 130G
  ls -l "$WORK/image.qcow2" >> "$transcript"
  mark "disk: ok size=$(du -h "$WORK/image.qcow2" | cut -f1)"
}

stage_boot() {
  if [ -n "${QEMU_BIN:-}" ]; then
    export PATH="$QEMU_BIN/bin:$PATH"
  fi
  command -v qemu-system-x86_64 qemu-img >/dev/null
  accel=(-accel tcg,thread=multi)
  test -e /dev/kvm && accel=(-accel kvm -cpu host)
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
    printf '%s' "$(fetch_token)" > "$WORK/share/id-token"
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
  mark "=== login-status ==="
  cat "$WORK/share/login-status" 2>/dev/null | tee -a "$transcript" || true
  mark "=== qemu.err ==="
  tail -40 "$WORK/qemu.err" 2>/dev/null | tee -a "$transcript" || true
  mark "=== qemu.log ==="
  tail -60 "$WORK/qemu.log" 2>/dev/null | tee -a "$transcript" || true
  if [ "$ok" = yes ]; then
    mark "boot: VM joined tailnet, keeping alive 10 minutes"
    sleep 600
  fi
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
  test "$ok" = yes
}

set -x
exec > >(tee "$transcript") 2>&1

case "$stage" in
  token) stage_token ;;
  qemu) stage_qemu ;;
  disk) stage_disk ;;
  boot) stage_boot ;;
  all) stage_token && stage_qemu && stage_disk && stage_boot ;;
  *) echo "unknown stage $stage" >&2; exit 2 ;;
esac