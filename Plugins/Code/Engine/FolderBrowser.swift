// The folders of the machine the engine runs on (`GET /api/fs/dirs?path=`), for picking a project's
// folders from a Mac that is not that machine: the open panel only shows the Mac's own.
import Foundation
import HarnessCore

enum FolderBrowser {
    static let limit = 500

    static func list(path requested: String?, hidden: Bool) throws -> HTTPResponse {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = (requested?.isEmpty == false ? requested! : home)
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw HTTPError(400, "path must be absolute") }
        // `..` and symlinks resolved, so what is shown is where the folder is
        let real = ReadOnlyGuard.canonical(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HTTPError(400, "not a folder: \(path)")
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: real) else { throw HTTPError(403, "this folder cannot be read: \(path)") }
        let dirs = names.filter { hidden || !$0.hasPrefix(".") }.filter { name in
            var directory: ObjCBool = false
            // a link to a folder counts as one
            return FileManager.default.fileExists(atPath: (real as NSString).appendingPathComponent(name), isDirectory: &directory) && directory.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var body: JSONObject = ["path": .string(real), "home": .string(home), "dirs": .strings(Array(dirs.prefix(limit))),
                                "truncated": .bool(dirs.count > limit)]
        body["parent"] = real == "/" ? Optional<JSON>.none : .string((real as NSString).deletingLastPathComponent)
        return .json(200, .object(body))
    }
}
