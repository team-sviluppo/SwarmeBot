@testable import SwarmeKit
import XCTest

/// Every UI string goes through `tr` and has an English entry.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let folders = ["Sources/SwarmeBot", "Sources/SwarmeKit", "iOS/SwarmeBot"]

    private func sources() throws -> [(path: String, lines: [String])] {
        var out: [(String, [String])] = []
        for folder in Self.folders {
            let base = Self.root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.contains("/Translations/") } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                out.append((file.path.replacingOccurrences(of: Self.root.path + "/", with: ""), text.components(separatedBy: "\n")))
            }
        }
        return out
    }

    /// A line's string literals with their start offsets, comments skipped.
    private func literals(_ line: String) -> [(text: String, prefix: Substring)] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return [] }
        var out: [(String, Substring)] = []
        let regex = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let ns = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: match.range.location)
            if before.contains("//") { continue } // trailing comment
            out.append((ns.substring(with: match.range(at: 1)), Substring(before)))
        }
        return out
    }

    func testTranslateFillsPlaceholdersInOrder() {
        XCTAssertEqual(translate("A %@ e %@", to: .italian, ["1", "2"]), "A 1 e 2")
        XCTAssertEqual(translate("chiave assente", to: .english), "chiave assente", "a missing entry shows the Italian")
    }

    func testEveryTrLiteralHasAnEnglishEntry() throws {
        var missing: [String] = []
        for (path, lines) in try sources() {
            for (number, line) in lines.enumerated() {
                for literal in literals(line) where literal.prefix.hasSuffix("tr(") {
                    let key = literal.text.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
                    if Translations.english[key] == nil { missing.append("\(path):\(number + 1) \(literal.text)") }
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "no English for:\n" + missing.joined(separator: "\n"))
    }

    /// Literals handed straight to a SwiftUI title would be looked up in the
    /// bundle's (absent) tables and show as typed: they must go through `tr`,
    /// or be `verbatim:` when they are not words to translate.
    func testNoBareLiteralTitles() throws {
        let call = #"(?:\b(?:Text|Button|Label|Toggle|TextField|SecureField|Section|Menu|Picker|Stepper|LabeledContent|Link|GroupBox|DisclosureGroup|ContentUnavailableView|Tab)|\.(?:help|navigationTitle|alert|confirmationDialog|tabItem))\(\s*$"#
        let regex = try NSRegularExpression(pattern: call)
        var bare: [String] = []
        for (path, lines) in try sources() {
            for (number, line) in lines.enumerated() {
                for literal in literals(line) where literal.text.range(of: #"[A-Za-zÀ-ÿ]{2,}"#, options: .regularExpression) != nil {
                    let prefix = String(literal.prefix)
                    if regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
                        bare.append("\(path):\(number + 1) \(literal.text)")
                    }
                }
            }
        }
        XCTAssertTrue(bare.isEmpty, "wrap in tr(...) or use verbatim:\n" + bare.joined(separator: "\n"))
    }

    /// Italian outside `tr`: accented letters are the reliable sign.
    func testNoItalianOutsideTr() throws {
        var found: [String] = []
        for (path, lines) in try sources() where !path.hasSuffix("Localization.swift") {
            for (number, line) in lines.enumerated() {
                for literal in literals(line) where literal.text.range(of: "[àèéìòùÀÈ]", options: .regularExpression) != nil {
                    if !literal.prefix.hasSuffix("tr(") { found.append("\(path):\(number + 1) \(literal.text)") }
                }
            }
        }
        XCTAssertTrue(found.isEmpty, "Italian not through tr:\n" + found.joined(separator: "\n"))
    }
}
