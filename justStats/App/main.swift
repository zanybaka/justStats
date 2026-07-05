import AppKit

// AppKit lifecycle entry point (no @main / SwiftUI App lifecycle by design — see docs/techspec.md §1).
//
// `main.swift` top-level code runs synchronously on the process's main thread before
// the run loop starts, so it is safe to assume main-actor isolation to construct the
// `@MainActor` delegate (SET-003 made `AppDelegate` main-actor-isolated). `NSApplicationMain`
// then hands control to the AppKit run loop, which drives all subsequent callbacks on
// the main thread.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
