import ServiceManagement

/// Seam for the "Launch at Login" setting (SET-002, PRD FR10, TECHSPEC §5). The Settings
/// view model drives login-item registration through this abstraction rather than calling
/// `SMAppService` directly, so the toggle's enable/disable/read-current-state logic is
/// unit-testable without actually touching the user's real Login Items.
///
/// TECHSPEC §5 deliberately uses `SMAppService.mainApp` (the modern, Sequoia-15+ API) and
/// **no** separate login-item helper executable — that legacy pattern (which Stats still
/// carries for older macOS) is unnecessary at our baseline and is not reproduced here.
///
/// The toggle must reflect the *real* registration status, not a cached bool: `isEnabled`
/// reads `SMAppService.mainApp.status` on every access so the UI can never drift out of
/// sync with what the system actually has registered (e.g. if the user removes the item in
/// System Settings while the app is running).
protocol LaunchAtLoginControlling {
    /// Whether the app is currently registered to launch at login, read live from the
    /// service status (`.enabled` → `true`). Any other status (`.notRegistered`,
    /// `.requiresApproval`, `.notFound`) reads as `false` — the item will not launch, so
    /// the toggle shows off.
    var isEnabled: Bool { get }

    /// Registers the main app as a login item. Throws if registration fails so the caller
    /// can surface the error and leave the toggle reflecting the true (still-off) status.
    func enable() throws

    /// Unregisters the main app as a login item. Throws if unregistration fails.
    func disable() throws
}

/// Production `LaunchAtLoginControlling`: registers/unregisters the app itself via
/// `SMAppService.mainApp` (TECHSPEC §5). No helper target, no embedded login-item
/// executable — the main app *is* the registered service.
///
/// `isEnabled` maps `SMAppService.mainApp.status` to a bool on every read: `.enabled`
/// means the login item is active; every other case (not registered, awaiting the user's
/// approval in System Settings, or not found) means it will not launch, so the toggle
/// reads off. This keeps the UI honest even when registration state changes outside the
/// app (System Settings > General > Login Items).
struct SMAppServiceLaunchAtLogin: LaunchAtLoginControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func enable() throws {
        try SMAppService.mainApp.register()
    }

    func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
