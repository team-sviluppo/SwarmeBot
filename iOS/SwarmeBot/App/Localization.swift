// The iOS app's half of localization: where the language choice is kept,
// `tr`, dates. Languages and tables are SwarmeL10n, shared with the Mac app
// (SwarmeKit/Localization.swift works the same way).
//
// The first launch follows the phone's language (Italian if it comes first
// among the preferred ones, English otherwise); after that it is the choice
// made in Impostazioni.
import Foundation
import Observation
@_exported import SwarmeL10n

@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()
    nonisolated static let defaultsKey = "appLanguage"

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        language = Self.current
    }

    /// Read without registering an observation: for code off the main actor.
    nonisolated static var current: AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) { return saved }
        return Locale.preferredLanguages.first?.hasPrefix("it") == true ? .italian : .english
    }
}

/// The UI string `italian` in the app's language. `%@` placeholders are
/// filled in order with `args` (`tr("Eliminare %@?", bot.name)`).
func tr(_ italian: String, _ args: String...) -> String {
    translate(italian, to: currentLanguage(), args)
}

/// Observed when read on the main thread, so a view that reads it redraws.
func currentLanguage() -> AppLanguage {
    guard Thread.isMainThread else { return Localizer.current }
    return MainActor.assumeIsolated { Localizer.shared.language }
}

extension Date {
    /// Any date style in the app's language.
    func appFormatted(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(currentLanguage().locale))
    }

    /// "2 hours ago" in the app's language.
    func appRelative() -> String {
        formatted(Date.RelativeFormatStyle(presentation: .named).locale(currentLanguage().locale))
    }
}
