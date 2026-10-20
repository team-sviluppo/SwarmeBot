// The app's language: English (the default) or Italian, chosen in Settings
// and kept across launches.
//
// Not Apple's string tables: the app also runs from `swift run`, where an
// executable's Localizable tables are not found, and the language is the
// user's choice inside the app, not macOS's. Strings stay in Italian in the
// code (the project's convention) and are the keys; `tr` returns them as
// they are in Italian and looks them up in `Translations.english` otherwise.
// `tr` reads `Localizer.shared.language`, an observable property, so every
// view that shows a translated string redraws when the language changes.
import Foundation
import Observation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case italian = "it"

    public var id: String { rawValue }

    /// Each language's name in itself, as language pickers show them.
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italiano"
        }
    }

    /// The language with this Mac's region: English on an Italian Mac keeps
    /// the 24-hour clock and day-month order the user is used to.
    public var locale: Locale {
        var components = Locale.Components(languageCode: Locale.LanguageCode(rawValue), languageRegion: Locale.current.region)
        components.hourCycle = Locale.current.hourCycle
        return Locale(components: components)
    }
}

@MainActor
@Observable
public final class Localizer {
    public static let shared = Localizer()
    nonisolated static let defaultsKey = "appLanguage"

    public var language: AppLanguage {
        didSet { AppPaths.defaults.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        language = AppPaths.defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// Read without registering an observation: for code off the main actor.
    nonisolated static var current: AppLanguage {
        AppPaths.defaults.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

/// The UI string `italian` in the app's language. `%@` placeholders are
/// filled in order with `args` (`tr("Eliminare %@?", bot.name)`).
public func tr(_ italian: String, _ args: String...) -> String {
    translate(italian, to: currentLanguage(), args)
}

/// The app's language, observed when read on the main thread (so a view
/// that reads it redraws on a change), read from the defaults elsewhere.
func currentLanguage() -> AppLanguage {
    MainActor.assumeIsolatedIfPossible { Localizer.shared.language } ?? Localizer.current
}

/// The same lookup for a given language, for tests and previews.
public func translate(_ italian: String, to language: AppLanguage, _ args: [String] = []) -> String {
    let template = language == .italian ? italian : (Translations.english[italian] ?? italian)
    guard !args.isEmpty else { return template }
    var out = ""
    var rest = Substring(template)
    var index = 0
    while let range = rest.range(of: "%@") {
        out += rest[..<range.lowerBound]
        out += index < args.count ? args[index] : ""
        index += 1
        rest = rest[range.upperBound...]
    }
    return out + rest
}

extension MainActor {
    /// The body's value on the main thread, nil elsewhere (where reading an
    /// observable would trap or race).
    static func assumeIsolatedIfPossible<T: Sendable>(_ body: @MainActor () -> T) -> T? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated(body)
    }
}

extension Date {
    /// `formatted(date:time:)` in the app's language rather than macOS's.
    public func appFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(currentLanguage().locale))
    }

    /// Any date style in the app's language.
    public func appFormatted(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(currentLanguage().locale))
    }

    /// "2 hours ago" in the app's language.
    public func appRelative() -> String {
        formatted(Date.RelativeFormatStyle(presentation: .named).locale(currentLanguage().locale))
    }
}
