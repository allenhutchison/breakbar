#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 SOURCE_PNG OUTPUT_ICNS" >&2
    exit 1
fi

source_png="$1"
output_icns="$2"

if [[ ! -f "$source_png" ]]; then
    echo "App icon source not found: $source_png" >&2
    exit 1
fi

icon_work_dir="$(mktemp -d)"
iconset_dir="$icon_work_dir/AppIcon.iconset"
cleanup() {
    rm -rf "$icon_work_dir"
}
trap cleanup EXIT

mkdir -p "$iconset_dir" "$(dirname "$output_icns")"

create_icon() {
    local pixels="$1"
    local filename="$2"
    sips -z "$pixels" "$pixels" "$source_png" --out "$iconset_dir/$filename" >/dev/null
}

create_icon 16 icon_16x16.png
create_icon 32 icon_16x16@2x.png
create_icon 32 icon_32x32.png
create_icon 64 icon_32x32@2x.png
create_icon 128 icon_128x128.png
create_icon 256 icon_128x128@2x.png
create_icon 256 icon_256x256.png
create_icon 512 icon_256x256@2x.png
create_icon 512 icon_512x512.png
create_icon 1024 icon_512x512@2x.png

iconutil --convert icns --output "$output_icns" "$iconset_dir"
