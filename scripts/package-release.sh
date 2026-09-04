#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$repo_root/.build/release"
app_path="$repo_root/.build/BreakBar.app"
notary_archive="$release_dir/BreakBar-notarization.zip"
release_archive="$release_dir/BreakBar.zip"

: "${RELEASE_VERSION:?Set RELEASE_VERSION to the app version being packaged.}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to the Developer ID Application identity.}"
: "${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH to the App Store Connect API private key.}"
: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to the App Store Connect API key ID.}"
: "${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID to the App Store Connect issuer ID.}"

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
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
shasum -a 256 "$release_archive" > "$release_archive.sha256"

echo "Packaged $release_archive"
