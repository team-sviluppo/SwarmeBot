// "Apri in…": the editors this Mac has, and how each opens a folder, here or on a server.
import Foundation
import SwarmeKit

enum EditorApp: String, CaseIterable, Identifiable {
    case vscode, cursor, zed, xcode

    var id: String { rawValue }

    var name: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        }
    }

    var bundleId: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .zed: return "dev.zed.Zed"
        case .xcode: return "com.apple.dt.Xcode"
        }
    }

    /// The URL scheme these two answer for a folder on a server over ssh
    /// (Remote - SSH); the others only open a folder on this Mac.
    private var remoteScheme: String? {
        switch self {
        case .vscode: return "vscode"
        case .cursor: return "cursor"
        case .zed, .xcode: return nil
        }
    }

    var opensServerFolders: Bool { remoteScheme != nil }

    /// `vscode://vscode-remote/ssh-remote+user@host/folder`. A port other than 22 goes in
    /// the host the way Remote - SSH reads it: hex of `{"hostName", "user", "port"}`.
    func remoteURL(identity: SSHIdentity, folder: String) -> URL? {
        guard let scheme = remoteScheme else { return nil }
        let host: String
        if identity.port == 22 {
            host = "\(identity.user)@\(identity.host)"
        } else {
            let json = #"{"hostName":"\#(identity.host)","user":"\#(identity.user)","port":\#(identity.port)}"#
            host = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        }
        let path = folder.hasPrefix("/") ? folder : "/" + folder
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "+")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://vscode-remote/ssh-remote+\(host)\(encoded)")
    }
}
