# Release Checklist — justStats

Manual, by design (TECHSPEC §6). No release automation in CI. Every release is
cut by hand following the steps below. justStats is **unsigned** (no Apple
Developer Program membership); users approve it via Gatekeeper right-click →
Open on first launch (see README).

Distribution model:
- Artifact: a `.zip` of `justStats.app`, attached to a GitHub Release.
- Update feed: `appcast.xml` at the repo root, served over HTTPS from
  `https://raw.githubusercontent.com/zanybaka/justStats/main/appcast.xml`
  (this is `SUFeedURL` in `justStats/Info.plist`).
- Signatures: Sparkle EdDSA. The **public** key lives in `Info.plist`
  (`SUPublicEDKey`). The **private** key is NEVER in this repo or its history.

---

## Prerequisites (one-time)

1. **Sparkle tools.** After `xcodebuild` resolves the Sparkle SPM package, the
   command-line tools live inside the build products / DerivedData under
   `artifacts/sparkle/Sparkle/bin/` (`generate_keys`, `sign_update`). You can
   also download them from a Sparkle release. Confirm both are runnable:
   ```sh
   ./sign_update --help
   ```

2. **EdDSA key pair (generated once by UPD-001, must already exist).**
   The pair was created with:
   ```sh
   ./generate_keys
   ```
   - The **public** key is in `justStats/Info.plist` under `SUPublicEDKey`.
     If it still reads `REPLACE_WITH_REAL_SPARKLE_EDDSA_PUBLIC_KEY`, the key
     pair has not been generated yet — do that first, out of band.
   - The **private** key is stored in the **macOS login keychain** (Sparkle's
     default; item name `https://sparkle-project.org`) and/or an offline backup.
     **NEVER** paste it into a file in this repo, a commit, an issue, or CI.
   - Verify the public key in `Info.plist` matches the keychain private key:
     ```sh
     ./generate_keys -p   # prints the public key for the stored private key
     ```
     The printed value must equal `SUPublicEDKey`.

3. `gh` CLI authenticated against `github.com/zanybaka/justStats`
   (`gh auth status`).

---

## Release steps

Assume the new version is `X.Y.Z` (marketing) with build number `B`
(integer, monotonically increasing — this is what Sparkle compares).

### 1. Bump the version

Set both in the Xcode target build settings (source of truth — `Info.plist`
references them as `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`):
- `MARKETING_VERSION` → `X.Y.Z`  (→ `CFBundleShortVersionString`)
- `CURRENT_PROJECT_VERSION` → `B`  (→ `CFBundleVersion`)

`B` MUST be strictly greater than the previous release's build number, or
Sparkle will not offer the update.

Commit the bump (do not tag yet):
```sh
git commit -am "Release vX.Y.Z: bump version"
```

### 2. Build a Release `.app`

Archive/build in Release configuration and locate the built `justStats.app`.
```sh
xcodebuild -project justStats.xcodeproj -scheme justStats \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/release \
  clean build
```
The app lands at
`build/release/Build/Products/Release/justStats.app`.
(If you prefer, use Xcode → Product → Archive → Distribute App → Copy App.)

### 3. Zip the app with `ditto`

Use `ditto` (preserves the bundle correctly; `zip -r` can mangle symlinks /
resource forks):
```sh
cd build/release/Build/Products/Release
ditto -c -k --sequesterRsrc --keepParent justStats.app justStats-X.Y.Z.zip
```
This produces `justStats-X.Y.Z.zip`.

### 4. Generate the EdDSA signature

Run Sparkle's `sign_update` on the zip. It signs with the private key from the
keychain — it does NOT reveal the private key:
```sh
./sign_update justStats-X.Y.Z.zip
```
Output looks like:
```
sparkle:edSignature="a1b2c3…==" length="1234567"
```
Copy BOTH values. `length` is the exact zip byte size; confirm with
`stat -f%z justStats-X.Y.Z.zip` if you like.

### 5. Create the GitHub Release with the zip asset

Tag `vX.Y.Z` and upload the zip:
```sh
gh release create vX.Y.Z justStats-X.Y.Z.zip \
  --repo zanybaka/justStats \
  --title "vX.Y.Z" \
  --notes "Release notes here."
```
Note the asset download URL — it will be:
```
https://github.com/zanybaka/justStats/releases/download/vX.Y.Z/justStats-X.Y.Z.zip
```

### 6. Add the appcast `<item>`

Edit `appcast.xml` at the repo root. Copy the commented template `<item>`
block, uncomment it, put it **first** in `<channel>` (newest release first),
and fill in every placeholder:
- `<sparkle:version>` → `B`
- `<sparkle:shortVersionString>` → `X.Y.Z`
- `<sparkle:minimumSystemVersion>` → `15.0`
- `enclosure url` → the GitHub Release asset URL from step 5 (must be HTTPS)
- `enclosure sparkle:edSignature` → the signature from step 4
- `enclosure length` → the length from step 4
- `<pubDate>` → RFC 822 date (e.g. `date -R` output, or
  `Mon, 01 Jan 2026 12:00:00 +0000`)
- `<title>` / `<description>` → human-readable release notes

Validate it parses:
```sh
xmllint --noout appcast.xml
```

### 7. Commit and push the appcast

```sh
git commit -am "Release vX.Y.Z: appcast entry"
git push origin main
```
Once pushed, `raw.githubusercontent.com/.../main/appcast.xml` serves the new
feed and existing installs will detect the update on their next check.

### 8. Verify

- In a running older build, trigger **Check for Updates** (Settings) → the
  update should be offered, download, verify the EdDSA signature, and install.
- Because the app is unsigned, first-launch Gatekeeper behavior on the updated
  copy is the open risk tracked by **UPD-003** — validate on a real machine
  before announcing a public release.

---

## Security reminders (do not skip)

- **Never** commit, log, or share the EdDSA private key. Only `SUPublicEDKey`
  (public) belongs in the repo.
- The appcast `url`/`SUFeedURL` MUST be HTTPS.
- Do not add any `SUSkipSignatureValidation`-style bypass — signature
  verification stays on (checked by UPD-004).
- `sign_update` output contains a signature, not the key — it is safe to paste
  into `appcast.xml`.
