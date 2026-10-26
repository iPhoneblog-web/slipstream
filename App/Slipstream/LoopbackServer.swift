import Foundation
import HelperCore
import Network
import os

/// The loopback endpoint on 127.0.0.1 and a free port (ADR-0007 §7). Network.framework carries
/// the bytes; HelperCore parses and answers.
final class LoopbackServer: @unchecked Sendable {
    private let api: LoopbackAPI
    private let queue = DispatchQueue(label: "slipstream.loopback")
    private var listener: NWListener?
    private let log = Logger(subsystem: SlipstreamIDs.logSubsystem, category: "loopback")

    init(api: LoopbackAPI) {
        self.api = api
    }

    /// Starts listening and returns the port.
    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [api, queue, log] connection in
            HTTPConnection(connection: connection, api: api, queue: queue, log: log).start()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

/// One keep-alive connection: requests one after another, as `fetch` sends them.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let api: LoopbackAPI
    private let queue: DispatchQueue
    private let log: Logger
    private var buffer = Data()
    /// `Expect: 100-continue` (curl sends it; Safari does not) is answered once per request.
    private var continued = false
    /// A 64 MiB slice and its headers.
    private static let maxBody = ProResJobs.maxSlice + 1024 * 1024

    init(connection: NWConnection, api: LoopbackAPI, queue: DispatchQueue, log: Logger) {
        self.connection = connection
        self.api = api
        self.queue = queue
        self.log = log
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024 * 1024) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if error != nil || (complete && data == nil) {
                connection.cancel()
                return
            }
            process()
        }
    }

    private func process() {
        switch HTTPParser.parse(buffer, maxBody: Self.maxBody) {
        case .incomplete:
            if !continued, let head = buffer.prefix(HTTPParser.maxHeaderBytes + 4).range(of: Data("\r\n\r\n".utf8)),
               String(decoding: buffer[buffer.startIndex..<head.lowerBound], as: UTF8.self).lowercased()
                .contains("\r\nexpect: 100-continue") {
                continued = true
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            receive()
        case .failure(let status):
            send(HTTPResponse(status: status), keepAlive: false)
        case .request(let request, let consumed):
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: consumed))
            continued = false
            Task { [self] in
                let response = await api.handle(request)
                if response.status >= 400 {
                    log.info("\(request.method, privacy: .public) \(request.path, privacy: .public): \(response.status)")
                }
                queue.async { self.send(response, keepAlive: true) }
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [self] error in
            if error != nil || !keepAlive {
                connection.cancel()
            } else {
                queue.async { self.process() }
            }
        })
    }
}
