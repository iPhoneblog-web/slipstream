import Foundation

/// One request of HTTP/1.1, as the bridge sends it: a request line, headers, and a body of
/// `Content-Length` bytes. No chunked bodies: `fetch` with a `Blob` always sends a length.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:],
                body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The path's segments, `/v1/jobs/u1/source` as `["v1", "jobs", "u1", "source"]`.
    public var segments: [String] { path.split(separator: "/").map(String.init) }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let body = (try? JSONCoding.encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: body)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    public func serialized(keepAlive: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 422: return "Unprocessable Content"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }
}

public enum HTTPParser {
    public enum Result {
        /// More bytes needed.
        case incomplete
        case request(HTTPRequest, consumed: Int)
        /// Answer with this status and close.
        case failure(Int)
    }

    public static let maxHeaderBytes = 16 * 1024

    /// Parses the first request in `buffer`. `maxBody` bounds the body: a 64 MiB slice and a
    /// little room.
    public static func parse(_ buffer: Data, maxBody: Int) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        let window = buffer.prefix(maxHeaderBytes + 4)
        guard let end = window.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .failure(431) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .failure(400)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .failure(400) }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failure(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if let te = headers["transfer-encoding"], te.lowercased() != "identity" { return .failure(411) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .failure(400) }
        guard length <= maxBody else { return .failure(413) }
        let bodyStart = end.upperBound
        guard buffer.distance(from: buffer.startIndex, to: bodyStart) + length <= buffer.count else {
            return .incomplete
        }
        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: length))

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                query[key] = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            }
        }
        let request = HTTPRequest(method: String(requestLine[0]), path: String(parts.first ?? "/"), query: query,
                                  headers: headers, body: body)
        return .request(request, consumed: buffer.distance(from: buffer.startIndex, to: bodyStart) + length)
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n` against a file of `total` bytes, as a half-open
    /// range; nil when it does not fit.
    public static func range(_ header: String, total: Int64) -> Range<Int64>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty {
            guard let n = Int64(spec[1]), n > 0 else { return nil }
            return max(0, total - n)..<total
        }
        guard let a = Int64(spec[0]), a < total else { return nil }
        let b = spec[1].isEmpty ? total - 1 : min(Int64(spec[1]) ?? -1, total - 1)
        guard b >= a else { return nil }
        return a..<(b + 1)
    }

    /// `bytes a-b/total` (a request's Content-Range) as a half-open range and the total.
    public static func contentRange(_ header: String) -> (Range<Int64>, Int64)? {
        guard header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let ab = parts[0].split(separator: "-")
        guard ab.count == 2, let a = Int64(ab[0]), let b = Int64(ab[1]), a <= b, b < total else { return nil }
        return (a..<(b + 1), total)
    }
}

/// snake_case JSON, ISO 8601 times: what the page and the queue read.
public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
