@testable import SwarmeKit
import XCTest

/// The pre-engine backup must survive what remote servers leave in ~/.swarmebot.
final class BackupCopyTests: XCTestCase {
    func testSocketsAndSSHIdentitiesAreLeftOut() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/sbk-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("data"), target = root.appendingPathComponent("backup")
        try fm.createDirectory(at: source.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("ssh/cm"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("bots.json"))
        try Data("img".utf8).write(to: source.appendingPathComponent("attachments/a.png"))
        try Data("key".utf8).write(to: source.appendingPathComponent("ssh/id_ed25519"))
        // a live unix socket, as ssh's ControlMaster or a permission broker leaves
        let socketPath = source.appendingPathComponent("attachments/broker.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound, 0)

        try HarnessEngine.copyEngineData(from: source, to: target)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("bots.json").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("attachments/a.png").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("attachments/broker.sock").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("ssh").path))
    }
}
