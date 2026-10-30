import Foundation

extension Bundle {
    /// The target's resources. SwiftPM's `Bundle.module` only looks next to
    /// the .app (where codesign refuses unsealed content) and in the build
    /// directory, and traps when neither exists; the packaged app keeps the
    /// bundle in Contents/Resources, so look there first.
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("SwarmeBot_SwarmeBotUI.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
