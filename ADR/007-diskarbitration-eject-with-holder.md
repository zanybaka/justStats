# ADR-007: Eject via DiskArbitration, naming the holder through the dissenter PID

Status: Accepted
Date: 2026-11-21
Sources: `docs/prd.md` (FR17, ADR-CANDIDATE — eject with holder); `docs/techspec.md` §13; backlog task VOL-008; live probe of `DADiskUnmount` on a held disk image, 2026-11-21

## Context

When macOS refuses to eject a volume it says "one or more programs may be using it" and never names the program. The owner had to run diagnostics to learn the blocker was `mds_stores`. justStats should unmount external and network volumes itself and say, in plain words, who is holding the volume. It runs without admin rights and without a helper tool, so `sudo lsof` is not an option.

The task's first design assumed the public DiskArbitration SDK offers `DADissenterGetPID`. It does not: `DADissenter.h` exposes only `DADissenterGetStatus` and `DADissenterGetStatusString`, and a probe on macOS 15.7.5 showed that a busy refusal returns status `0xc010` (`EBUSY`) with **no status string**. `diskutil` does print "dissented by PID …", and the framework's `.tbd` exports `DADissenterGetProcessID`, which is simply missing from the headers.

## Decision

- Unmount with `DADiskUnmount` on the whole disk (`kDADiskUnmountOptionWhole`) so a multi-volume stick ejects together, like Finder; Force Eject adds `kDADiskUnmountOptionForce`; a best-effort `DADiskEject` follows a successful unmount.
- Read the holder PID from `DADissenterGetProcessID`, resolved at runtime with `dlsym`. If the symbol is missing the refusal degrades to "a program is using it"; the app still launches and ejects.
- Resolve the process name with `proc_name`, falling back to `sysctl(kern.proc.pid)`, because `proc_name` is empty for root daemons such as `mds_stores`.
- Map known system holders to short English phrases in a built-in dictionary; an unknown holder renders as `process <name> (PID <n>)`.
- Hide the mechanism behind a `VolumeEjecting` protocol so the view model is tested without a real mount.
- Network mounts have no `DADisk`: they fall back to `FileManager.unmountVolume` (Force: `unmount(2)` with `MNT_FORCE`) and name no holder.

## Alternatives considered

- **`NSWorkspace.unmountAndEjectDevice` / `FileManager.unmountVolume` only:** supported API, but the error carries no holder. That is the original complaint.
- **Parse `lsof` output:** slow, a subprocess to manage, and blind to processes of other users (root daemons such as `mds_stores`) without sudo.
- **Scan open files via libproc (`proc_pidinfo`):** verified to find same-user holders, but 169 of 672 processes were unreadable on the test Mac, including the root daemons that usually hold external disks.
- **Link the private DiskManagement framework (what `diskutil` uses):** a much larger private surface than one exported symbol.

## Consequences

- The holder is named precisely and instantly, with no privileges. Verified with a real mounted image held by a process: refusal named the process; Force unmounted it; a free volume unmounted cleanly.
- A dependency on one undocumented but exported symbol. Failure mode is graceful (no holder named). The distribution is already outside the App Store (ADR-004), so private-symbol lookup has no review risk, but a future macOS could change the signature; the unit tests cover the mapping and the manual QA step covers the real call.
- The dissenter does not say which volume of a multi-volume stick refused; the message names the volume the user pressed Eject on plus the holder.
- Network volumes get no holder name. Network unmount paths were not exercised against a real share in VOL-008.
- A busy refusal takes about 11 s, so the UI shows an "Ejecting…" state for that long.

## Implementation references

- `justStats/Modules/Disk/VolumeEjecting.swift` — `VolumeEjecting`, `EjectResult`, `EjectMessages`, `DiskArbitrationVolumeEjector`.
- `justStats/Modules/Disk/VolumeListViewModel.swift` — `EjectState`, eject flow, `NSWorkspace.didUnmountNotification` observation.
- `justStats/Modules/Disk/VolumeEjectViews.swift` — button and inline panel.
- `justStatsTests/VolumeEjectTests.swift` — seam-driven tests.
