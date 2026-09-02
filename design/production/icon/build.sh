#!/usr/bin/env bash
# usage: build.sh <scale units/native px> <cx> <cy>
set -e
T=$(dirname "$0")/../../explorations/branding/user-ref-trace
S=$1; CX=${2:-599}; CY=${3:-589}
TX=$(awk -v s=$S -v c=$CX 'BEGIN{printf "%.4f", 54 - c*s}')
TY=$(awk -v s=$S -v c=$CY 'BEGIN{printf "%.4f", 54 - c*s}')
grp() { awk '/^<g /,/^<\/g>/' "$1" | sed "s/fill=\"#000000\"/fill=\"$2\"/"; }
PATCH='<path d="M648,440 L724,477 L710,485 L648,462 Z"'
mk() { # $1 out  $2 head fill  $3 lime fill
cat > "$1" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">
<g transform="translate($TX,$TY) scale($S)">
$(grp "$T/head-white.svg" "$2")
$PATCH fill="$2"/>
$(grp "$T/head-lime.svg" "$3")
</g>
</svg>
SVG
}
mk ic_launcher_foreground.svg '#E6E6E6' '#B7FF2A'
mk ic_launcher_monochrome.svg '#FFFFFF' '#FFFFFF'
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108"><rect width="108" height="108" fill="#0A0A0A"/></svg>\n' > ic_launcher_background.svg
resvg -w 1080 -h 1080 ic_launcher_foreground.svg fg-1080.png
magick fg-1080.png -alpha extract -threshold 50% \( +clone -fill white -colorize 100 -fill black -draw 'circle 540,540 540,210' \) -compose multiply -composite -format "outside r33: %[fx:mean*w*h] px\n" info:
magick fg-1080.png -alpha extract -threshold 50% -format "all bbox %@ (units: /10)\n" info:
