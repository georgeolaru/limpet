# Releasing the signed menu-bar app (Cask)

The Homebrew **formula** (daemon + CLI) needs nothing special — it builds from the
source tarball. The **cask** (`brew install --cask`) ships the prebuilt
`Limpet.app`, which Homebrew requires to be **code-signed + notarized**. This is
how you produce that artifact. (The menu-bar app also still installs unsigned via
`install.sh`, which compiles locally and sidesteps Gatekeeper — that path is
unaffected.)

## One-time setup (per machine)

1. **Developer ID Application certificate** in your login keychain
   (Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com →
   Certificates). Check it's there:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **Notary credentials** stored so `notarytool` runs unattended. Use an
   app-specific password (appleid.apple.com → Sign-In and Security) or an App
   Store Connect API key:
   ```bash
   xcrun notarytool store-credentials limpet-notary \
     --apple-id "you@example.com" --team-id "TEAMID" \
     --password "abcd-efgh-ijkl-mnop"
   ```

## Cut a signed release

```bash
# 1. Tag + release the source (see homebrew-tap/RELEASING.md) so v<version> exists.
# 2. Build, sign, notarize, staple, and package the app:
./release-app.sh 1.1.0
#    -> dist/Limpet-macos-universal-1.1.0.zip  (+ prints its sha256)

# 3. Attach the zip to the GitHub release:
gh release upload v1.1.0 dist/Limpet-macos-universal-1.1.0.zip
```

That's it. The tap's **auto-bump** (`homebrew-tap/.github/workflows/update-formula.yml`)
sees the new `Limpet-macos-universal-1.1.0.zip` asset and fills the cask's
`version` + `sha256` automatically (manual run for instant, or within a day on
the schedule). Then `brew install --cask georgeolaru/tap/limpet` works.

## Notes

- `release-app.sh` builds a **universal** binary (arm64 + x86_64), signs with a
  hardened runtime + secure timestamp (both required by notarization), then
  staples the ticket so first launch works offline.
- Override the identity/profile via env: `SIGN_IDENTITY=…`, `NOTARY_PROFILE=…`.
- **CI option (not yet wired):** the same steps can run in GitHub Actions on
  release, but that means storing the Developer ID cert (base64 `.p12`) + notary
  secrets in the repo. Ask if you want that — local signing keeps the cert on
  your Mac and needs no secrets.
