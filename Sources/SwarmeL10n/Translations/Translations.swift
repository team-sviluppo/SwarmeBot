// Italian UI string → English, for `tr` (Localization.swift). One file per
// area of the app, merged here. A key missing from every part shows in
// Italian; LocalizationTests fails on any `tr` literal without an entry.
public enum Translations {
    public static let english: [String: String] = {
        var all: [String: String] = [:]
        var parts = [chat, settings, remote, engine, skills, vault, transfer, ios, code, plugins]
        #if SWARMEBOT_PRIVATE_PLUGINS
        parts += privatePlugins
        #endif
        for part in parts {
            all.merge(part) { first, _ in first }
        }
        return all
    }()
}
