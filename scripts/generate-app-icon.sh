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
asset_catalog="$icon_work_dir/Assets.xcassets"
app_icon_set="$asset_catalog/AppIcon.appiconset"
cleanup() {
    rm -rf "$icon_work_dir"
}
trap cleanup EXIT

mkdir -p "$app_icon_set" "$(dirname "$output_icns")"
# Supply every macOS icon size so actool's legacy .icns renditions are not cropped.
create_icon() {
    local pixels="$1"
    local filename="$2"
    sips -z "$pixels" "$pixels" "$source_png" --out "$app_icon_set/$filename" >/dev/null
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
cp "$source_png" "$app_icon_set/icon_512x512@2x.png"

cat > "$app_icon_set/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

xcrun actool \
    --compile "$(dirname "$output_icns")" \
    --output-partial-info-plist "$icon_work_dir/IconInfo.plist" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    "$asset_catalog" >/dev/null

compiled_icns="$(dirname "$output_icns")/AppIcon.icns"
if [[ "$compiled_icns" != "$output_icns" ]]; then
    mv "$compiled_icns" "$output_icns"
fi
