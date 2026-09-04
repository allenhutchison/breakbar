# BreakBar release guidelines

BreakBar is distributed outside the Mac App Store as a free, Developer ID-signed and Apple-notarized app.

## One-time GitHub configuration

Create a protected `release` environment and add these repository or environment secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`: Base64-encoded `.p12` containing the Developer ID Application certificate and private key.
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`: Password used when exporting the `.p12`.
- `APPLE_NOTARY_KEY_BASE64`: Base64-encoded App Store Connect API private key (`.p8`) with access to notarization.
- `APPLE_NOTARY_KEY_ID`: App Store Connect API key ID.
- `APPLE_NOTARY_ISSUER_ID`: App Store Connect issuer ID.

Restrict the `release` environment to the `main` branch and require approval before deployment. Never place signing material in the repository, workflow artifacts, release notes, or logs.

In **Settings → Pages**, set the publishing source to **GitHub Actions**. The Pages workflow publishes the static files in `docs/` after changes reach `main`.

## Version and notes

- Follow semantic versioning. Run `scripts/bump-version.sh patch|minor|major`; do not edit the bundle versions by hand.
- Update `RELEASE_NOTES.md` from the complete change range since the previous GitHub release.
- The workflow input must exactly match `CFBundleShortVersionString` in `Support/Info.plist`.
- The public tag and release title use `v<version>` and `BreakBar <version>` respectively.

## Release gate

Before dispatching the `Release` workflow from `main`:

1. Confirm CI passed for the release commit.
2. Run `make test` and `make build` locally.
3. Build and launch the release configuration locally, then verify clock in/out, the menu-bar countdown, Settings, calendar status, and Today’s history.
4. Review `RELEASE_NOTES.md` and confirm the version with the maintainer.

The workflow must finish signing, notarization, stapling, Gatekeeper assessment, and checksum generation before it creates the GitHub release. A failure must leave no unsigned public artifact or partially published release.
