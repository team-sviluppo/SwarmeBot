// The app's look: dark (the default), light, or whatever macOS is set to,
// chosen in Settings and kept across launches.
import Foundation
import Observation

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case system

    public var id: String { rawValue }
}

@MainActor
@Observable
public final class AppearanceSettings {
    public static let shared = AppearanceSettings()
    nonisolated static let defaultsKey = "appAppearance"

    public var appearance: AppAppearance {
        didSet { AppPaths.defaults.set(appearance.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        appearance = AppPaths.defaults.string(forKey: Self.defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .dark
    }
}
