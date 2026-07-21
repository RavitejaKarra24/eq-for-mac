# Zero-fee distribution guide

EQ for Mac is distributed without Apple Developer Program membership. Tagged
releases are universal, ad-hoc-signed DMGs published by GitHub Actions. They are
not Developer ID-signed, notarized, stapled, or submitted to the App Store.

That keeps distribution free, but Gatekeeper will require users to approve the
app once in **System Settings → Privacy & Security → Open Anyway**. The public
website provides the illustrated user flow.

## What the release contains

Each `vX.Y.Z` tag produces:

- `EQ-for-Mac.dmg`, containing Apple Silicon and Intel executables;
- `EQ-for-Mac.dmg.sha256`, for download verification; and
- a GitHub Release that clearly discloses the ad-hoc signature and links to the
  installation guide.

The workflow then pins `Casks/eq-for-mac.rb` to the exact version and SHA-256 on
`main`. Homebrew installs the same artifact and does not suppress Gatekeeper.

No Apple certificate, Apple ID, team ID, app-specific password, or repository
secret is needed.

## Publish a release

Make sure `main` is clean, CI passes, and the version has not been released
before. The first public release defaults to `v1.0.0`.

```bash
git tag v1.0.0
git push origin v1.0.0
```

The release workflow:

1. validates the semantic version tag;
2. builds a release binary for `arm64` and `x86_64`;
3. ad-hoc signs the resource bundle and application;
4. verifies the code signature, architectures, plist, and mounted DMG;
5. publishes the DMG and checksum; and
6. commits the exact release version and checksum to the Homebrew Cask.

Do not replace an existing tagged binary. If a release is wrong, fix the issue
and publish the next patch version.

## Local packaging

Create the same kind of app and versioned DMG locally:

```bash
VERSION=1.0.0 BUILD_NUMBER=1 CODESIGN_IDENTITY=- scripts/package.sh
```

Artifacts are written to `dist/`. Verify them with:

```bash
codesign --verify --deep --strict --verbose=2 "dist/EQ for Mac.app"
lipo -verify_arch arm64 x86_64 "dist/EQ for Mac.app/Contents/MacOS/EQForMac"
cd dist && shasum -a 256 -c EQ-for-Mac-1.0.0.dmg.sha256
```

An ad-hoc signature is a valid local code signature, but it does not identify
the publisher to Apple and does not satisfy notarization.

## Gatekeeper support policy

The recommended user path is Apple’s per-app exception:

1. download from this repository and move the app to Applications;
2. attempt to open the app and dismiss the expected warning;
3. open **System Settings → Privacy & Security**;
4. click **Open Anyway**, authenticate, and confirm; and
5. grant **Screen & System Audio Recording**.

If the per-app button fails to appear, the advanced fallback is scoped to this
bundle only:

```bash
xattr -dr com.apple.quarantine "/Applications/EQ for Mac.app"
open "/Applications/EQ for Mac.app"
```

Never tell users to run `spctl --master-disable`, change global Gatekeeper
policy, or ignore an alert that says the app will damage the Mac or contains
malware. Managed Macs may prohibit exceptions.

## Homebrew notes

The repository is a custom tap because it is not named `homebrew-tap`:

```bash
brew tap ravitejakarra24/eq-for-mac https://github.com/RavitejaKarra24/eq-for-mac
brew install --cask eq-for-mac
```

Do not document `--no-quarantine`. Current Homebrew no longer exposes it as a
normal install option, and the custom Cask should preserve macOS security
behavior. Each release must have a concrete version and SHA-256; `:latest` and
`:no_check` are only the pre-release bootstrap state.

## Release checklist

- CI passes on the commit being tagged.
- The app reports the intended version and minimum macOS 14.2.
- The release contains both architectures and a valid ad-hoc signature.
- The checksum file validates the downloaded DMG.
- The GitHub release disclosure and installation-guide link are visible.
- The Homebrew Cask is automatically pinned after publishing.
- A fresh quarantined download completes the documented Open Anyway flow.
- The website download, checksum, screenshots, copy buttons, and dark mode work.
