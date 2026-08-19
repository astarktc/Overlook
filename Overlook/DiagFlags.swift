import Foundation

// [DEBUG-swiftui-audit] Temporary instrumentation for the SwiftUI invalidation-storm audit.
// Every flag is read once from the process environment at first access. To remove the whole
// audit, delete this file plus every other line tagged `[DEBUG-swiftui-audit]`.
//
// This lives in its own file (rather than next to `ContentView`) because the producers it
// gates are compiled into both the app and the unit-test target.
enum DiagFlags {
    private static let env = ProcessInfo.processInfo.environment

    private static func flag(_ key: String) -> Bool {
        env[key] == "1"
    }

    /// OVERLOOK_DIAG_PRINT_CHANGES=1 → `Self._printChanges()` at the top of instrumented bodies.
    static let printChanges = flag("OVERLOOK_DIAG_PRINT_CHANGES")
    /// OVERLOOK_DIAG_NO_STATS=1 → disable periodic WebRTC stats/latency publishing.
    static let noStats = flag("OVERLOOK_DIAG_NO_STATS")
    /// OVERLOOK_DIAG_NO_HEALTH=1 → disable stream-health @Published writes.
    static let noHealth = flag("OVERLOOK_DIAG_NO_HEALTH")
    /// OVERLOOK_DIAG_NO_FPS=1 → disable inbound fps publishing from the decode path.
    static let noFps = flag("OVERLOOK_DIAG_NO_FPS")
    /// OVERLOOK_DIAG_NO_WINDOW_SETTERS=1 → neuter the window title/aspect NSViewRepresentables.
    static let noWindowSetters = flag("OVERLOOK_DIAG_NO_WINDOW_SETTERS")
    /// OVERLOOK_DIAG_NO_RENDER_HOP=1 → do not attach ConnectionGenerationVideoRenderer to the track.
    static let noRenderHop = flag("OVERLOOK_DIAG_NO_RENDER_HOP")
}
