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

final class StreamingReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<UInt8, Error>.Continuation
    private let lock = NSLock()
    private var response: CheckedContinuation<URLResponse, Error>?

    init(continuation: AsyncThrowingStream<UInt8, Error>.Continuation, response: CheckedContinuation<URLResponse, Error>) {
        self.continuation = continuation
        self.response = response
    }

    private func answer(_ result: Result<URLResponse, Error>) {
        lock.lock()
        let waiting = response
        response = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        answer(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for byte in data { continuation.yield(byte) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            answer(.failure(error))
            continuation.finish(throwing: error)
        } else {
            if let response = task.response { answer(.success(response)) }
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}

extension URLSession {
    /// A session of its own per request (the delegate is per session), with this one's configuration.
    public func streamingBytes(for request: URLRequest) async throws -> (StreamingBytes, URLResponse) {
        let (stream, continuation) = AsyncThrowingStream<UInt8, Error>.makeStream()
        let configuration = self.configuration
        let response: URLResponse = try await withCheckedThrowingContinuation { waiting in
            let receiver = StreamingReceiver(continuation: continuation, response: waiting)
            let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
        return (StreamingBytes(stream: stream), response)
    }
}
#endif
