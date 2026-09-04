#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 patch|minor|major" >&2
    exit 2
fi

level="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plist="$repo_root/Support/Info.plist"
current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"

IFS=. read -r major minor patch <<< "$current_version"
if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]]; then
    echo "Expected a semantic version, found $current_version." >&2
    exit 1
fi

case "$level" in
    patch)
        patch=$((patch + 1))
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    *)
        echo "Unknown version level: $level" >&2
        exit 2
        ;;
esac

new_version="$major.$minor.$patch"
new_build=$((current_build + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new_version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $new_build" "$plist"

echo "Bumped BreakBar from $current_version ($current_build) to $new_version ($new_build)."
