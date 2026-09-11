#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$repo_root/.build/release"
app_path="$repo_root/.build/BreakBar.app"
notary_archive="$release_dir/BreakBar-notarization.zip"
release_archive="$release_dir/BreakBar.zip"
verification_dir="$release_dir/verification"
appcast_input_dir="$release_dir/appcast-input"
appcast_path="$release_dir/appcast.xml"
sparkle_generate_appcast="$repo_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

: "${RELEASE_VERSION:?Set RELEASE_VERSION to the app version being packaged.}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to the Developer ID Application identity.}"
: "${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH to the App Store Connect API private key.}"
: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to the App Store Connect API key ID.}"
: "${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID to the App Store Connect issuer ID.}"
: "${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY to the exported Sparkle EdDSA private key.}"

plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Support/Info.plist")"
if [[ "$plist_version" != "$RELEASE_VERSION" ]]; then
    echo "Release version $RELEASE_VERSION does not match Info.plist version $plist_version." >&2
    exit 1
fi

rm -rf "$release_dir"
mkdir -p "$release_dir"

make -C "$repo_root" release-bundle SIGNING_IDENTITY="$SIGNING_IDENTITY"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_archive"
xcrun notarytool submit "$notary_archive" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_archive"
cleanup_verification_dir() {
    local exit_status="$1"
    rm -rf "$verification_dir" || true
    trap - EXIT
    exit "$exit_status"
}
trap 'cleanup_verification_dir "$?"' EXIT
mkdir -p "$verification_dir"
ditto -x -k "$release_archive" "$verification_dir"
verified_app="$verification_dir/BreakBar.app"
codesign --verify --deep --strict --verbose=2 "$verified_app"
xcrun stapler validate "$verified_app"
spctl --assess --type execute --verbose=2 "$verified_app"
(
    cd "$release_dir"
    shasum -a 256 "BreakBar.zip" > "BreakBar.zip.sha256"
)

mkdir -p "$appcast_input_dir"
cp "$release_archive" "$appcast_input_dir/BreakBar.zip"
cp "$repo_root/RELEASE_NOTES.md" "$appcast_input_dir/BreakBar.md"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/allenhutchison/breakbar/releases/download/v$RELEASE_VERSION/" \
    --link "https://github.com/allenhutchison/breakbar/releases/tag/v$RELEASE_VERSION" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --maximum-versions 1 \
    -o "$appcast_path" \
    "$appcast_input_dir"
rm -rf "$appcast_input_dir"

echo "Packaged $release_archive"
echo "Generated $appcast_path"
