import Foundation
import SwiftUI

/// State for `WebUISettingsPanel` that must outlive the view.
///
/// Ticket 03: the settings panel is now conditionally mounted (it is unmounted while closed, so
/// its Picker-heavy body is never evaluated and it costs no layout pass). Everything the panel
/// used to keep in `@State` — loaded device config, keymaps, streamer state, section expansion,
/// in-progress drafts, error history — lives here instead, owned by `ContentView` as a
/// `@StateObject`, so closing and reopening the panel shows the previously loaded content
/// instead of starting from scratch.
///
/// This is storage only: the panel keeps its own load/apply logic and its `@FocusState`
/// (which cannot live in an `ObservableObject`).
@MainActor
final class WebUISettingsPanelModel: ObservableObject {
    struct ErrorEntry: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let message: String
    }

    // Loaded remote state.
    @Published var config: GLKVMSystemConfig?
    @Published var keymaps: GLKVMHidKeymapsState?
    @Published var streamerState: GLKVMStreamerState?

    // In-flight indicators.
    @Published var isLoading = false
    @Published var isApplying = false
    @Published var isApplyingStreamer = false
    @Published var isApplyingEdid = false

    // Errors.
    @Published var errorMessage: String?
    @Published var errorHistory: [ErrorEntry] = []
    @Published var showingErrorHistory: Bool = false

    // Section expansion.
    @Published var isVideoExpanded = true
    @Published var isRemoteExpanded = true
    @Published var isKeyboardExpanded = true
    @Published var isAudioExpanded = false
    @Published var isSystemExpanded = false
    @Published var isNetworkExpanded = false
    @Published var isAdvancedExpanded = false

    // EDID.
    @Published var currentEdid: String = ""
    @Published var selectedEdidOption: String = "CUSTOMIZE"
    @Published var customEdidDraft: String = ""
    @Published var isProgrammaticEdidSelectionUpdate: Bool = false

    // Video quality / codec.
    @Published var selectedVideoQualityPreset: Int = 1
    @Published var codecPreference: CodecPreference = .auto

    // Debounced apply tasks. Deliberately not cancelled when the panel closes: an apply that is
    // already scheduled should still reach the device.
    var applyTask: Task<Void, Never>?
    var applyStreamerTask: Task<Void, Never>?

    // Streamer drafts.
    @Published var isProgrammaticStreamerDraftUpdate: Bool = false
    @Published var streamerDesiredFps: Int = 30
    @Published var streamerQuality: Int = 80
    @Published var streamerH264Bitrate: Int = 2000
    @Published var streamerH264Gop: Int = 30
    @Published var streamerZeroDelay: Bool = false
    @Published var streamerResolution: String = ""

    @Published var streamerDesiredFpsText: String = ""
    @Published var streamerQualityText: String = ""
    @Published var streamerH264BitrateText: String = ""
    @Published var streamerH264GopText: String = ""

    // Audio device enumeration (cheap, but re-listing on every open flickers the pickers).
    @Published var audioInputDevices: [CoreAudioDeviceInfo] = []
    @Published var audioOutputDevices: [CoreAudioDeviceInfo] = []
}
