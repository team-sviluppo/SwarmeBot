// The terminal app the user picked (Impostazioni › Generale): where "Apri terminale",
// a server's ssh shell and "Continua nel terminale" open. What is installed, and the
// launching itself, are the app's (AppKit); this is what each terminal needs.
import Foundation

public enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal, iterm, ghostty, warp, wezterm, kitty

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .wezterm: return "WezTerm"
        case .kitty: return "Kitty"
        }
    }

    /// For `NSWorkspace.urlForApplication(withBundleIdentifier:)`: only the installed ones are offered.
    public var bundleId: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        case .wezterm: return "com.github.wez.wezterm"
        case .kitty: return "net.kovidgoyal.kitty"
        }
    }

    /// How to hand a terminal an executable script file.
    public enum Launch: Equatable, Sendable {
        /// Open the file with the app, as Finder does with a `.command` file.
        case openFile
        /// Start a new instance of the app with these arguments (`open -n -a … --args`).
        case newInstance(arguments: [String])
    }

    public func launch(script: String) -> Launch {
        switch self {
        case .terminal, .iterm, .warp: return .openFile
        case .ghostty: return .newInstance(arguments: ["-e", script])
        case .wezterm: return .newInstance(arguments: ["start", "--", script])
        case .kitty: return .newInstance(arguments: [script])
        }
    }

    public static let defaultsKey = "terminalApp"

    /// The choice, Terminal when none was made.
    public static var selected: TerminalApp {
        get { AppPaths.defaults.string(forKey: defaultsKey).flatMap(TerminalApp.init(rawValue:)) ?? .terminal }
        set { AppPaths.defaults.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
