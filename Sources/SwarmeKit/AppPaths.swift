// Where the app keeps its things, and a way to keep them elsewhere.
//
// `SWARMEBOT_HOME=/some/folder` makes the app use that folder in place of the
// home directory for everything it owns (~/.swarmebot, Application Support,
// Logs, the ssh identities), its own preferences and no Keychain (device
// tokens go to a 0600 file there, RemoteEngines.swift), so a
// development build can run on test data without touching the real ones.
// On macOS `HOME` does not do this: Foundation reads the home from the
// user database, not from the environment.
import Foundation

public enum AppPaths {
    static let override: URL? = ProcessInfo.processInfo.environment["SWARMEBOT_HOME"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

    /// The home the app's own paths hang from.
    public static var home: URL { override ?? FileManager.default.homeDirectoryForCurrentUser }

    /// True while running on test data.
    public static var isIsolated: Bool { override != nil }

    /// The app's preferences: a suite of their own on test data.
    public static var defaults: UserDefaults {
        isIsolated ? (UserDefaults(suiteName: "com.swarmebot.mac.isolated") ?? .standard) : .standard
    }

    /// Appended to every Keychain service name: test tokens never mix with real ones.
    static var keychainSuffix: String { isIsolated ? ".isolated" : "" }
}
