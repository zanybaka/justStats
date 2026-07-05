# Gatekeeper × Sparkle Spike — Harness & Procedure (UPD-003)

> **STATUS: EXECUTED 2026-07-05 (REL-002) — VERDICT: GO.**
> Ran on macOS 15.7.5, Apple Silicon (arm64), Gatekeeper enabled. The
> Sparkle-delivered update installed and relaunched to 0.0.2 **silently, with
> no Gatekeeper re-block** — Sparkle strips the `com.apple.quarantine` xattr on
> the replacement bundle (only a benign `com.apple.provenance` remained). Full
> verdict + evidence are recorded in TECHSPEC §6.
>
> **One requirement this run uncovered:** the app must be moved to `/Applications`
> via a **Finder drag**. A quarantined app run from its copied/extracted location
> is App-Translocated and Sparkle refuses to update it ("can't be updated if it's
> running from the location it was downloaded to"). This is now in the README
> install steps. The procedure below remains the reproducible rig for re-running.

---

## 0. What question this answers

**Does macOS Gatekeeper re-block (or re-prompt for) a Sparkle-delivered
update to an unsigned/ad-hoc justStats.app that the user already approved
once via right-click → Open?**

Two plausible outcomes, and this is exactly what we're measuring:

- **PASS** — the update relaunches silently. Gatekeeper remembers the
  user's approval of the app identity and does not re-prompt. Sparkle-based
  public releases are **GO**.
- **FAIL** — macOS shows a fresh "cannot verify the developer" block (not
  just a passive warning), or the updated app refuses to launch until the
  user manually approves it again. Sparkle-based updates are **NO-GO** for a
  silent experience; we fall back to the documented **manual-download**
  messaging (see §7).

The mechanism under test is the **quarantine flag**
(`com.apple.quarantine`) and how Sparkle's installer strips (or fails to
strip) it on the replacement bundle. The observable proof is
`xattr -p com.apple.quarantine` on the updated bundle (see §5).

---

## 1. Why this can't be automated

- Gatekeeper's first-launch decision for an unsigned app is a GUI dialog
  requiring a human right-click → **Open** (or **Open Anyway** in System
  Settings → Privacy & Security). There is no supported non-interactive
  approval path for the "unidentified developer" flow.
- The result depends on the machine's real Gatekeeper state
  (`spctl --status`), the login user's launch-services database, and the
  real quarantine bit — none of which a build server reproduces.
- Therefore: **build two real versions, install v1, approve it by hand,
  publish v2 to a local test appcast, trigger the real Sparkle upgrade, and
  watch what macOS does.** Everything below is written so a person can do
  that start-to-finish and reach a defensible GO / NO-GO.

---

## 2. Prerequisites

- Apple Silicon Mac, macOS 15.0+ (matches the app's `LSMinimumSystemVersion`).
- Xcode 26.3 (or the toolchain the repo builds with).
- Gatekeeper in its **default** state (do NOT run the spike with Gatekeeper
  disabled — that would mask the very block we're testing):
  ```sh
  spctl --status          # expect: "assessments enabled"
  ```
  If it says "assessments disabled", re-enable before testing:
  ```sh
  sudo spctl --master-enable
  ```
- **Sparkle must be linked into the build** for the update trigger to work
  (`canImport(Sparkle)` true → `SparkleUpdaterController` active). As of
  this writing the Sparkle SPM package is **not** yet in
  `justStats.xcodeproj` (see `justStats/Modules/Updates/README-sparkle-integration.md`
  → "Current integration state" vs. reality: `grep -ci sparkle
  justStats.xcodeproj/project.pbxproj` returns 0). Add the package first
  (UPD-001 path A) — otherwise the app runs `NoopSoftwareUpdater`, the
  "Check for Updates…" button only logs, and there is nothing to trigger.
- **Sparkle command-line tools** `generate_keys` and `sign_update`.
  Primary source — download the Sparkle release tarball (no repo checkout
  required):
  ```sh
  # pick the version the app links against (2.9.x)
  curl -L -o /tmp/Sparkle.tar.xz \
    https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz
  mkdir -p /tmp/sparkle-tools && tar -xf /tmp/Sparkle.tar.xz -C /tmp/sparkle-tools
  ls /tmp/sparkle-tools/bin/    # generate_keys, sign_update, ...
  export SPARKLE_BIN=/tmp/sparkle-tools/bin
  "$SPARKLE_BIN/sign_update" --help
  ```
  Alternate source — once the SPM package is resolved, the same binaries are
  built under the artifact bundle in DerivedData (path varies; the tarball
  above is the stable, documented path).
- **EdDSA key pair** generated once, private key in the login Keychain,
  public key in `Info.plist`. See §3.

> This spike deliberately uses a **local** appcast + **local** HTTP server
> so nothing is published to the real GitHub Release / `raw.githubusercontent.com`
> feed. No production release is created by running this procedure.

---

## 3. One-time: EdDSA key + a throwaway public key in the test builds

The real signing key (matching the public key that will ship in production
`Info.plist`) may already exist in your Keychain from UPD-001. For the
spike you can reuse it, or generate a throwaway pair **for the test builds
only** — the point is that the v1 and v2 test builds carry the SAME public
key and v2's zip is signed by the matching private key, so Sparkle's
signature check passes and the update actually installs (which is the
precondition for observing Gatekeeper behavior at all).

```sh
# Generates/refreshes the pair; private key goes to the login Keychain,
# public key is printed. NEVER write the private key into the repo.
"$SPARKLE_BIN/generate_keys"
# Print the public key for the stored private key:
"$SPARKLE_BIN/generate_keys" -p
```

Put that printed public key into the **test** `Info.plist`'s `SUPublicEDKey`
for BOTH v1 and v2 builds (see §4 — we override it per build via a local
plist edit; do not commit a real key).

> SECURITY: the private key stays in the Keychain. Do not paste it into any
> file, commit, or this document. Only the public key is ever written down.

---

## 4. Build v0.0.1 and v0.0.2 (unsigned / ad-hoc)

We want two builds that differ **only** by version/build number, both
unsigned (or ad-hoc `-` signed, which is what an unnotarized local build
is), both pointing their `SUFeedURL` at the **local** test appcast, and both
carrying the same `SUPublicEDKey`.

Work in a scratch directory so nothing lands in the repo:

```sh
SPIKE=~/juststats-gk-spike
mkdir -p "$SPIKE"/{v1,v2,web}
cd /Volumes/MyData/Src/Github/justStats
```

### 4a. Build v0.0.1

Build Release with the spike version numbers and the local feed URL.
`CODE_SIGNING_ALLOWED=NO` yields an ad-hoc/unsigned bundle (the
distribution model — see TECHSPEC §6).

```sh
xcodebuild -project justStats.xcodeproj -scheme justStats \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$SPIKE/dd-v1" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION=0.0.1 CURRENT_PROJECT_VERSION=1 \
  clean build

cp -R "$SPIKE/dd-v1/Build/Products/Release/justStats.app" "$SPIKE/v1/justStats.app"
```

Now override the feed URL and public key **in the built bundle's**
`Info.plist` (so we never touch the repo's `Info.plist`, and never commit a
real key). `SUFeedURL` must point at the local server we start in §5:

```sh
PLIST="$SPIKE/v1/justStats.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :SUFeedURL http://localhost:8000/appcast.xml" "$PLIST"
# same public key that matches the private key in your Keychain:
/usr/libexec/PlistBuddy -c \
  "Set :SUPublicEDKey $("$SPARKLE_BIN/generate_keys" -p)" "$PLIST"
/usr/bin/plutil -p "$PLIST" | grep -E 'SUFeedURL|SUPublicEDKey|CFBundleVersion|CFBundleShort'
```

> NOTE: `http://localhost` is allowed **only** because Sparkle special-cases
> loopback for local testing; App Transport Security still forbids non-HTTPS
> for real hosts. Production `SUFeedURL` stays HTTPS (it already is in the
> repo). If your Sparkle version rejects the plain-HTTP loopback feed, add a
> temporary `NSAppTransportSecurity → NSAllowsLocalNetworking = true` to the
> **test** bundle's Info.plist only, or serve the local appcast over HTTPS
> with a self-signed cert. Do not commit either change.

### 4b. Build v0.0.2

Identical, only the version numbers change. Build number MUST be strictly
greater than v1's or Sparkle won't offer it.

```sh
xcodebuild -project justStats.xcodeproj -scheme justStats \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$SPIKE/dd-v2" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION=0.0.2 CURRENT_PROJECT_VERSION=2 \
  clean build

cp -R "$SPIKE/dd-v2/Build/Products/Release/justStats.app" "$SPIKE/v2/justStats.app"

PLIST2="$SPIKE/v2/justStats.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :SUFeedURL http://localhost:8000/appcast.xml" "$PLIST2"
/usr/libexec/PlistBuddy -c \
  "Set :SUPublicEDKey $("$SPARKLE_BIN/generate_keys" -p)" "$PLIST2"
```

### 4c. Zip v0.0.2 with `ditto` (this is the artifact Sparkle downloads)

Use `ditto` exactly as the release checklist does — `zip -r` can mangle the
bundle:

```sh
cd "$SPIKE/v2"
ditto -c -k --sequesterRsrc --keepParent justStats.app justStats-0.0.2.zip
cp justStats-0.0.2.zip "$SPIKE/web/justStats-0.0.2.zip"
stat -f%z "$SPIKE/web/justStats-0.0.2.zip"    # exact byte length for the appcast
```

### 4d. Sign the v0.0.2 zip

```sh
"$SPARKLE_BIN/sign_update" "$SPIKE/web/justStats-0.0.2.zip"
# → sparkle:edSignature="…==" length="123456"
```

Copy BOTH the `edSignature` and `length` values for the appcast in §5.

---

## 5. Serve a local test appcast

### 5a. Write the test appcast

`$SPIKE/web/appcast.xml` — points at the **local** zip URL, carries the v2
signature and length from §4d. (Same structure as the repo's `appcast.xml`,
minus the GitHub URLs.)

```sh
cat > "$SPIKE/web/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>justStats (Gatekeeper spike)</title>
    <link>http://localhost:8000/appcast.xml</link>
    <description>Local test feed for the UPD-003 Gatekeeper spike.</description>
    <language>en</language>
    <item>
      <title>Version 0.0.2</title>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>REPLACE_WITH_RFC822_DATE</pubDate>
      <description><![CDATA[<ul><li>Gatekeeper spike test build.</li></ul>]]></description>
      <enclosure
        url="http://localhost:8000/justStats-0.0.2.zip"
        sparkle:version="2"
        sparkle:shortVersionString="0.0.2"
        sparkle:edSignature="REPLACE_WITH_ED_SIGNATURE_FROM_sign_update"
        length="REPLACE_WITH_EXACT_ZIP_BYTE_LENGTH"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML
```

Fill in the three placeholders:

```sh
# pubDate
sed -i '' "s|REPLACE_WITH_RFC822_DATE|$(date -R)|" "$SPIKE/web/appcast.xml"
# edSignature + length — paste from the sign_update output in §4d, e.g.:
#   sed -i '' 's|REPLACE_WITH_ED_SIGNATURE_FROM_sign_update|<edSig>|' "$SPIKE/web/appcast.xml"
#   sed -i '' "s|REPLACE_WITH_EXACT_ZIP_BYTE_LENGTH|$(stat -f%z "$SPIKE/web/justStats-0.0.2.zip")|" "$SPIKE/web/appcast.xml"
xmllint --noout "$SPIKE/web/appcast.xml" && echo "appcast OK"
```

### 5b. Start the local HTTP server

```sh
cd "$SPIKE/web"
python3 -m http.server 8000
# leave this running in its own terminal; Ctrl-C to stop after the test
```

Sanity check from another terminal:

```sh
curl -s http://localhost:8000/appcast.xml | head
curl -sI http://localhost:8000/justStats-0.0.2.zip | head -1   # expect 200
```

> Optional belt-and-suspenders: instead of editing the built bundle's
> `SUFeedURL`, you can force the feed at runtime with a defaults override
> (Sparkle reads `SUFeedURL` from user defaults if present):
> ```sh
> defaults write com.zanybaka.justStats SUFeedURL http://localhost:8000/appcast.xml
> # undo after the spike:
> defaults delete com.zanybaka.justStats SUFeedURL
> ```
> Prefer the in-bundle plist edit (§4a) as the primary method; the defaults
> override is a fallback if the bundle edit doesn't take.

---

## 6. Run the actual upgrade flow (the part a human must do)

This is the crux. Do it deliberately and record each observation.

### 6.1 Simulate a real download of v1 (attach the quarantine flag)

An app the user *installed* (downloaded from GitHub) carries the
`com.apple.quarantine` xattr. A locally-built `.app` does NOT — so we must
add it, or the spike tests the wrong (too-easy) path:

```sh
xattr -w com.apple.quarantine \
  "0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)" \
  "$SPIKE/v1/justStats.app"
xattr -p com.apple.quarantine "$SPIKE/v1/justStats.app"   # confirm it's set
```

Copy v1 into `/Applications` (where a user would put it), preserving the
xattr:

```sh
ditto "$SPIKE/v1/justStats.app" /Applications/justStats.app
xattr -p com.apple.quarantine /Applications/justStats.app  # still set? good
```

### 6.2 First launch → expect the Gatekeeper block, then approve it

```sh
open /Applications/justStats.app
```

- **Expected:** macOS blocks it ("cannot be opened because it is from an
  unidentified developer" / "Apple could not verify…"). This is the normal
  unsigned-app first-launch experience the README documents.
- **Approve it the real way:** right-click the app in Finder → **Open** →
  **Open** in the dialog. (Or System Settings → Privacy & Security →
  **Open Anyway**.) The menu-bar icon should appear.
- **Record:** confirm the quarantine flag is now cleared/approved:
  ```sh
  xattr -p com.apple.quarantine /Applications/justStats.app 2>&1
  spctl -a -vvv /Applications/justStats.app 2>&1   # assessment for this bundle
  ```
  Note whatever these print — this is the **baseline** the updated bundle
  will be compared against.

### 6.3 "Publish" v2 (already done — the local server is serving it)

v2's zip + signed appcast are live at `http://localhost:8000` from §5.
Nothing else to do here; this step exists to mirror the real
release-checklist ordering (build → sign → publish → clients update).

### 6.4 Trigger the Sparkle update from the running v1

- Open **Settings** (menu-bar icon → gear) → click **Check for Updates…**.
- Sparkle should find v0.0.2, show its release-notes sheet, download the
  zip from localhost, **verify the EdDSA signature**, and offer
  **Install and Relaunch**. Click it.
- Sparkle replaces `/Applications/justStats.app` in place and relaunches.

> If Sparkle reports "signature verification failed", the public key in the
> test bundle doesn't match the private key that signed the zip — fix §3/§4
> before drawing any Gatekeeper conclusion. A signature failure is NOT a
> Gatekeeper result.

### 6.5 OBSERVE — this is the verdict

Watch precisely what happens at the relaunch:

- Does macOS show a **fresh Gatekeeper block / "unidentified developer"
  dialog** for the relaunched v0.0.2? (→ leaning **FAIL**)
- Does it relaunch **silently** with the new version and no prompt?
  (→ leaning **PASS**)
- Confirm the running version is actually 0.0.2 (menu-bar → Settings shows
  the version, or check the bundle):
  ```sh
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    /Applications/justStats.app/Contents/Info.plist   # expect 0.0.2
  ```

---

## 7. The measurement that decides PASS vs FAIL

Immediately after the update installs (§6.5), inspect the **updated**
bundle's quarantine state and Gatekeeper assessment:

```sh
xattr -l /Applications/justStats.app
xattr -p com.apple.quarantine /Applications/justStats.app 2>&1
spctl -a -vvv /Applications/justStats.app 2>&1
```

Interpretation:

| Observation on the **updated** v0.0.2 bundle | Verdict |
|---|---|
| No `com.apple.quarantine` xattr present, app relaunched with no prompt | **PASS** — Sparkle stripped quarantine; Gatekeeper stays satisfied. Sparkle updates are **GO**. |
| `com.apple.quarantine` present with the "unapproved" form AND macOS showed a fresh block dialog | **FAIL** — the update is re-quarantined and re-blocked. Sparkle silent updates are **NO-GO**; use the §8 fallback. |
| No block dialog, but a `com.apple.quarantine` present in an already-approved form, app launched fine | **PASS (nuanced)** — Gatekeeper accepted it; note the exact xattr value in the results. |
| A block appeared but only as a passive, non-blocking warning that didn't stop launch | **PASS (with caveat)** — document the exact wording; decide if the UX is acceptable. |

Also capture, for the written result:

- `spctl --status` (was Gatekeeper actually enabled during the test?),
- macOS version (`sw_vers`),
- the exact text of any dialog (screenshot),
- whether the relaunch required any human click at all.

---

## 8. Fallback if the verdict is FAIL

If Gatekeeper re-blocks the Sparkle-delivered update, silent auto-update is
not achievable for an unsigned/unnotarized build. The fallback (already the
direction in architecture-draft §7 and TECHSPEC §6) is:

- Sparkle still **detects** the new version and tells the user one is
  available, but instead of "Install and Relaunch" the in-app messaging
  points the user to **manually download** the new `.zip` from the GitHub
  Release and re-approve via right-click → Open.
- Document this in the README's install/update section and in-app (the
  "Check for Updates…" result copy) so users aren't surprised by a
  re-block.
- Track the proper long-term fix (Apple Developer ID signing + notarization,
  which removes the quarantine re-block entirely) as a separate,
  out-of-scope-for-v1 item.

Record the FAIL details and this decision into TECHSPEC §6, replacing the
"PENDING" note with the real result.

---

## 9. Cleanup (leave the machine as you found it)

```sh
# stop the python server (Ctrl-C in its terminal)
rm -rf /Applications/justStats.app        # remove the spike install
defaults delete com.zanybaka.justStats SUFeedURL 2>/dev/null || true
rm -rf ~/juststats-gk-spike               # scratch builds, zips, appcast
# if you disabled ATS or Gatekeeper for the test, restore both:
sudo spctl --master-enable                # if you had toggled it
```

Do **not** commit anything produced by this run — the scratch builds, the
local appcast, the throwaway keys, and any per-bundle plist edits are all
disposable. Only the **written verdict** goes back into `docs/techspec.md §6`.

---

## 10. Recording the result

When a human has run the above, write the outcome into **TECHSPEC §6**,
replacing the current "PENDING" paragraph with:

- the verdict (**GO** / **NO-GO** for silent Sparkle updates),
- the machine/OS it was verified on,
- the observed `xattr`/`spctl` evidence,
- if NO-GO, a pointer to the §8 manual-download fallback now in effect.

That closes UPD-003's DoD ("Findings written into TECHSPEC §6 with a clear
go/no-go"). Until then, the verdict line in TECHSPEC §6 stays **PENDING**.
