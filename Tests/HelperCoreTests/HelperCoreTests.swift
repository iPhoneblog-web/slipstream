import DropCore
@testable import HelperCore
import XCTest

final class ByteRangesTests: XCTestCase {
    func testMergesInAnyOrder() {
        var r = ByteRanges()
        r.insert(64..<128)
        r.insert(0..<32)
        XCTAssertEqual(r.missing(192), [32..<64, 128..<192])
        r.insert(32..<64)
        r.insert(128..<192)
        XCTAssertEqual(r.ranges, [0..<192])
        XCTAssertTrue(r.covers(192))
        XCTAssertEqual(r.count, 192)
    }

    func testOverlapCountsOnce() {
        var r = ByteRanges([0..<10, 5..<20])
        XCTAssertEqual(r.count, 20)
        r.insert(30..<40)
        XCTAssertFalse(r.covers(40))
        XCTAssertEqual(r.missing(50), [20..<30, 40..<50])
    }
}

final class HTTPParserTests: XCTestCase {
    func testRequestWithBodyArrivesInPieces() {
        let raw = Data("PUT /v1/jobs/u1/source?x=a%20b HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Range: bytes 0-3/8\r\nContent-Length: 4\r\n\r\nabcdGET".utf8)
        guard case .incomplete = HTTPParser.parse(raw.prefix(30), maxBody: 100) else { return XCTFail() }
        guard case .incomplete = HTTPParser.parse(raw.prefix(raw.count - 5), maxBody: 100) else { return XCTFail() }
        guard case .request(let req, let consumed) = HTTPParser.parse(raw, maxBody: 100) else { return XCTFail() }
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.segments, ["v1", "jobs", "u1", "source"])
        XCTAssertEqual(req.query["x"], "a b")
        XCTAssertEqual(req.header("Content-Range"), "bytes 0-3/8")
        XCTAssertEqual(req.body, Data("abcd".utf8))
        XCTAssertEqual(consumed, raw.count - 3)
    }

    /// The guards fire: a body over the limit, a chunked body, a header that never ends.
    func testRefusals() {
        let big = Data("PUT / HTTP/1.1\r\nContent-Length: 101\r\n\r\n".utf8)
        guard case .failure(413) = HTTPParser.parse(big, maxBody: 100) else { return XCTFail() }
        let chunked = Data("PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        guard case .failure(411) = HTTPParser.parse(chunked, maxBody: 100) else { return XCTFail() }
        let endless = Data(repeating: 0x41, count: HTTPParser.maxHeaderBytes + 10)
        guard case .failure(431) = HTTPParser.parse(endless, maxBody: 100) else { return XCTFail() }
        guard case .failure(400) = HTTPParser.parse(Data("NONSENSE\r\n\r\n".utf8), maxBody: 100) else { return XCTFail() }
    }

    func testRanges() {
        XCTAssertEqual(HTTPParser.range("bytes=0-99", total: 1000), 0..<100)
        XCTAssertEqual(HTTPParser.range("bytes=900-", total: 1000), 900..<1000)
        XCTAssertEqual(HTTPParser.range("bytes=-10", total: 1000), 990..<1000)
        XCTAssertEqual(HTTPParser.range("bytes=950-2000", total: 1000), 950..<1000)   // the end is shorter
        XCTAssertNil(HTTPParser.range("bytes=1000-", total: 1000))                     // at the end: nothing
        XCTAssertNil(HTTPParser.range("bytes=0-1,5-6", total: 1000))
        XCTAssertNil(HTTPParser.range("items=0-1", total: 1000))
        XCTAssertEqual(HTTPParser.contentRange("bytes 64-127/200")?.0, 64..<128)
        XCTAssertEqual(HTTPParser.contentRange("bytes 64-127/200")?.1, 200)
        XCTAssertNil(HTTPParser.contentRange("bytes 64-300/200"))
    }

    func testResponseBytes() {
        let r = HTTPResponse(status: 206, headers: [("Content-Range", "bytes 0-1/4")], body: Data("ab".utf8))
        let text = String(decoding: r.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nab"))
    }
}

final class TunnelTests: XCTestCase {
    let line = "eqtunnel1 address=10.10.20.11/32 server_public_key=HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw= endpoint=vpn.example.org:51821 allowed_ips=10.10.20.1/32 keepalive=25 api=http://10.10.20.1:8090/v1"

    func testLineRoundTrip() throws {
        let c = try TunnelConfig(configLine: line)
        XCTAssertEqual(c.address, "10.10.20.11/32")
        XCTAssertEqual(c.persistentKeepaliveS, 25)
        XCTAssertEqual(c.configLine, line)
    }

    func testFromThePage() throws {
        let json = """
        {"tunnel": {"address": "10.10.20.11/32", "server_public_key": "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=",
          "endpoint": "vpn.example.org:51821", "allowed_ips": "10.10.20.1/32", "persistent_keepalive_s": 25,
          "api": "http://10.10.20.1:8090/v1"}}
        """
        XCTAssertEqual(try TunnelConfig.fromPage(Data(json.utf8)).configLine, line)
        XCTAssertEqual(try TunnelConfig.fromPage(Data("{\"config_line\": \"\(line)\"}".utf8)).configLine, line)
        XCTAssertEqual(try TunnelConfig.fromPage(Data(line.utf8)).configLine, line)
    }

    /// The guard fires: a bad key, a missing field, no port.
    func testInvalid() {
        XCTAssertThrowsError(try TunnelConfig(configLine: line.replacingOccurrences(of: "HIgo9", with: "xx")))
        XCTAssertThrowsError(try TunnelConfig(configLine: line.replacingOccurrences(of: " api=http://10.10.20.1:8090/v1", with: "")))
        XCTAssertThrowsError(try TunnelConfig(configLine: line.replacingOccurrences(of: ":51821", with: "")))
        XCTAssertThrowsError(try TunnelConfig(configLine: "wgtunnel " + line))
        XCTAssertThrowsError(try TunnelConfig.fromPage(Data("[1]".utf8)))
    }

    /// The pair from wg(8)'s example: the public key is WireGuard's.
    func testKnownKeyPair() throws {
        let key = try WireGuardKey(privateKey: Data(base64Encoded: "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=")!)
        XCTAssertEqual(key.publicBase64, "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=")
    }

    func testGeneratedKeyIsClamped() {
        let key = WireGuardKey.generate()
        XCTAssertEqual(key.privateKey[0] & 7, 0)
        XCTAssertEqual(key.privateKey[31] & 0xc0, 0x40)
        XCTAssertTrue(WireGuardKey.isValidPublic(key.publicBase64))
    }
}

final class WorkerProtocolTests: XCTestCase {
    func testEvents() {
        XCTAssertEqual(WorkerEvent.parse(#"{"event":"connection","up":true,"refused":[{"kind":"rung","reason":"x265 4.0 statt 4.1"}]}"#),
                       .connection(up: true, lastAnswerAt: nil, refused: [.init(kind: "rung", reason: "x265 4.0 statt 4.1")]))
        guard case .job(let job) = WorkerEvent.parse(#"{"event":"job","lease_id":"l1","title":"Folge 12","kind":"rung","rung":"2160","fraction":0.25,"fps":3.5,"eta_s":600,"new_field":1}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(job.rung, "2160")
        XCTAssertEqual(job.etaS, 600)
        XCTAssertEqual(WorkerEvent.parse(#"{"event":"update","latest":"1.1.0"}"#), .update(latest: "1.1.0"))
        XCTAssertEqual(WorkerEvent.parse(#"{"event":"paused","until":null}"#), .paused(until: nil))
        XCTAssertNil(WorkerEvent.parse(#"{"event":"something-new"}"#))
        XCTAssertNil(WorkerEvent.parse("not json"))
    }

    func testCommands() {
        XCTAssertEqual(WorkerCommand.quit.line, "{\"cmd\":\"quit\"}\n")
        XCTAssertEqual(WorkerCommand.limits(threads: 8, gpu: true, jobs: 1).line,
                       "{\"cmd\":\"limits\",\"gpu\":true,\"jobs\":1,\"threads\":8}\n")
        XCTAssertEqual(WorkerCommand.pause(until: Date(timeIntervalSince1970: 0)).line,
                       "{\"cmd\":\"pause\",\"until\":\"1970-01-01T00:00:00Z\"}\n")
    }

    func testLineBuffer() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("a\nb".utf8)), ["a"])
        XCTAssertEqual(b.append(Data("c\n\n".utf8)), ["bc", ""])
    }
}
