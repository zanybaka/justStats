# Manual Accessibility Test Script (QA-001)

VoiceOver + keyboard-only walkthrough for justStats. Everything an automated agent
could verify (the spoken-summary strings, the non-color icon shape cue, keyboard
wiring) is covered by unit tests; this script covers the parts that **require a human
with VoiceOver running on a real Mac** — actual announcement, focus order, and
keyboard operability of the live `NSStatusItem` / `NSPopover` / Settings window.

Run on: macOS 15 (Sequoia) or later, Apple Silicon or Intel. Build the app
(`Release` or `Debug`), launch it, and confirm the menu bar icon appears.

## Conventions

- **VO** = the VoiceOver keys, `Control-Option`. "VO-Right" = `Control-Option-Right Arrow`.
- Toggle VoiceOver with `Command-F5` (or triple-press Touch ID/Power on some Macs).
- **Keyboard-only** steps assume the mouse/trackpad is **not touched** — use Tab,
  arrows, Space, and Return only.
- If a step says "VO announces …", the quoted text is what you should hear; minor
  punctuation differences are fine, but the **facts** (state word, sizes, action) must
  be spoken. The exact strings are pinned in the unit tests
  (`RowAccessibilityLabelTests`, `IconControllerTests`) so any wording drift there
  fails CI before it reaches this script.

---

## Part A — Status item announces the real disk state (not "button")

Covers TECHSPEC §9 item 9 first clause; unit-verified string source: `IconStatus.accessibilityLabel`.

1. Turn VoiceOver **on** (`Command-F5`).
2. Move VO focus to the menu bar: press **VO-M** (moves to the menu bar), then
   **VO-Right / VO-Left** to walk the status items until you reach the justStats icon.
   - Alternatively: **VO-M twice** cycles to the status menu (right side of the menu bar).
3. **Expected:** VoiceOver announces a real sentence, e.g.
   - green: *"Disk status: OK, 250 GB free"*
   - yellow: *"Disk status: low, 15 GB free"*
   - red: *"Disk status: critical, 8 GB free"*
   It must **not** say only "button" or "justStats". The free-space figure must match
   the boot volume's actual free space.
4. **Color-is-not-the-only-cue check (visual, no VO):** with normal vision, confirm the
   icon **shape** differs by state — green/yellow render a filled **disk (circle)**; red
   renders a **warning triangle with an exclamation mark**. Someone who cannot
   distinguish the hues still sees the shape change. (Unit-verified:
   `IconControllerTests.testEachStateRendersDistinctly` asserts red differs in shape,
   not only hue.)
5. **Activate by keyboard:** with VO focus on the icon, press **VO-Space**. The popover
   opens. (Proves the status item is operable without a mouse.)

> If the current free space keeps the icon green and you want to see the red
> announcement, open **Settings** (Part D) and temporarily raise the red threshold above
> the current free space; the icon and its spoken label update within one refresh tick.

---

## Part B — Open the popover and read the volumes

Covers TECHSPEC §9 item 9 "rows reachable". Unit-verified string source:
`VolumeRowView.headerAccessibilityLabel`.

1. With the popover open (from Part A step 5, or click the icon), press **VO-Right**
   repeatedly to walk the popover top to bottom. Confirm the **focus order** is sane:
   header → sort toggle → refresh → settings gear → volume rows → largest-files header →
   file rows.
2. On the **header**, VO announces *"Volumes, heading"* (it carries the heading trait,
   so **VO-Command-H** also jumps between the "Volumes" and "Largest files on …"
   headings via the headings rotor).
3. On the **sort toggle**, VO announces *"Sort by fullness"* plus its value —
   *"Default order"* or *"Most full first"* — and, when active, *"selected"*. Press
   **VO-Space** to toggle it; the value announcement flips. (The direction is spoken as a
   value, so it is not conveyed by the icon glyph alone.)
4. On the **Refresh** button, VO announces *"Refresh, button"*. Press **VO-Space**;
   the list re-reads.
5. On each **volume row**, VO announces one coherent sentence:
   *"Macintosh HD, 100 GB free, 400 GB used of 500 GB"*. Confirm the **name, free, and
   used-of-total are all spoken as a single element** (not "Macintosh HD" then a separate
   "100 GB free"). This holds for **all** row variants — the category-bar rows too, whose
   used/total numbers otherwise live only in the bar legend.
6. A **still-loading** external/network row announces *"<name>, loading"*; a hung mount
   announces *"<name>, size unavailable"*. (Attach a USB drive, or point at a slow SMB
   mount, to exercise these — otherwise skip.)

---

## Part C — Read a category bar and the degraded notices

Covers "category bar segments carry per-segment name + size, not color-only" and the
notices. Unit-verified string source: `CategoryBarView.accessibilitySummary`,
`NotIndexedNoticeView`, `FullDiskAccessNoticeView`.

1. On the boot volume's row, after its scan lands, **VO-Right** onto the **category bar**.
2. **Expected:** VoiceOver reads the whole bar as one ordered sentence naming **each
   non-empty category and its size**, e.g.
   *"Macintosh HD storage breakdown: System 60 GB, Apps 30 GB, Media 20 GB, Free 50 GB"*.
   The **color swatches are decorative** — every segment's meaning is in the spoken
   name+size and in the visible legend text beneath the bar, so a color-blind or
   VoiceOver user gets the full breakdown. Confirm the legend under the bar visually
   lists the same names+sizes (not just colored dots).
3. **"Not indexed" notice** (SCAN-005): on a genuinely unindexed external drive's row, VO
   announces *"<volume>: Not indexed — category breakdown unavailable"*. (Skip if no such
   drive is attached.)
4. **Full Disk Access notice** (SCAN-006): if the boot volume's index is empty (no FDA
   grant), the row shows the FDA notice. VO announces *"<volume>: Grant Full Disk Access
   for complete data"* with the hint *"Opens Full Disk Access settings"*. **VO-Right**
   to the **Open Settings** button, press **VO-Space** — System Settings' Full Disk
   Access pane opens. (To force this state: revoke justStats' Full Disk Access in
   System Settings, relaunch, reopen the popover.)

---

## Part D — Trash a file via keyboard only (destructive-action discipline)

Covers TECHSPEC §9 item 9 "Trash operable via keyboard alone" and the DOD "VoiceOver
user can trash a file". Unit-verified string source:
`LargestFileRow.rowAccessibilityLabel` and the button labels in `LargestFilesSection`.

> **Use a throwaway file.** Move to Trash is recoverable (the file goes to the Trash,
> not a permanent delete), but do this on a file you don't mind moving. Create one first,
> e.g. `mkfile 2g ~/Desktop/a11y-test.bin` (or copy a large file to `~/Desktop`), so it
> ranks in the largest-files list.

1. Open the popover (keyboard: focus the status item per Part A, **VO-Space**).
2. **VO-Right** down to the **Largest files on <volume>** heading, then into the file
   rows. On a file row VO announces *"<file name>, <size>"*, e.g.
   *"a11y-test.bin, 2 GB"*.
3. **VO-Right** to that row's **Move to Trash** button — VO announces
   *"Move a11y-test.bin to Trash, button"*. Press **VO-Space**.
4. The row flips to the **inline confirm** state (no modal). Confirm:
   - the row now announces *"a11y-test.bin, 2 GB, confirm move to Trash"* (the pending
     destructive state is spoken, so a VoiceOver user is not left in it silently), and
   - **VO-Right** reaches a **Cancel** button (*"Cancel moving a11y-test.bin to Trash"*)
     and a **Move to Trash** confirm button (*"Confirm moving a11y-test.bin to Trash"*)
     with the hint *"Moves the file to the Trash. Recoverable from the Trash."*
5. **Keyboard-only reachability check:** everything in step 4 must be reachable with
   **VO-Right / VO-Left** and operable with **VO-Space** — no mouse.
6. Press **VO-Space** on the **confirm** button. The file moves to the Trash; the row
   drops out of the list. Open Finder → Trash and confirm the file is there
   (recoverable). Put it back or empty the Trash as you like.
7. **Cancel path:** repeat steps 2–4 on another file, then **VO-Space** the **Cancel**
   button — the row returns to its resting *Reveal + Trash* state, file untouched.
8. **Reveal path:** on a file row, **VO-Right** to **Reveal <file> in Finder**, press
   **VO-Space** — Finder activates with the file selected.

---

## Part E — Settings window: labels + keyboard operability

Covers TECHSPEC §9 item 9 "Settings gear reachable / operable via keyboard". Unit source:
the labels live in `SettingsView`; the `⌘,` wiring is in `SettingsMenu` /
`SettingsMenuTests`.

1. Open Settings by keyboard **two ways** — verify **both**:
   - From the popover: **VO-Right** to the **Settings** gear (*"Settings, button"*),
     **VO-Space**.
   - Global shortcut: with the popover or Settings window frontmost, press **⌘,**
     (Command-comma). The Settings window opens/comes forward.
2. In the Settings window, press **Tab** (and **Shift-Tab**) to walk every control.
   Confirm each is focusable and labelled:
   - **Threshold mode** segmented picker — VO: *"Threshold mode"*; switch with arrows
     between *Free space (GB)* and *Free space (%)*.
   - **Red below** field — VO: *"Red threshold in gigabytes"* (or *"… percentage"* in %
     mode). Type a number; the icon re-evaluates.
   - **Red below** stepper — VO: *"Red threshold in gigabytes stepper"*; **↑/↓** or
     **VO-Space** on the increment/decrement.
   - **Yellow below** field + stepper — analogous *"Yellow threshold …"* labels.
   - **Launch at Login** toggle — VO: *"Launch at login, switch"*; **VO-Space** flips it.
   - **Automatically check for updates** toggle — VO: *"Automatically check for updates,
     switch"*.
   - **Check for Updates…** button — VO: *"Check for updates, button"*.
3. If you enter an inconsistent threshold (yellow ≤ red, etc.), the inline validation
   warning appears and VO reads its text.
4. **Keyboard-only close:** **⌘W** closes the Settings window; reopening with **⌘,**
   reuses it (no duplicate window).

---

## Sign-off checklist

Tick each after a real VoiceOver + keyboard-only run:

- [ ] A: status item announces the real disk-state sentence (state word + free space), not "button".
- [ ] A: icon shape differs by state (disk vs. warning triangle) — color is not the only cue.
- [ ] A: status item opens the popover via VO-Space (keyboard only).
- [ ] B: popover focus order is sane top-to-bottom.
- [ ] B: "Volumes" is a heading; sort toggle speaks its direction as a value; Refresh operable.
- [ ] B: each volume row speaks name + free + used-of-total as one element (incl. category-bar rows).
- [ ] C: category bar speaks every non-empty category with its size; legend lists them visually.
- [ ] C: "Not indexed" and Full Disk Access notices are announced; FDA button opens the pane.
- [ ] D: a file can be moved to Trash **entirely by keyboard**; the confirm state is announced.
- [ ] D: Cancel and Reveal paths work by keyboard.
- [ ] E: Settings opens via the gear **and** via ⌘,; every control is Tab-reachable and labelled.
- [ ] E: Settings window closes with ⌘W and reopens reusing the same window.

---

## What still needs a human (cannot be automated headlessly)

The following are **inherently manual** — no agent in this environment can perform them:

1. **The entire VoiceOver walkthrough above** — real speech output, focus movement, and
   rotor behavior can only be confirmed with VoiceOver actually running on a Mac.
2. **Keyboard-only operability of the live AppKit surfaces** — the `NSStatusItem`
   button, `NSPopover`, and Settings `NSWindow`. Unit tests verify the button targets,
   the `⌘,` key equivalent (`SettingsMenuTests`), and the a11y **strings**, but not that
   Tab/VO focus actually lands on and activates each live control.
3. **Full Disk Access degraded-state announcement (Part C step 4)** — requires revoking
   FDA in System Settings and relaunching; there is no headless way to force the pane or
   confirm it opened.
4. **External / hung-mount row announcements (Part B step 6)** — require physically
   attaching a USB drive and pointing at a slow/dead network mount.
5. **Reduced Transparency / Increase Contrast / Reduce Motion** system settings — sanity-
   check that the popover and icon stay legible with these Accessibility system options
   enabled (not scripted here; a quick visual pass is recommended before release).

Everything else — the spoken-summary wording, the non-color icon shape, the state →
content mapping, and the button wiring — is covered by the XCTest suite and runs in CI.
