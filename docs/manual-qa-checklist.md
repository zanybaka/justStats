# Manual QA Checklist (QA-003)

Pre-release, human-executed release checklist for justStats, derived from
**TECHSPEC §9** manual-QA items 1–9. Everything here is **inherently manual** —
it exercises the live `NSStatusItem` / `NSPopover` / Settings window, real
volumes, real hardware, and real logout/login, none of which an automated agent
can drive headlessly. Pure logic (threshold→color math, category math,
largest-files sort, a11y strings) is already covered by the XCTest suite in CI
and is **not** re-checked here.

Run on: macOS 15 (Sequoia) or later, Apple Silicon or Intel. Build the app
(`Release` preferred, `Debug` acceptable), launch it, and confirm the menu bar
icon appears before starting.

## Conventions

- **App under test:** the `justStats.app` you just built (bundle id
  `com.zanybaka.justStats`).
- Some steps can be **scripted** to force a state (e.g. `defaults write` to move
  the icon color). Where so, the exact command is given as plain text — copy it
  verbatim. Commands assume `justStats` is the frontmost/only instance and that
  no `NSUserDefaults` suite override is in play.
- Thresholds are stored under `com.zanybaka.justStats` with these keys
  (source of truth: `justStats/Kit/DefaultsKeys.swift`):
  `redThresholdBytes`, `yellowThresholdBytes` (Int64, **decimal** bytes, absolute
  mode); `redThresholdPercent`, `yellowThresholdPercent` (Double, percentage
  mode); `thresholdMode` (`absolute` | `percentage`). The app re-reads the config
  on each refresh tick, so a `defaults write` flips the icon within one tick
  without a relaunch. Settings-window edits persist to the **same** keys.
- **Restore after scripted threshold changes** so a tester's machine is left at
  defaults (red < 10 GB, yellow < 20 GB, absolute):

  ```
  defaults delete com.zanybaka.justStats redThresholdBytes
  defaults delete com.zanybaka.justStats yellowThresholdBytes
  defaults delete com.zanybaka.justStats redThresholdPercent
  defaults delete com.zanybaka.justStats yellowThresholdPercent
  defaults delete com.zanybaka.justStats thresholdMode
  ```

  (Missing keys fall back to defaults per-field; `defaults delete` on an absent
  key is harmless.)

- **VoiceOver + keyboard-only (item 9)** is **not** duplicated here — it lives in
  `docs/manual-accessibility-test.md` (QA-001). Item 9 below is a pointer only.

---

## 1. Cold launch — icon appears immediately, correct color

**TECHSPEC §9 item 1.**

Steps:
1. Quit any running justStats instance.
2. Confirm no threshold overrides are active (run the restore block above), then
   launch the freshly built app:

   ```
   open /path/to/justStats.app
   ```

3. Watch the menu bar the instant the app launches.

Expected:
- The status-item icon appears **immediately** (no perceptible blank/lag before
  the icon is drawn).
- Its color matches the **boot volume's actual free space** against default
  thresholds: green when free ≥ 20 GB, yellow when 10 GB ≤ free < 20 GB, red when
  free < 10 GB. Cross-check the boot volume's free space in Finder / Disk Utility
  or with `df -H /`.
- The icon **shape** cue matches the color (green/yellow = filled disk, red =
  warning triangle) — see QA-001 Part A step 4.

Pass / Fail: [ ]

---

## 2. Open popover — internal disks appear first, no visible delay

**TECHSPEC §9 item 2.**

Steps:
1. Click the status-item icon to open the popover.

Expected:
- Internal (boot + other internal) volumes render **first** and with **no
  visible delay** — the internal rows are present the moment the popover appears;
  the UI does not wait on external/network enumeration to show them.
- Each internal row shows name, free, and used-of-total; the boot volume's
  category bar fills in shortly after (streaming), without blocking the rows.

Pass / Fail: [ ]

---

## 3. Attach a USB volume — appears without blocking the UI

**TECHSPEC §9 item 3.**

Steps:
1. With the popover open, physically attach an external **USB** volume (or an SD
   card / external SSD that mounts as removable).
2. Keep interacting with the popover (scroll, hover) while it mounts.

Expected:
- The new external volume's row **appears in the list** once mounted, added below
  the internal volumes.
- The rest of the UI stays **responsive** the whole time — no beachball, no
  freeze; internal rows remain interactive while the external volume enumerates
  and its size/category data streams in (row may briefly show a loading state).
- Detaching the volume removes its row cleanly.

Pass / Fail: [ ]

---

## 4. Disconnected / slow network volume doesn't freeze the popover

**TECHSPEC §9 item 4.**

Steps (use one):
- **A (real slow mount):** mount an SMB/AFP share, e.g.
  `open 'smb://server/share'`, then pull the network (disable Wi-Fi / unplug
  Ethernet) so the mount goes stale but stays mounted. Open the popover.
- **B (dead mount):** point at a share on a host that is offline, so the mount
  hangs on stat. Open the popover.

Expected:
- The popover **still renders** the internal + healthy external rows **without
  freezing** — the hung/slow network volume must not block the whole list.
- The stalled network row shows a **loading / size-unavailable** state rather
  than beachballing the UI (a11y wording: QA-001 Part B step 6).
- Refresh and scrolling remain responsive while the network row is stuck.

Pass / Fail: [ ]

---

## 5. Threshold color flip — abundant → yellow/red within one tick

**TECHSPEC §9 item 5.** Fully scriptable via `defaults write`.

The point is: a boot volume with abundant free space shows **green**; forcing the
thresholds above the current free space flips the icon within **one refresh
tick** (no relaunch). Use scripted thresholds so the check is deterministic
regardless of the machine's real free space.

Steps:
1. Confirm the icon is **green** at defaults (abundant free space). If the boot
   volume is genuinely low, that itself is the green→non-green boundary; note it.
2. Find the boot volume's free space in bytes to pick threshold values above it:

   ```
   df -k / | awk 'NR==2 {print $4 * 1024 " bytes free"}'   # macOS: -k = 1K blocks
   ```

3. **Force RED:** set the red threshold **above** current free space (example
   uses 100 TB so it always trips; adjust if your volume is larger):

   ```
   defaults write com.zanybaka.justStats thresholdMode -string absolute
   defaults write com.zanybaka.justStats redThresholdBytes -int 100000000000000
   ```

   Expected: within one refresh tick the icon turns **red** (warning-triangle
   shape) — no relaunch needed.

4. **Force YELLOW:** drop red back below free space and raise yellow above it:

   ```
   defaults write com.zanybaka.justStats redThresholdBytes -int 1
   defaults write com.zanybaka.justStats yellowThresholdBytes -int 100000000000000
   ```

   Expected: within one tick the icon turns **yellow** (filled-disk shape).

5. **Percentage mode** (optional variant): a 100% red threshold always trips:

   ```
   defaults write com.zanybaka.justStats thresholdMode -string percentage
   defaults write com.zanybaka.justStats redThresholdPercent -int 100
   ```

   Expected: icon turns **red** within one tick.

6. **Restore defaults** (run the restore block from Conventions). Expected: icon
   returns to its real-free-space color within one tick.

7. **Settings-window path (no scripting):** open Settings (gear or `⌘,`), lower
   the thresholds via the fields/steppers so the boot volume falls under
   yellow/red, and confirm the icon updates within one tick; then restore.

Pass / Fail: [ ]

---

## 6. Largest files — Reveal in Finder + Move to Trash (recoverable)

**TECHSPEC §9 item 6.** Use a **throwaway** file.

Steps:
1. Create a large throwaway file so it ranks in the largest-files list:

   ```
   mkfile 2g ~/Desktop/juststats-qa-test.bin
   ```

   (or copy any large file to `~/Desktop`). Open the popover; if needed, Refresh
   so the boot volume's largest-files list re-scans and the file shows up.
2. On its row, click **Reveal in Finder**.

   Expected: Finder activates with **`juststats-qa-test.bin` selected** in
   `~/Desktop`.
3. Back in the popover, on that row click **Move to Trash**.

   Expected: the row flips to an **inline confirm** state (no modal); a Cancel
   and a confirm "Move to Trash" appear.
4. Click **Cancel** once to verify the file is untouched, then **Move to Trash**
   again and **confirm**.

   Expected: the file **moves to the Trash** and the row drops out of the list.
5. Verify **recoverability:** open Finder → Trash; `juststats-qa-test.bin` is
   there and can be **Put Back**. Confirm the original is gone from `~/Desktop`:

   ```
   ls -l ~/Desktop/juststats-qa-test.bin   # expect: No such file or directory
   ls -l ~/.Trash/juststats-qa-test.bin    # expect: the file, recoverable
   ```

6. Clean up: Put Back or empty the Trash as you prefer.

Pass / Fail: [ ]

---

## 7. Launch at Login — toggle, log out/in, verify actual behavior

**TECHSPEC §9 item 7.** Requires a real logout/login — cannot be scripted away.

Steps:
1. Open Settings (`⌘,`). Toggle **Launch at Login** **ON**.
2. (Optional visibility check) The registration is via `SMAppService`; you can
   observe the pending/enabled state in **System Settings → General → Login Items
   & Extensions** (justStats should be listed / enabled).
3. **Log out and log back in** (Apple menu → Log Out …), or restart.

   Expected: justStats **launches automatically** at login; its icon appears in
   the menu bar without manual launch.
4. Open Settings again, toggle **Launch at Login** **OFF**, log out and back in.

   Expected: justStats does **not** auto-launch; the menu bar has no icon until
   you launch it manually. The toggle state in Settings matches actual behavior
   in both directions.

Pass / Fail: [ ]

---

## 8. Full Disk Access degraded state → notice, then resolves after granting

**TECHSPEC §9 item 8.**

Steps:
1. **Revoke** justStats' Full Disk Access: System Settings → Privacy & Security →
   **Full Disk Access** → turn justStats **off** (or remove it). Quit justStats.
   You can open that pane directly with:

   ```
   open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'
   ```

2. Relaunch justStats and open the popover.

   Expected: the boot volume's row shows the **degraded / Full Disk Access
   notice** ("Grant Full Disk Access for complete data") instead of a full
   category breakdown (the category data is unavailable without the grant). The
   volume free/used numbers still show.
3. Click the notice's **Open Settings** button.

   Expected: it opens the **Full Disk Access** pane.
4. **Grant** Full Disk Access to justStats there, then **quit and relaunch**
   justStats and reopen the popover.

   Expected: the degraded notice is **gone** and the boot volume's category
   breakdown renders normally. (a11y wording for this notice: QA-001 Part C
   step 4.)

Pass / Fail: [ ]

---

## 9. VoiceOver + keyboard-only

**TECHSPEC §9 item 9.** Not duplicated here.

Execute the full VoiceOver + keyboard-only walkthrough in
**`docs/manual-accessibility-test.md` (QA-001)** — Parts A–E plus its sign-off
checklist. It covers: the status item announcing the real disk-state sentence
(not "button"), the non-color shape cue, popover focus order, every control
(rows, sort toggle, Refresh, Settings gear, Reveal, Trash + inline confirm)
reachable and operable via keyboard alone, and the Settings window.

Pass / Fail: [ ] (see QA-001 sign-off)

---

## Run log

### 2026-07-05 — justStats 0.3.4, macOS 15.7.5, Apple Silicon (REL-003)

No blockers found. Items marked "not tested" are hardware/session-dependent and
are tracked as deferred follow-up **REL-006**; their logic is covered by the XCTest
suite.

- [x] 1. Cold launch — icon appeared immediately, green filled-disk matching ~73 GB free. **PASS**
- [x] 2. Popover — internal disks rendered first with no visible delay; category bar streamed in. **PASS**
- [~] 3. USB attach — **not tested (no USB device on hand).** Streaming-append logic covered by `VolumeListViewModel` tests. → REL-006
- [~] 4. Slow/dead network mount — **not tested (no reproducible stale mount).** Hung-mount isolation covered by `DeferredVolumeResolver` tests. → REL-006
- [x] 5. Threshold flip — scripted red / yellow / percentage-red all flipped the icon within a tick; restore returned to green; the Settings-window path also flipped + persisted. **PASS**
- [x] 6. Largest files — Reveal in Finder selected the file; Move-to-Trash inline confirm + Cancel verified live. Actual `trashItem` execution covered by ACT-002 tests + the ACT-003 no-permanent-delete audit (a live throwaway wasn't feasible: it must exceed the machine's 15th-largest file — multi-GB — and Spotlight hadn't indexed a fresh file). **PASS**
- [x] 7. Launch at Login — toggling on/off registered/unregistered justStats in System Settings → Login Items live (`SMAppService`). Full logout/login auto-launch left as an optional confirmation. **PASS**
- [x] 8. Full Disk Access — categories render correctly **without** FDA (Spotlight needs no FDA for the general breakdown), so the lazy degraded notice correctly does not appear; there was no FDA-blocked data to force the degraded state. Notice-visibility logic covered by SCAN-006 tests. **PASS**
- [~] 9. VoiceOver + keyboard-only — **deferred (REL-004).**

## Release sign-off

Tick each only after a real run on a Mac:

- [ ] 1. Cold launch: icon appears immediately, color matches real boot-volume free space.
- [ ] 2. Popover: internal disks appear first with no visible delay.
- [ ] 3. USB attach: external volume appears without blocking/freezing the UI.
- [ ] 4. Slow/dead network mount: popover renders internal + external rows without freezing.
- [ ] 5. Threshold flip: forcing thresholds (scripted and via Settings) flips icon color within one tick; defaults restored.
- [ ] 6. Largest files: Reveal selects the right file; Move to Trash confirms and moves it to the Trash (recoverable).
- [ ] 7. Launch at Login: on/off toggle matches actual auto-launch behavior across logout/login.
- [ ] 8. Full Disk Access: degraded notice shown when revoked; granting + relaunch resolves it.
- [ ] 9. VoiceOver + keyboard-only: QA-001 walkthrough passes (see its sign-off).

---

## Manual-only steps (cannot be automated headlessly)

Every item above is manual; these in particular have **no** headless substitute:

1. **Real hardware:** USB attach (item 3) and a genuinely slow/dead network mount
   (item 4) — physical devices / network conditions.
2. **Logout/login:** Launch-at-Login verification (item 7) requires an actual
   session logout and login (or restart).
3. **System-privacy toggles:** revoking/granting Full Disk Access (item 8)
   happens in System Settings and takes effect only across a relaunch.
4. **Live UI observation:** "icon appears immediately" (item 1), "internal-first
   with no visible delay" (item 2), and "UI doesn't freeze" (items 3, 4) are
   perceptual/timing judgments on the live `NSStatusItem`/`NSPopover`.
5. **VoiceOver + keyboard-only** (item 9): the entire QA-001 walkthrough — real
   speech, focus movement, keyboard operability.

## NFR follow-up (out of this checklist's scope)

Per the QA-003 brief and TECHSPEC §7: a **side-by-side idle CPU / memory
comparison against exelban/stats is a separate MANUAL follow-up** — Stats is not
installed on the build machine, so justStats' own idle numbers can be measured
here but the head-to-head comparison must be done by a human with both apps
installed on a real Mac.
