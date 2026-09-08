#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: boot-and-join.sh <qcow2-image>}"
set -x

mkdir -p /tmp/share
printf '%s' "$TS_OAUTH_CLIENT_ID" > /tmp/share/client-id

fetch_token() {
  aud_enc=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$TS_AUDIENCE")
  curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$aud_enc" | jq -r .value
}

printf '%s' "$(fetch_token)" > /tmp/share/id-token

sudo apt-get update
sudo apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils

cp "$image" /tmp/image.qcow2
chmod +w /tmp/image.qcow2
qemu-img resize /tmp/image.qcow2 130G

accel=(-accel tcg,thread=multi)
test -e /dev/kvm && accel=(-accel kvm -cpu host)

qemu-system-x86_64 \
  "${accel[@]}" \
  -m 2048 \
  -smp 4 \
  -drive file=/tmp/image.qcow2,if=virtio,format=qcow2 \
  -nic user,model=virtio,hostfwd=tcp::2222-:22 \
  -virtfs local,path=/tmp/share,mount_tag=share,security_model=none \
  -display none -serial file:qemu.log > qemu.out 2> qemu.err &
qemu_pid=$!

vm_ready=no
ok=no
deadline=$((SECONDS + 1200))
while [ $SECONDS -lt $deadline ]; do
  printf '%s' "$(fetch_token)" > /tmp/share/id-token
  if grep -q VM-READY qemu.log 2>/dev/null; then
    vm_ready=yes
  fi
  if [ -f /tmp/share/login-ok ]; then
    ok=yes
    break
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "qemu exited early"
    break
  fi
  sleep 10
done
echo "vm_ready=$vm_ready login=$ok"
echo "=== login-status ==="
cat /tmp/share/login-status 2>/dev/null || true
echo "=== qemu.err ==="
tail -40 qemu.err 2>/dev/null || true
echo "=== qemu.log ==="
tail -60 qemu.log 2>/dev/null || true
if [ "$ok" = yes ]; then
  echo "VM joined tailnet, keeping it alive 10 minutes before shutdown"
  sleep 600
fi
kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
test "$ok" = yes