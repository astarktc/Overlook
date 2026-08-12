import Foundation

/// Persists a Codec Preference independently for each KVM device id.
public struct CodecPreferenceStore {
    private static let keyPrefix = "overlook.codecPreference.v1."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func preference(forDeviceID deviceID: String) -> CodecPreference {
        guard let storedValue = defaults.string(forKey: key(forDeviceID: deviceID)) else {
            return .auto
        }
        return CodecPreference(rawValue: storedValue) ?? .auto
    }

    public func save(_ preference: CodecPreference, forDeviceID deviceID: String) {
        defaults.set(preference.rawValue, forKey: key(forDeviceID: deviceID))
    }

    private func key(forDeviceID deviceID: String) -> String {
        Self.keyPrefix + deviceID
    }
}
