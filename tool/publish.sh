#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
repo=$root/publish

rev=$(git -C "$root" rev-parse HEAD)
read -r version code STRIKED_BUILD <<<"$("$root/tool/deploy.sh" stamp "$rev")"
apk=$("$root/tool/deploy.sh" build "$rev")

# '-' and not '+': a literal + in a url path reads as a space to enough clients.
name="striked-$version-$code.apk"
mkdir -p "$repo"
rm -f "$repo"/striked-*.apk "$repo/latest.apk"
install -m644 "$apk" "$repo/$name"
ln "$repo/$name" "$repo/latest.apk"

sum=$(sha256sum "$repo/$name" | cut -d' ' -f1)
size=$(du -h "$repo/$name" | cut -f1)
when=$(date -Is)

{
  printf '<!doctype html><meta charset=utf-8>'
  printf '<meta name=viewport content="width=device-width,initial-scale=1">'
  printf '<title>striked</title>'
  printf '<style>body{background:#111;color:#eee;font:14px/1.6 ui-monospace,monospace;margin:0;padding:2rem 1.25rem;max-width:34rem}'
  printf 'a.get{display:block;padding:1.1rem;margin:1.5rem 0;background:#eee;color:#111;text-align:center;text-decoration:none;letter-spacing:.08em}'
  printf 'dt{color:#777;float:left;width:5.5rem;clear:left}dd{margin:0 0 .35rem 5.5rem;word-break:break-all}</style>'
  printf '<h1>STRIKED</h1>'
  printf '<a class="get" href="%s">INSTALL %s (%s)</a>' "$name" "$version" "$code"
  printf '<dl>'
  printf '<dt>build</dt><dd>%s</dd>' "$STRIKED_BUILD"
  printf '<dt>size</dt><dd>%s</dd>' "$size"
  printf '<dt>built</dt><dd>%s</dd>' "$when"
  printf '<dt>sha256</dt><dd>%s</dd>' "$sum"
  printf '</dl>'
  printf '<p style="color:#777">SYS must read v%s (%s) %s once it lands.</p>' "$version" "$code" "$STRIKED_BUILD"
} >"$repo/index.html"

echo "publish: $name ($STRIKED_BUILD) -> $repo"
