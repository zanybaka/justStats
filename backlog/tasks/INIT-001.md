## Phase 0 — Project initialization

- [x] INIT-001 Create Xcode app skeleton with module layout
Task Context: New AppKit-lifecycle macOS app target `justStats`, deployment target macOS 15, universal binary (arm64 + x86_64), `LSUIElement = true` (menu-bar only, no Dock icon). Folder layout per TECHSPEC §1: `App/` (shell), `Kit/` (shared helpers), `Modules/Disk/`. Add empty XCTest target.
Task DOD: Project builds clean from a fresh clone; app launches showing a placeholder status item; test target runs (0 tests OK).
Priority: P1
Size: M
Depends on:
Agent: auto
Verify: xcodebuild -scheme justStats build test
