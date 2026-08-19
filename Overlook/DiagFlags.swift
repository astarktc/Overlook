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
    /// OVERLOOK_DIAG_NO_RENDER_HOP=1 → drop the video render path's main-actor hops (first-frame
    /// signal, fps publish, OCR frame capture). Video itself keeps flowing: the frames go straight
    /// to the display layer and never touch the main actor.
    static let noRenderHop = flag("OVERLOOK_DIAG_NO_RENDER_HOP")
    /// OVERLOOK_DIAG_STALL_MAIN=1 → stall the main thread for 200 ms once a second, from app
    /// start. This is the acceptance test for the video renderer: video must keep playing
    /// smoothly while the main thread is repeatedly blocked.
    static let stallMain = flag("OVERLOOK_DIAG_STALL_MAIN")
}

// [DEBUG-swiftui-audit] The main-thread stall injector behind OVERLOOK_DIAG_STALL_MAIN.
//
// A 1 Hz, 200 ms `Thread.sleep` on the main thread is a brutal but honest stand-in for the
// SwiftUI invalidation storms this audit is about: anything that presents video *on* the main
// thread visibly stutters under it, and anything that does not keeps playing.
@MainActor
enum MainThreadStallInjector {
    private static var timer: Timer?

    /// Installs the repeating stall on the main run loop. Call once, from the main thread.
    static func startIfEnabled() {
        guard DiagFlags.stallMain, timer == nil else { return }

        NSLog("[Overlook] OVERLOOK_DIAG_STALL_MAIN=1: stalling the main thread 200 ms every second")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
