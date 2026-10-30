#!/usr/bin/env bash
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <dir> [scenario]" >&2; exit 2; }
dir=$1
scenario=${2:-}
app=".#host-ssh${scenario:+-$scenario}"
name=$(basename "$(realpath "$dir")")
case "$name" in /|.|..|'') echo "plugin-sync: $dir has no usable name" >&2; exit 2 ;; esac
remote="Projects/plugins/$name"
q=$(printf %q "$remote")
tar -C "$dir" --exclude=.upgrade -cf - . | nix run "$app" -- \
    "set -e; rm -rf $q.sync $q.old; mkdir -p $q.sync/.upgrade; tar -C $q.sync -xf -; \
    if [ -d $q/.upgrade ]; then rm -rf $q.sync/.upgrade; mv $q/.upgrade $q.sync/; fi; \
    touch $q.sync/.upgrade/synced; if [ -e $q ]; then mv $q $q.old; fi; mv $q.sync $q"
mkdir -p "$dir/.upgrade/preview"
if nix run "$app" -- "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
    [ $q/.upgrade/preview/latest.json -nt $q/.upgrade/synced ] && break; sleep 0.5; done; \
    cat $q/.upgrade/preview/latest.json" > "$dir/.upgrade/preview/latest.json.part" 2>/dev/null; then
    mv "$dir/.upgrade/preview/latest.json.part" "$dir/.upgrade/preview/latest.json"
else
    rm -f "$dir/.upgrade/preview/latest.json.part"
fi
echo "synced ~/$remote"
