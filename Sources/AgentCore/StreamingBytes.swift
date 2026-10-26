// A streamed HTTP body, on both platforms — bot-remoto §3.6.
//
// `URLSession.bytes(for:)` is what the drivers and the MCP client read SSE
// with; swift-corelibs-foundation (Linux) does not have it. On Apple
// platforms this is exactly `bytes(for:)`; on Linux a delegate session hands
// each chunk on as it arrives, so a stream is read while it flows.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
public typealias StreamingBytes = URLSession.AsyncBytes

extension URLSession {
    public func streamingBytes(for request: URLRequest) async throws -> (StreamingBytes, URLResponse) {
        try await bytes(for: request)
    }
}
#else
public struct StreamingBytes: AsyncSequence, Sendable {
    public typealias Element = UInt8
    let stream: AsyncThrowingStream<UInt8, Error>

    public func makeAsyncIterator() -> AsyncThrowingStream<UInt8, Error>.AsyncIterator { stream.makeAsyncIterator() }

    /// As `AsyncBytes.lines`: split on LF, a CR before it dropped.
    public var lines: AsyncThrowingStream<String, Error> {
        let bytes = stream
        return AsyncThrowingStream { continuation in
            let task = Task {
                var line = [UInt8]()
                do {
                    for try await byte in bytes {
                        if byte == 0x0A {
                            if line.last == 0x0D { line.removeLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One receiver per request, all served by one session that is never torn
/// down. A session of its own per request, invalidated from inside its own
/// delegate callback, deallocated its curl multi handle while that was still
/// referenced ("_MultiHandle deallocated with non-zero retain count") and the
/// engine died a moment later, on an HTTPS MCP server that streams.
final class StreamingReceiver: @unchecked Sendable {
    let continuation: AsyncThrowingStream<UInt8, Error>.Continuation
    private let lock = NSLock()
    private var response: CheckedContinuation<URLResponse, Error>?

    init(continuation: AsyncThrowingStream<UInt8, Error>.Continuation, response: CheckedContinuation<URLResponse, Error>) {
        self.continuation = continuation
        self.response = response
    }

    func answer(_ result: Result<URLResponse, Error>) {
        lock.lock()
        let waiting = response
        response = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamingSession()

    private let lock = NSLock()
    private var receivers: [Int: StreamingReceiver] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    /// Start `request`; the receiver is registered before the task runs.
    func start(_ request: URLRequest, _ receiver: StreamingReceiver) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        receivers[task.taskIdentifier] = receiver
        lock.unlock()
        task.resume()
        return task
    }

    private func receiver(_ task: URLSessionTask) -> StreamingReceiver? {
        lock.lock()
        defer { lock.unlock() }
        return receivers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        receiver(dataTask)?.answer(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let receiver = receiver(dataTask) else { return }
        for byte in data { receiver.continuation.yield(byte) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let receiver = receivers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let receiver else { return }
        if let error {
            receiver.answer(.failure(error))
            receiver.continuation.finish(throwing: error)
        } else {
            if let response = task.response { receiver.answer(.success(response)) }
            receiver.continuation.finish()
        }
    }
}

extension URLSession {
    /// Streams through a shared session of the default configuration: the
    /// request's own `timeoutInterval` and headers are what set it apart.
    public func streamingBytes(for request: URLRequest) async throws -> (StreamingBytes, URLResponse) {
        let (stream, continuation) = AsyncThrowingStream<UInt8, Error>.makeStream()
        let response: URLResponse = try await withCheckedThrowingContinuation { waiting in
            let receiver = StreamingReceiver(continuation: continuation, response: waiting)
            let task = StreamingSession.shared.start(request, receiver)
            continuation.onTermination = { _ in task.cancel() }
        }
        return (StreamingBytes(stream: stream), response)
    }
}
#endif
