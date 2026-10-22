// The app's languages and the lookup behind `tr`, shared by the Mac app
// (SwarmeKit/Localization.swift) and the iOS app: strings stay in Italian in
// the code and are the keys; English comes from `Translations.english`.
// Where the choice is kept, and `tr` itself, belong to each app.
import Foundation

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

    /// The language with this device's region: English on an Italian Mac or
    /// iPhone keeps the 24-hour clock and day-month order the user is used to.
    public var locale: Locale {
        var components = Locale.Components(languageCode: Locale.LanguageCode(rawValue), languageRegion: Locale.current.region)
        components.hourCycle = Locale.current.hourCycle
        return Locale(components: components)
    }
}

/// The UI string `italian` in `language`; `%@` placeholders are filled in
/// order with `args`. Each app's `tr` calls this with its chosen language.
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
