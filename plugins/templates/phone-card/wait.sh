#!/bin/sh
# The phone reads the ask before the files and echoes it, so a result carrying
# this ask covers every edit made before the script started.
cd "$(dirname "$0")/.." || exit 2
out=.upgrade/preview/latest.json
ask="$$-$(date +%s)"
mkdir -p .upgrade
printf '%s\n' "$ask" > .upgrade/ask.part && mv -f .upgrade/ask.part .upgrade/ask
i=0
while [ "$i" -lt 60 ]; do
    i=$((i + 1))
    if [ -f "$out" ] && grep -qF "\"ask\": \"$ask\"" "$out"; then
        cat "$out"
        grep -q '^  "ok": true,$' "$out"
        exit $?
    fi
    sleep 1
done
echo 'no phone check for these files: open TOOLS > DEVELOP PLUGIN on this folder' >&2
exit 3
