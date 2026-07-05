# Sparkle integration

Auto-update via **Sparkle 2.x**, wired behind a small `SoftwareUpdating` seam so the rest of
the app never depends on Sparkle directly.

- `SoftwareUpdating.swift` — the protocol seam (`checkForUpdates()`, `automaticallyChecksForUpdates`).
- `SparkleUpdaterController.swift` — the real updater, wrapping `SPUStandardUpdaterController`.
  The whole file is behind `#if canImport(Sparkle)`, so it compiles only when the Sparkle
  package is linked.
- `NoopSoftwareUpdater.swift` — the fallback used when Sparkle is **not** linked. It logs
  "update check not available in this build" and round-trips the automatic-check flag through
  `UserDefaults` so the toggle still works.
- `SoftwareUpdaterFactory.swift` — picks `SparkleUpdaterController` when `canImport(Sparkle)`
  holds, else `NoopSoftwareUpdater`. This is the only place the choice is made — no call-site
  edits are ever needed to switch.

The Settings window exposes a **"Check for Updates…"** button and an **"Automatically check for
updates"** toggle, both routed through `SettingsViewModel` → the seam.

## Current state: Sparkle is linked (done in REL-001, 2026-07-05)

The Sparkle SPM package **is** wired into `justStats.xcodeproj`:

- `project.pbxproj` carries the `XCRemoteSwiftPackageReference`; `Package.resolved` pins Sparkle
  **2.9.4**; `Sparkle.framework` is linked **and embedded** (Embed & Sign) into the app bundle
  (`Contents/Frameworks/Sparkle.framework` — verified in the built `.app`, so it won't crash at
  launch).
- Because Sparkle is linked, `canImport(Sparkle)` is **true**, so `SoftwareUpdaterFactory`
  returns the real `SparkleUpdaterController` automatically.
- `Info.plist` holds the **real** public key (not the old placeholder):
  - `SUFeedURL` = `https://raw.githubusercontent.com/zanybaka/justStats/main/appcast.xml`
  - `SUPublicEDKey` = the base64 public key matching the private signing key in the keychain.
  - `SUEnableInstallerLauncherService` = `true` (unsandboxed installer launcher).

Auto-update is therefore active. It will (safely) refuse to install anything not signed by the
matching private key — the correct default.

## How the signing key was generated

Done once, on 2026-07-05, with Sparkle's `generate_keys` tool (it ships in the resolved SPM
package under `…/SourcePackages/artifacts/sparkle/Sparkle/bin/`, and also in the release tarball
`Sparkle-2.9.x.tar.xz`). Locate it any time with:

```sh
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*sparkle*' | head -1
```

Running it with no arguments generated a keypair, stored the **private** key in the login
**Keychain** (item: *"Private key for signing Sparkle updates"*, account `ed25519`), and printed
the **public** key, which was pasted into `Info.plist`'s `SUPublicEDKey`:

```sh
./generate_keys          # generate + store private key in keychain, print public key
./generate_keys -p       # just print the existing public key (for automation)
```

The private key is **only** in the keychain — never in the repo. Confirm nothing leaked:

```sh
git log -p | grep -i "BEGIN PRIVATE KEY\|SUPrivateEDKey" || echo "clean"
```

## Signing-key management — back it up, and how to restore/import it

The private signing key is **irreplaceable**: every installed copy embeds the public key and will
only accept updates signed by the matching private key. **Lose the private key and you can no
longer ship auto-updates to existing installs** — they'd have to manually reinstall a build
carrying a new public key. So back it up.

**Back up (export from the keychain to a file):**

```sh
./generate_keys -x ~/sparkle_private_key.txt   # keychain may prompt — allow it
```

Then store the file's contents in a password manager / secure vault (e.g. Bitwarden, Passwords)
as "justStats Sparkle signing key", and **delete the file** — its contents equal the key:

```sh
rm ~/sparkle_private_key.txt
```

Never commit this file or leave it on disk.

**Restore / import on another machine or CI** (e.g. to sign a release from a different Mac):

```sh
./generate_keys -f sparkle_private_key.txt     # import into that machine's keychain
```

Note: if a *different* "Private key for signing Sparkle updates" item already exists in that
keychain, remove it in Keychain Access first, or the import won't take.

**Signing releases:** on any machine whose keychain holds the private key, `sign_update` finds it
automatically — no key argument needed. See `docs/release-checklist.md` (REL-005).

## Re-establishing the package reference (only if it's ever lost)

If `project.pbxproj` loses the Sparkle package reference, re-add it via Xcode (hand-editing the
hand-written pbxproj is fragile — an earlier headless attempt produced undefined symbols and a
malformed embed phase, and was rolled back):

1. **File → Add Package Dependencies…**, enter `https://github.com/sparkle-project/Sparkle`,
   **Up to Next Major Version** from `2.6.0`, add the **Sparkle** product to the `justStats` target.
2. In the target's **General → Frameworks, Libraries, and Embedded Content**, confirm
   `Sparkle.framework` is set to **Embed & Sign** (a linked-but-not-embedded dynamic framework
   crashes the packaged app at launch).
3. Rebuild — `canImport(Sparkle)` becomes true and the factory uses the real updater
   automatically. The public key in `Info.plist` is unchanged; the private key is still in the
   keychain, so no key regeneration is needed.

## Falling back to Noop (path B), if ever needed

To build without Sparkle (e.g. a no-network CI): remove the package reference (the
`XCRemoteSwiftPackageReference`, the target's `packageProductDependencies` / Frameworks
`PBXBuildFile` / the Embed Frameworks phase entry, and the project's `packageReferences`) and
delete `Package.resolved`. `canImport(Sparkle)` goes false and `SoftwareUpdaterFactory` returns
`NoopSoftwareUpdater` — the app builds and runs, "Check for Updates…" just logs, no source edits.
