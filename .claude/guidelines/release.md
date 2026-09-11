# BreakBar release guidelines

BreakBar is distributed outside the Mac App Store as a free, Developer ID-signed and Apple-notarized app.

## One-time GitHub configuration

Create a protected `release` environment and add these repository or environment secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`: Base64-encoded `.p12` containing the Developer ID Application certificate and private key.
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`: Password used when exporting the `.p12`.
- `APPLE_NOTARY_KEY_BASE64`: Base64-encoded App Store Connect API private key (`.p8`) with access to notarization.
- `APPLE_NOTARY_KEY_ID`: App Store Connect API key ID.
- `APPLE_NOTARY_ISSUER_ID`: App Store Connect issuer ID.
- `SPARKLE_EDDSA_PRIVATE_KEY`: Private key exported from Sparkle's `generate_keys` tool for signing update archives. Keep the matching public key in `Support/Info.plist` and preserve the private key in the login keychain and this protected secret.

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
3. Build and launch the release configuration locally, then verify clock-in/clock-out, the menu-bar countdown, Settings, calendar status, and Today’s history.
4. Review `RELEASE_NOTES.md` and confirm the version with the maintainer.

The workflow must finish signing, notarization, stapling, Gatekeeper assessment, checksum generation, and EdDSA appcast generation before it creates the GitHub release. A failure must leave no unsigned public artifact or partially published release. The published release must contain `BreakBar.zip`, `BreakBar.zip.sha256`, and `appcast.xml`; the app reads the appcast through GitHub's latest-release asset URL.

BreakBar verifies an update's EdDSA signature before extracting its archive. Sparkle cannot transition EdDSA keys through the normal ZIP channel while pre-extraction verification is enabled.

### Emergency EdDSA key rotation

Use this manual path only if the current EdDSA private key is unavailable or must be replaced:

1. Generate the replacement key, put its public key in `Support/Info.plist`, and update the protected `SPARKLE_EDDSA_PRIVATE_KEY` secret. Keep the same Developer ID Application identity for this transition release; do not rotate the Apple signing identity and EdDSA key together.
2. Build, Developer ID-sign, notarize, staple, and validate the transition app using the normal release gates, but do not dispatch the `Release` workflow because it always publishes a ZIP.
3. Put the transition app in a DMG, code-sign the DMG with that same Developer ID Application identity, submit the DMG to Apple for notarization, staple it, and validate its code signature, notarization ticket, and Gatekeeper assessment.
4. Put only the DMG and its release notes in a clean appcast-input directory. Run Sparkle's `generate_appcast` with the replacement private key and the GitHub tag download URL. Confirm the resulting enclosure references the DMG, not a ZIP.
5. Manually create a draft GitHub release containing the DMG, its SHA-256 checksum, and the generated `appcast.xml`. Inspect and download the draft assets, repeat the signature, stapler, Gatekeeper, checksum, and entitlement checks, then publish it as the latest release.
6. Confirm an installed build using the old public key can update through the public appcast to the transition release. Later releases may return to the normal ZIP workflow using the replacement key.

Never publish a ZIP signed only with the replacement key: installed versions using the old public key will reject it before extraction.
