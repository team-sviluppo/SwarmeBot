// Updates through Sparkle 2: an appcast on the releases repo, archives
// signed with EdDSA. The updater runs only in a packaged app whose
// Info.plist carries a public key — a dev build or an unsigned bundle has
// nothing it could verify an update against, so it never starts one.
import Foundation
import Sparkle

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    @Published private(set) var available = false
    @Published var automaticChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    private init() {
        let bundle = Bundle.main
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard bundle.bundleURL.pathExtension == "app", !key.isEmpty,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        available = true
        automaticChecks = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }
}
