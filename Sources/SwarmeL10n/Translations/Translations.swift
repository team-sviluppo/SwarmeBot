// Italian UI string → English, for `tr` (Localization.swift). One file per
// area of the app, merged here. A key missing from every part shows in
// Italian; LocalizationTests fails on any `tr` literal without an entry.
public enum Translations {
    public static let english: [String: String] = {
        var all: [String: String] = [:]
        for part in [chat, settings, remote, engine, skills, vault, ios] {
            all.merge(part) { first, _ in first }
        }
        return all
    }()
}
