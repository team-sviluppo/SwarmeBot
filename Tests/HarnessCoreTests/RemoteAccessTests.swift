@testable import HarnessCore
import XCTest

// The remote engine's front door (docs/plans/2026-10-16-bot-remoto.md §3–§4, §12).

/// `remoteRequest("/path")` is a GET; `remoteRequest("POST", "/path")` names the method.
func remoteRequest(_ first: String, _ second: String? = nil, headers: [String: String] = [:], body: String = "") -> HTTPRequest {
    let (method, path) = second.map { (first, $0) } ?? ("GET", first)
    return HTTPRequest(method: method, path: path, query: [:], headers: headers, body: Data(body.utf8))
}

func temporaryPaths() -> DataPaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sbr-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let paths = DataPaths(root: root)
    paths.ensure()
    return paths
}

@MainActor
final class DeviceRegistryTests: XCTestCase {
    func testTokensAreStoredOnlyAsHashes() throws {
        let paths = temporaryPaths()
        let registry = DeviceRegistry(paths: paths)
        let added = try registry.add(name: "  Mac di prova  ", kind: "mac")
        XCTAssertEqual(added.device["name"]?.string, "Mac di prova")
        XCTAssertGreaterThanOrEqual(added.token.count, 40)
        let disk = try String(contentsOf: registry.file, encoding: .utf8)
        XCTAssertFalse(disk.contains(added.token))
        XCTAssertTrue(disk.contains(DeviceRegistry.hash(added.token)))
        let mode = try FileManager.default.attributesOfItem(atPath: registry.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertNil(DeviceRegistry.wire(added.device)["tokenHash"])
    }

    func testAuthenticateAndRevoke() throws {
        let registry = DeviceRegistry(paths: temporaryPaths())
        let a = try registry.add(name: "A", kind: "mac")
        let b = try registry.add(name: "B", kind: "weird")
        XCTAssertEqual(b.device["kind"]?.string, "other")
        XCTAssertEqual(registry.authenticate(a.token), a.device["id"]?.string)
        XCTAssertNil(registry.authenticate("nope"))
        XCTAssertNil(registry.authenticate(""))
        XCTAssertTrue(try registry.revoke(a.device["id"]!.string!))
        XCTAssertFalse(try registry.revoke(a.device["id"]!.string!))
        XCTAssertNil(registry.authenticate(a.token))
        XCTAssertEqual(registry.authenticate(b.token), b.device["id"]?.string)
        XCTAssertEqual(registry.list().count, 1)
        XCTAssertEqual(registry.list(includeRevoked: true).count, 2)
    }

    func testAnotherProcessWritingTheFileIsSeen() throws {
        let paths = temporaryPaths()
        let engine = DeviceRegistry(paths: paths)
        XCTAssertTrue(engine.list().isEmpty)
        // `swarme-harness device add` over ssh while the engine runs
        let added = try DeviceRegistry(paths: paths).add(name: "via ssh", kind: "mac")
        XCTAssertEqual(engine.authenticate(added.token), added.device["id"]?.string)
    }

    func testNameIsRequired() {
        XCTAssertThrowsError(try DeviceRegistry(paths: temporaryPaths()).add(name: "   ", kind: nil))
    }
}

final class PairingAndLimiterTests: XCTestCase {
    func testCodesAreSingleUseAndExpire() {
        var codes = PairingCodes()
        let issued = codes.issue(now: 1_000)
        XCTAssertEqual(issued.code.count, 10)
        XCTAssertEqual(issued.expiresAt, 1_000 + PairingCodes.lifetime)
        XCTAssertTrue(codes.redeem(issued.code.lowercased(), now: 2_000))
        XCTAssertFalse(codes.redeem(issued.code, now: 2_000))
        let late = codes.issue(now: 0)
        XCTAssertFalse(codes.redeem(late.code, now: PairingCodes.lifetime + 1))
        XCTAssertFalse(codes.redeem("", now: 0))
    }

    func testOnlyAFewCodesStayOpen() {
        var codes = PairingCodes()
        let first = codes.issue(now: 0)
        for index in 1...PairingCodes.maxOpen { _ = codes.issue(now: Double(index)) }
        XCTAssertFalse(codes.redeem(first.code, now: 10))
    }

    func testTenFailuresInAMinuteBlockForFive() {
        var limiter = FailureLimiter()
        for index in 0..<9 { limiter.fail("1.2.3.4", now: Double(index)) }
        XCTAssertFalse(limiter.isBlocked("1.2.3.4", now: 10))
        limiter.fail("1.2.3.4", now: 10)
        XCTAssertTrue(limiter.isBlocked("1.2.3.4", now: 11))
        XCTAssertFalse(limiter.isBlocked("5.6.7.8", now: 11))
        XCTAssertFalse(limiter.isBlocked("1.2.3.4", now: 10 + FailureLimiter.penalty + 1))
        // spread out, failures never add up
        var slow = FailureLimiter()
        for index in 0..<30 { slow.fail("x", now: Double(index) * 10_000) }
        XCTAssertFalse(slow.isBlocked("x", now: 300_000))
    }
}

@MainActor
final class RemoteGateTests: XCTestCase {
    func makeAccess() throws -> (RemoteAccess, String) {
        let access = RemoteAccess(paths: temporaryPaths(), publicURL: "https://bot.example.it/srv1/me")
        let token = try access.devices.add(name: "Mac", kind: "mac").token
        return (access, token)
    }

    func refusal(_ result: RouteResult?) -> Int? {
        guard case let .response(response)? = result else { return nil }
        return response.status
    }

    func testEveryRouteNeedsAToken() throws {
        let (access, token) = try makeAccess()
        var request = remoteRequest("/api/bots")
        XCTAssertEqual(refusal(access.gate(&request)), 401)
        request = remoteRequest("/api/bots", headers: ["authorization": "Bearer wrong"])
        XCTAssertEqual(refusal(access.gate(&request)), 401)
        request = remoteRequest("/api/bots", headers: ["authorization": "Bearer \(token)", "host": "bot.example.it"])
        XCTAssertNil(access.gate(&request))
        XCTAssertNotNil(request.deviceId)
    }

    func testHealthAndClaimAreOpenButNothingElse() throws {
        let (access, _) = try makeAccess()
        var health = remoteRequest("/api/health")
        XCTAssertNil(access.gate(&health))
        var claim = remoteRequest("POST", "/api/devices/claim")
        XCTAssertNil(access.gate(&claim))
        var pairing = remoteRequest("POST", "/api/devices/pairing")
        XCTAssertEqual(refusal(access.gate(&pairing)), 401)
        var claimByGet = remoteRequest("GET", "/api/devices/claim")
        XCTAssertEqual(refusal(access.gate(&claimByGet)), 401)
    }

    func testInternalRoutesDoNotExistHereEvenWithAToken() throws {
        let (access, token) = try makeAccess()
        var request = remoteRequest("/api/internal/agents", headers: ["authorization": "Bearer \(token)"])
        XCTAssertEqual(refusal(access.gate(&request)), 404)
    }

    func testOriginIsRefusedAndComputerRoutesAreLocalOnly() throws {
        let (access, token) = try makeAccess()
        var browser = remoteRequest("/api/bots", headers: ["authorization": "Bearer \(token)", "origin": "https://bot.example.it"])
        XCTAssertEqual(refusal(access.gate(&browser)), 403)
        // the device tokens of other engines are handed over by the Mac only (MixedRooms.swift)
        for path in ["/api/local-computer", "/api/local-computer/start", "/api/bots/abc/computer", "/api/bots/abc/computer/control",
                     "/api/peer-engines"] {
            var request = remoteRequest(path, headers: ["authorization": "Bearer \(token)"])
            XCTAssertEqual(refusal(access.gate(&request)), 501, path)
        }
        var computers = remoteRequest("/api/bots/abc/computerish", headers: ["authorization": "Bearer \(token)"])
        XCTAssertNil(access.gate(&computers))
    }

    func testRepeatedFailuresAreSlowedDownPerForwardedClient() throws {
        let (access, token) = try makeAccess()
        for _ in 0..<FailureLimiter.maxFailures {
            var bad = remoteRequest("/api/bots", headers: ["x-forwarded-for": "9.9.9.9, 10.0.0.1"])
            _ = access.gate(&bad)
        }
        var blocked = remoteRequest("/api/bots", headers: ["x-forwarded-for": "9.9.9.9", "authorization": "Bearer \(token)"])
        XCTAssertEqual(refusal(access.gate(&blocked)), 429)
        var other = remoteRequest("/api/bots", headers: ["x-forwarded-for": "8.8.8.8", "authorization": "Bearer \(token)"])
        XCTAssertNil(access.gate(&other))
    }

    func testPairingClaimListAndRevoke() throws {
        let (access, token) = try makeAccess()
        var me = remoteRequest("POST", "/api/devices/pairing", headers: ["authorization": "Bearer \(token)"])
        XCTAssertNil(access.gate(&me))
        guard case let .response(issued)? = access.route(me) else { return XCTFail("no pairing answer") }
        XCTAssertEqual(issued.status, 201)
        let pairing = try JSON.parse(issued.body)
        XCTAssertEqual(pairing["chatUrl"]?.string, "https://bot.example.it/srv1/me")
        let code = pairing["code"]!.string!

        let claim = remoteRequest("POST", "/api/devices/claim", headers: ["content-type": "application/json"],
                                  body: #"{"code":"\#(code)","name":"iPhone","kind":"ios"}"#)
        guard case let .response(claimed)? = access.route(claim) else { return XCTFail("no claim answer") }
        XCTAssertEqual(claimed.status, 201)
        let phone = try JSON.parse(claimed.body)
        let phoneToken = phone["token"]!.string!
        let phoneId = phone["device"]!["id"]!.string!
        XCTAssertNil(phone["device"]?["tokenHash"])
        guard case let .response(again)? = access.route(claim) else { return XCTFail() }
        XCTAssertEqual(again.status, 401)

        var revoked: String?
        access.onRevoke = { revoked = $0 }
        var delete = remoteRequest("DELETE", "/api/devices/\(phoneId)", headers: ["authorization": "Bearer \(token)"])
        XCTAssertNil(access.gate(&delete))
        guard case let .response(deleted)? = access.route(delete) else { return XCTFail() }
        XCTAssertEqual(deleted.status, 200)
        XCTAssertEqual(revoked, phoneId)
        var asPhone = remoteRequest("/api/bots", headers: ["authorization": "Bearer \(phoneToken)"])
        XCTAssertEqual(refusal(access.gate(&asPhone)), 401)

        var list = remoteRequest("/api/devices", headers: ["authorization": "Bearer \(token)"])
        XCTAssertNil(access.gate(&list))
        guard case let .response(listed)? = access.route(list) else { return XCTFail() }
        let devices = try JSON.parse(listed.body)
        XCTAssertEqual(devices["devices"]?.array?.count, 1)
        XCTAssertEqual(devices["current"]?.string, list.deviceId)
    }

    func testHealthSaysRemoteWithoutLeakingThePid() throws {
        let (access, _) = try makeAccess()
        guard case let .response(health)? = access.route(remoteRequest("/api/health")) else { return XCTFail() }
        let body = try JSON.parse(health.body)
        XCTAssertEqual(body["remote"]?.bool, true)
        XCTAssertEqual(body["contract"]?.double, Double(RemoteContract.version))
        XCTAssertNil(body["pid"])
        XCTAssertNil(access.route(remoteRequest("/api/bots")))
    }
}

/// The POSIX transport end to end: a real unix socket, raw HTTP on it.
/// Reads block, and the server answers on the main actor: never read on main.
final class UnixSocketServerTests: XCTestCase {
    func exchange(_ path: String, _ raw: String) async throws -> String {
        try await Task.detached { try Self.blockingExchange(path, raw) }.value
    }

    static func blockingExchange(_ path: String, _ raw: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(message: "socket") }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw SocketError(message: "connect") }
        _ = raw.withCString { write(fd, $0, strlen($0)) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            out.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: out, as: UTF8.self)
    }

    func testRequestsOverAUnixSocketWithAGate() async throws {
        let path = "/tmp/sbr-test-\(UUID().uuidString.prefix(6)).sock"
        let server = HTTPServer(gate: { request in
            request.header("authorization") == "Bearer ok" ? nil : .response(.error(401, "unauthorized"))
        }) { request in
            .response(.json(200, ["path": .string(request.path), "body": .string(String(decoding: request.body, as: UTF8.self))]))
        }
        try server.start(unixSocket: path, mode: 0o660)
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o660)

        let refused = try await exchange(path, "GET /api/x HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 401"), refused)

        let ok = try await exchange(path, "POST /api/y HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer ok\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        XCTAssertTrue(ok.contains(#""path":"\/api\/y""#) || ok.contains(#""path":"/api/y""#), ok)
        XCTAssertTrue(ok.contains("hello"))

        // two requests on one keep-alive connection
        let both = try await exchange(path, "GET /a HTTP/1.1\r\nAuthorization: Bearer ok\r\n\r\nGET /b HTTP/1.1\r\nAuthorization: Bearer ok\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(both.components(separatedBy: "HTTP/1.1 200").count - 1, 2, both)
    }

    func testAStaleSocketIsReplacedButARegularFileIsNot() async throws {
        let path = "/tmp/sbr-test-\(UUID().uuidString.prefix(6)).sock"
        let first = HTTPServer(gate: { _ in nil }) { _ in .response(.json(200, [:])) }
        try first.start(unixSocket: path, mode: 0o600)
        // a crash leaves the file behind; the next start takes it over
        let second = HTTPServer(gate: { _ in nil }) { _ in .response(.json(200, ["second": true])) }
        try second.start(unixSocket: path, mode: 0o600)
        let answer = try await exchange(path, "GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(answer.contains("second"), answer)
        second.stop()
        first.stop()

        let file = "/tmp/sbr-test-\(UUID().uuidString.prefix(6)).txt"
        FileManager.default.createFile(atPath: file, contents: Data("keep me".utf8))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let third = HTTPServer(gate: { _ in nil }) { _ in .response(.json(200, [:])) }
        XCTAssertThrowsError(try third.start(unixSocket: file, mode: 0o600))
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "keep me")
    }

    func testLoopbackPicksAFreePort() throws {
        let server = HTTPServer { _ in .response(.json(200, ["ok": true])) }
        let port = try server.startLoopback(port: 0)
        defer { server.stop() }
        XCTAssertGreaterThan(port, 0)
        let done = expectation(description: "loopback answer")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/x")!) { data, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data.flatMap { try? JSON.parse($0) }?["ok"]?.bool, true)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
    }
}

@MainActor
final class RemoteRoutineTests: XCTestCase {
    func testTheScheduleZoneWinsOverTheMachineClock() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = TimeZone(identifier: "Europe/Rome")!
        func romeMillis(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Double {
            rome.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970 * 1000
        }
        let schedule = try RoutineManager.cleanSchedule(["type": "daily", "time": "09:00", "weekdays": [0, 1, 2, 3, 4, 5, 6], "timeZone": "Europe/Rome"])
        XCTAssertEqual(schedule["timeZone"]?.string, "Europe/Rome")
        // a server on UTC: 9:00 in Rome, not 9:00 UTC
        XCTAssertEqual(RoutineManager.nextOccurrence(schedule, after: romeMillis(2026, 10, 20, 8, 0), calendar: utc), romeMillis(2026, 10, 20, 9, 0))
        // across the end of daylight saving time (25 Oct 2026): still 9:00 in Rome
        XCTAssertEqual(RoutineManager.nextOccurrence(schedule, after: romeMillis(2026, 10, 24, 10, 0), calendar: utc), romeMillis(2026, 10, 25, 9, 0))
        XCTAssertEqual(RoutineManager.nextOccurrence(schedule, after: romeMillis(2026, 10, 25, 10, 0), calendar: utc), romeMillis(2026, 10, 26, 9, 0))
    }

    func testZoneIsOptionalAndValidated() throws {
        let plain = try RoutineManager.cleanSchedule(["type": "daily", "time": "09:00"])
        XCTAssertNil(plain["timeZone"])
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "daily", "time": "09:00", "timeZone": "Mars/Olympus"]))
    }
}
