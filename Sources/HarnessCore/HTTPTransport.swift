// What HTTPServer reads from and writes to: one accepted connection.
//
// Two transports sit behind the same three calls. Network.framework serves
// the local engine on loopback TCP exactly as before. POSIX sockets serve
// what Network cannot: unix sockets for the remote engine
// (docs/plans/2026-10-16-bot-remoto.md §3.1) and, on Linux, everything.
import Dispatch
import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public protocol HTTPConnection: AnyObject {
    /// At least one byte, or `complete` when the peer hung up. One call per delivery.
    func receive(maximumLength: Int, _ completion: @escaping (Data?, _ complete: Bool, Error?) -> Void)
    func send(_ data: Data, _ completion: @escaping (Error?) -> Void)
    func cancel()
}

#if canImport(Network)
final class NWHTTPConnection: HTTPConnection {
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func receive(maximumLength: Int, _ completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, complete, error in
            completion(data, complete, error)
        }
    }

    func send(_ data: Data, _ completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func cancel() { connection.cancel() }
}
#endif

struct SocketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func posix(_ what: String) -> SocketError {
        SocketError(message: "\(what): \(String(cString: strerror(errno)))")
    }
}

/// One accepted POSIX socket. Reads are driven by a read source on the
/// server queue (readable, so `read` never blocks); writes run on the
/// connection's own queue, so a slow client stalls only itself.
final class POSIXHTTPConnection: HTTPConnection, @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let writes: DispatchQueue
    // touched only on `queue`
    private var source: DispatchSourceRead?
    private var suspended = true // a new source starts suspended
    private var pending: ((Data?, Bool, Error?) -> Void)?
    private var maximum = 65536
    // read from both queues
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        writes = DispatchQueue(label: "swarme.http.write")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { close(fd) }
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func receive(maximumLength: Int, _ completion: @escaping (Data?, Bool, Error?) -> Void) {
        queue.async { [self] in
            guard !isClosed, let source else { completion(nil, true, nil); return }
            pending = completion
            maximum = maximumLength
            if suspended { suspended = false; source.resume() }
        }
    }

    private func readable() {
        guard let completion = pending else {
            // nobody is waiting: stop reading until someone asks
            if !suspended { suspended = true; source?.suspend() }
            return
        }
        var buffer = [UInt8](repeating: 0, count: maximum)
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        pending = nil
        // the next receive arrives asynchronously: pause until then
        if !suspended { suspended = true; source?.suspend() }
        if count <= 0 {
            completion(nil, true, count < 0 ? SocketError.posix("read") : nil)
        } else {
            completion(Data(buffer[0..<count]), false, nil)
        }
    }

    func send(_ data: Data, _ completion: @escaping (Error?) -> Void) {
        writes.async { [self] in
            guard !isClosed else { completion(SocketError(message: "closed")); return }
            var error: Error?
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    #if canImport(Glibc) || canImport(Musl)
                    let written = Foundation.send(fd, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                    #else
                    let written = write(fd, base + offset, raw.count - offset)
                    #endif
                    if written < 0 {
                        if errno == EINTR { continue }
                        error = SocketError.posix("write")
                        return
                    }
                    offset += written
                }
            }
            completion(error)
        }
    }

    func cancel() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        // after any write already queued, so a response is never cut short
        writes.async { [self] in
            queue.async { [self] in
                shutdown(fd, Int32(SHUT_RDWR))
                if let source {
                    // a suspended source never runs its cancel handler
                    if suspended { suspended = false; source.resume() }
                    source.cancel()
                }
                source = nil
                if let pending { self.pending = nil; pending(nil, true, nil) }
            }
        }
    }
}

/// A listening POSIX socket: unix (`path`) or TCP on IPv4 loopback.
final class POSIXListener: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    let port: UInt16?
    private let path: String?

    private init(fd: Int32, port: UInt16?, path: String?, queue: DispatchQueue, accept: @escaping (Int32) -> Void) {
        self.fd = fd
        self.port = port
        self.path = path
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = Foundation.accept(fd, nil, nil)
                if client < 0 { return }
                POSIXListener.prepare(client)
                accept(client)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    static func prepare(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // the listener is non-blocking for its accept loop; clients are not
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    }

    private static func nonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// A unix socket at `path` with `mode`; a stale socket file there is replaced.
    static func unix(path: String, mode: mode_t, queue: DispatchQueue, accept: @escaping (Int32) -> Void) throws -> POSIXListener {
        var address = sockaddr_un()
        let limit = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < limit else { throw SocketError(message: "socket path longer than \(limit - 1) bytes: \(path)") }
        #if canImport(Glibc) || canImport(Musl)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SocketError.posix("socket") }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8) + [0])
        }
        // only a socket may be replaced, never a regular file someone put there
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                close(fd)
                throw SocketError(message: "\(path) exists and is not a socket")
            }
            unlink(path)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let error = SocketError.posix("bind \(path)"); close(fd); throw error }
        guard chmod(path, mode) == 0 else { let error = SocketError.posix("chmod \(path)"); close(fd); throw error }
        guard listen(fd, 128) == 0 else { let error = SocketError.posix("listen"); close(fd); throw error }
        nonBlocking(fd)
        return POSIXListener(fd: fd, port: nil, path: path, queue: queue, accept: accept)
    }

    /// TCP on 127.0.0.1; port 0 picks a free one (read it back from `port`).
    static func loopback(port: UInt16, queue: DispatchQueue, accept: @escaping (Int32) -> Void) throws -> POSIXListener {
        #if canImport(Glibc) || canImport(Musl)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SocketError.posix("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let error = SocketError.posix("bind 127.0.0.1:\(port)"); close(fd); throw error }
        guard listen(fd, 128) == 0 else { let error = SocketError.posix("listen"); close(fd); throw error }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        nonBlocking(fd)
        return POSIXListener(fd: fd, port: UInt16(bigEndian: actual.sin_port), path: nil, queue: queue, accept: accept)
    }

    func stop() {
        source.cancel()
        if let path { unlink(path) }
    }
}
