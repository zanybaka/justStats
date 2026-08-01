## Phase 14 — Branding & doc assets (2026-07-05, before public release)

- [x] ASSET-001 App icon (disk-monitor motif)
Task Context: The app has no custom icon (no `.icns`, no `AppIcon` in the pbxproj — it shows the generic app icon in Finder / the About panel). Create a macOS app icon on a disk/storage-monitor theme fitting the app's identity (the colored status glyph / segmented usage bar), via the `macos-app-icon` skill: a 1024×1024 source, then `AppIcon.appiconset` (all sizes, HIG safe zone / squircle) + `.icns`, wired into the `justStats` target (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, an `Assets.xcassets` in the synchronized `justStats/` group). Appearance-adaptive/tinted variants optional.
Task DOD: The built app shows the custom icon in Finder and the About panel; build stays green; icon renders at menu/Finder/Dock-preview sizes without mush.
Priority: P2
Size: M
Depends on:
Agent: auto
Verify: build; inspect `dist/justStats.app` icon in Finder Get Info
