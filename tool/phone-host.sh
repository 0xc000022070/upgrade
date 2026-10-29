#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
phone-host.sh <address> [scenario]

Gives the debug build on the adb device in reach a working entry for a
fixture VM, with no form typed: checks that the VM answers at <address> with
the host key the repo declares, authorizes this machine's phone key in the
guest, and leaves a bundle the app applies at its next launch.

  address    where the phone reaches this machine, usually its Tailscale IP
  scenario   full (default) or a name from nix/host-vm/scenarios.nix

The phone key lives in $XDG_STATE_HOME/striked, never in the repo. adb picks
the device as it always does: ANDROID_SERIAL and ADB_SERVER_SOCKET are taken
from the caller.
EOF
}

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PKG=dev.luisnquin.striked
readonly HOST_PUB="$ROOT/nix/host-vm/fixtures/host_vm_host_key.pub"
readonly STATE="${XDG_STATE_HOME:-$HOME/.local/state}/striked"
readonly KEY="$STATE/phone_key"

die() {
  echo "phone-host: $*" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || {
  usage >&2
  exit 2
}
address=$1
scenario=${2:-full}

case $scenario in
  full) port=2222 name='STRIKED HOST VM' integrations='["herdr","agents"]' ;;
  bare) port=2223 name='SCENARIO BARE' integrations='[]' ;;
  herdr) port=2224 name='SCENARIO HERDR' integrations='["herdr"]' ;;
  engine) port=2225 name='SCENARIO ENGINE' integrations='["agents"]' ;;
  declared) port=2226 name='SCENARIO DECLARED' integrations='["agents"]' ;;
  *) die "no scenario named $scenario" ;;
esac
suffix=$([ "$scenario" = full ] || echo "-$scenario")

fingerprint() { ssh-keygen -lf "$1" | cut -d' ' -f2; }

expected=$(fingerprint "$HOST_PUB")
scanned=$(ssh-keyscan -T 10 -t ed25519 -p "$port" "$address" 2>/dev/null || true)
[ -n "$scanned" ] ||
  die "nothing answers ssh at $address:$port. A stale address, or the guest is down: just host-vm $scenario"
actual=$(fingerprint - <<<"$scanned")
[ "$actual" = "$expected" ] ||
  die "$address:$port presents $actual, not the declared $expected. Another sshd holds that address, or the guest predates the fixed key"

mkdir -p "$STATE"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C test-key -f "$KEY"
pub=$(cut -d' ' -f1-2 "$KEY.pub")

nix run "$ROOT#host-ssh$suffix" -- \
  "mkdir -p -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && { grep -qF '$pub' ~/.ssh/authorized_keys || echo '$pub test-key' >> ~/.ssh/authorized_keys; }"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bundle=$(jq -n \
  --arg keyPub "$(cat "$KEY.pub")" \
  --arg keyFp "$(fingerprint "$KEY.pub")" \
  --rawfile private "$KEY" \
  --arg hostId "fixture-host$suffix" \
  --arg name "$name" \
  --arg address "$address" \
  --argjson port "$port" \
  --arg hostFp "$expected" \
  --argjson integrations "$integrations" \
  --arg now "$now" \
  '{
    keys: [{
      id: "fixture-phone-key",
      name: "test-key",
      publicKey: $keyPub,
      fingerprint: $keyFp,
      createdAt: $now,
      privateKey: $private
    }],
    hosts: [{
      id: $hostId,
      name: $name,
      address: $address,
      port: $port,
      user: "dev",
      keyId: "fixture-phone-key",
      hostKey: { type: "ssh-ed25519", fingerprint: $hostFp, pinnedAt: $now },
      vncPassword: null,
      vncUsername: null,
      integrations: $integrations
    }],
    paths: []
  }')

# exec-in predates the shell protocol, so this holds on older adb too.
adb exec-in run-as "$PKG" sh -c 'umask 077; cat > files/seed-bundle.json' <<<"$bundle" ||
  die "adb could not write into $PKG. Is the debug build installed on the device adb picks?"
adb shell am force-stop "$PKG"
adb shell am start -W -n "$PKG/.MainActivity" >/dev/null
echo "phone-host: $name at $address:$port, host key $expected; the app applies it as it starts"
