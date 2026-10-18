// The few libc calls whose spelling differs between Darwin and Glibc — the
// Linux build of the remote engine (docs/plans/2026-10-16-bot-remoto.md §3.6).
// Inside a type with its own `write`/`close`, the module name picks libc's.
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum Sys {
    #if canImport(Darwin)
    static let streamSocket = SOCK_STREAM
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
    static func close(_ fd: Int32) { _ = Darwin.close(fd) }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Darwin.connect(fd, address, length) }
    /// A write to a closed peer is an error, not a SIGPIPE that kills the engine.
    static func noSigPipe(_ fd: Int32) { _ = fcntl(fd, F_SETNOSIGPIPE, 1) }
    #elseif canImport(Glibc)
    static let streamSocket = Int32(SOCK_STREAM.rawValue)
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Glibc.write(fd, buffer, count) }
    static func close(_ fd: Int32) { _ = Glibc.close(fd) }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Glibc.connect(fd, address, length) }
    /// No per-descriptor flag here: every entry point ignores SIGPIPE instead (main.swift).
    static func noSigPipe(_ fd: Int32) {}
    #endif
}
