#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PINS="$ROOT/nix/proot-android.json"
readonly POOL=https://packages.termux.dev/apt/termux-main/pool/main
readonly TAG=proot-android-debs

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" --latest=false --title "proot-android debs" --notes \
    "Termux's aarch64 debs behind nix/proot-android.nix, kept here because Termux drops superseded builds. Sources: https://github.com/termux/termux-packages (packages/proot, packages/libtalloc, packages/libandroid-shmem)."
fi
mirrored=$(gh release view "$TAG" --json assets -q '.assets[].name')

pins=$(cat "$PINS")
for name in $(jq -r 'keys[]' "$PINS"); do
  pool=$(jq -r --arg n "$name" '.[$n].pool' "$PINS")
  pinned=$(jq -r --arg n "$name" '.[$n].version' "$PINS")
  version=$(curl -fsS "$POOL/$pool/" | grep -o "href=\"${name}_[^\"]*_aarch64\.deb\"" |
    sed "s/^href=\"${name}_//; s/_aarch64\.deb\"\$//" | sort -V | tail -1)
  [ -n "$version" ] || { echo "proot-bump: no aarch64 deb for $name in $POOL/$pool" >&2; exit 1; }
  file="${name}_${version}_aarch64.deb"
  curl -fsSL "$POOL/$pool/$file" -o "$tmp/$file"
  sha256=$(sha256sum "$tmp/$file" | cut -d' ' -f1)
  if [ "$version" = "$pinned" ] && [ "$sha256" != "$(jq -r --arg n "$name" '.[$n].sha256' "$PINS")" ]; then
    echo "proot-bump: Termux rebuilt $file under the same name; refusing to repin it" >&2
    exit 1
  fi
  if grep -qxF "$file" <<<"$mirrored"; then
    echo "$file already mirrored"
  else
    gh release upload "$TAG" "$tmp/$file"
    echo "$file mirrored"
  fi
  pins=$(jq --arg n "$name" --arg v "$version" --arg h "$sha256" '.[$n].version = $v | .[$n].sha256 = $h' <<<"$pins")
  [ "$version" = "$pinned" ] || echo "$name $pinned -> $version"
done
printf '%s\n' "$pins" >"$PINS"
