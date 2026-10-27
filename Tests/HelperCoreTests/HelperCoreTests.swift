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

final class CPUChoiceTests: XCTestCase {
    func testQuarters() {
        XCTAssertEqual(CPUChoice.options(cores: 12).map(\.threads), [12, 9, 6, 3])
        XCTAssertEqual(CPUChoice.options(cores: 12).first?.label, "Alle (12)")
        XCTAssertEqual(CPUChoice.options(cores: 8).map(\.threads), [8, 6, 4, 2])
        XCTAssertEqual(CPUChoice.options(cores: 10).map(\.threads), [10, 8, 5, 3])
    }

    /// The guard fires: tiny Macs give no zero and no twice the same number.
    func testSmall() {
        XCTAssertEqual(CPUChoice.options(cores: 2).map(\.threads), [2, 1])
        XCTAssertEqual(CPUChoice.options(cores: 1).map(\.threads), [1])
        XCTAssertEqual(CPUChoice.options(cores: 0).map(\.threads), [1])
    }

    /// A number set in Settings that is no quarter still shows, ticked.
    func testCurrentFromSettings() {
        let o = CPUChoice.options(cores: 12, current: 7)
        XCTAssertEqual(o.map(\.threads), [12, 9, 7, 6, 3])
        XCTAssertEqual(o.first { $0.threads == 7 }?.label, "Eigene (7)")
        XCTAssertEqual(CPUChoice.options(cores: 12, current: 99).count, 4)
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
        XCTAssertEqual(WorkerEvent.parse(#"{"event":"model","name":"ggml-large-v3-turbo.bin","sha256":"ab","state":"downloading","bytes":1000,"bytes_done":250}"#),
                       .model(.init(name: "ggml-large-v3-turbo.bin", sha256: "ab", state: "downloading", bytes: 1000, bytesDone: 250)))
        guard case .model(let ready) = WorkerEvent.parse(#"{"event":"model","name":"ggml-small.bin","sha256":"cd","state":"ready","speed":12.5}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(ready.speed, 12.5)
        XCTAssertNil(ready.fraction)
        XCTAssertEqual(WorkerEvent.Model(name: "m", sha256: "s", state: "downloading", bytes: 0, bytesDone: 0).fraction, nil)
        XCTAssertEqual(WorkerEvent.Model(name: "m", sha256: "s", state: "downloading", bytes: 100, bytesDone: 150).fraction, 1)
        // A model event without its name is no model.
        XCTAssertNil(WorkerEvent.parse(#"{"event":"model","state":"ready"}"#))
        XCTAssertNil(WorkerEvent.parse("not json"))
    }

    func testCommands() {
        XCTAssertEqual(WorkerCommand.quit.line, "{\"cmd\":\"quit\"}\n")
        XCTAssertEqual(WorkerCommand.limits(threads: 8, gpu: true, jobs: 1).line,
                       "{\"cmd\":\"limits\",\"gpu\":true,\"jobs\":1,\"threads\":8}\n")
        XCTAssertEqual(WorkerCommand.pause(until: Date(timeIntervalSince1970: 0)).line,
                       "{\"cmd\":\"pause\",\"until\":\"1970-01-01T00:00:00Z\"}\n")
    }

    func testEnvironment() {
        let env = WorkerEnvironment.make(base: ["PATH": "/usr/bin:/H:/bin", "HOME": "/u"], helpers: "/H",
                                         fontsConf: "/R/fonts/fonts.conf", cache: "/C")
        XCTAssertEqual(env["PATH"], "/H:/usr/bin:/bin")
        XCTAssertEqual(env["FONTCONFIG_FILE"], "/R/fonts/fonts.conf")
        XCTAssertEqual(env["XDG_CACHE_HOME"], "/C")
        XCTAssertEqual(env["HOME"], "/u")
        // A FONTCONFIG_FILE already set stays; no fonts in the app, none set; no PATH, the system's.
        XCTAssertEqual(WorkerEnvironment.make(base: ["FONTCONFIG_FILE": "/x.conf"], helpers: "/H", fontsConf: "/R/f.conf", cache: "/C")["FONTCONFIG_FILE"], "/x.conf")
        let bare = WorkerEnvironment.make(base: [:], helpers: "/H", fontsConf: nil, cache: "/C")
        XCTAssertNil(bare["FONTCONFIG_FILE"])
        XCTAssertEqual(bare["PATH"], "/H:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testFlags() {
        let v027 = "usage: encode-worker [flags]\n\n  -whisper-version string\n    \twhisper.cpp's release, if no versions.txt is beside whisper-cli\n"
        let v028 = v027 + "  -toolchain-versions string\n    \tthe toolchain's versions.txt\n"
        XCTAssertFalse(WorkerFlags.supports("toolchain-versions", usage: v027))
        XCTAssertTrue(WorkerFlags.supports("toolchain-versions", usage: v028))
        XCTAssertTrue(WorkerFlags.supports("whisper-version", usage: v027))
        // A word in a description is no flag.
        XCTAssertFalse(WorkerFlags.supports("versions", usage: v028))
    }

    func testLineBuffer() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("a\nb".utf8)), ["a"])
        XCTAssertEqual(b.append(Data("c\n\n".utf8)), ["bc", ""])
    }
}

final class SiteConfigTests: XCTestCase {
    func testHostFromInput() throws {
        XCTAssertEqual(try SiteConfig.host(from: "funkhaus.example.org"), "funkhaus.example.org")
        XCTAssertEqual(try SiteConfig.host(from: "  https://Funkhaus.Example.org/encoder?x=1 "), "funkhaus.example.org")
        XCTAssertEqual(try SiteConfig.host(from: "localhost.test:8443"), "localhost.test:8443")
        // As the browser writes the origin: the default port goes, leading zeros too.
        XCTAssertEqual(try SiteConfig.host(from: "https://funkhaus.example.org:443/"), "funkhaus.example.org")
        XCTAssertEqual(try SiteConfig.host(from: "funkhaus.example.org:08443"), "funkhaus.example.org:8443")
    }

    /// The guard fires: no dot, odd characters, a bad port, empty.
    func testBadHosts() {
        for bad in ["", "localhost", "funk haus.org", "a..b", ".a.b", "a.b.", "a.b:0", "a.b:x", "a.b:1:2", "ex@mple.org",
                    "a.b:+443", "a.b:-1", "a.b:", "a.b:65536", "a.b:٤٤٣"] {
            XCTAssertThrowsError(try SiteConfig.host(from: bad), bad)
        }
    }

    func testWellKnown() throws {
        let ok = Data(#"{"app":"funkhaus","name":"Funkhaus","slipstream":{"protocol":1,"min_version":"1.1.0"}}"#.utf8)
        let site = try SiteConfig.check(host: "funkhaus.example.org", wellKnown: ok, appVersion: "1.1.0")
        XCTAssertEqual(site, SiteConfig(host: "funkhaus.example.org", name: "Funkhaus", protocol: 1))
        XCTAssertEqual(site.origin, "https://funkhaus.example.org")
        XCTAssertEqual(SiteConfig.wellKnown("a.b")?.absoluteString, "https://a.b/.well-known/funkhaus.json")
    }

    /// The guard fires: not JSON (a login page), another app, a protocol this app does not
    /// speak, a minimum above this version.
    func testWellKnownRefusals() {
        func check(_ s: String, _ v: String = "1.1.0") -> SiteConfig.Problem? {
            do { _ = try SiteConfig.check(host: "a.b", wellKnown: Data(s.utf8), appVersion: v); return nil }
            catch { return error as? SiteConfig.Problem }
        }
        XCTAssertEqual(check("<html>login</html>"), .notFunkhaus("kein JSON"))
        XCTAssertEqual(check(#"{"app":"other","slipstream":{"protocol":1}}"#), .notFunkhaus("app ist nicht funkhaus"))
        XCTAssertEqual(check(#"{"app":"funkhaus"}"#), .notFunkhaus("slipstream.protocol fehlt"))
        XCTAssertEqual(check(#"{"app":"funkhaus","slipstream":{"protocol":2}}"#), .unsupportedProtocol(2))
        XCTAssertEqual(check(#"{"app":"funkhaus","slipstream":{"protocol":1,"min_version":"1.2.0"}}"#), .tooOld(min: "1.2.0"))
        XCTAssertEqual(check(#"{"app":"funkhaus","slipstream":{"protocol":1,"min_version":"1.1.0"}}"#, "0.0.0"), .tooOld(min: "1.1.0"))
    }

    func testVersions() {
        XCTAssertEqual(SiteConfig.compare("1.10.0", "1.9.2"), 1)
        XCTAssertEqual(SiteConfig.compare("1.1", "1.1.0"), 0)
        XCTAssertEqual(SiteConfig.compare("v1.0.4", "1.1.0"), -1)
    }

    func testFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(SiteConfig.load(from: dir))
        let site = SiteConfig(host: "funkhaus.example.org", name: "F", protocol: 1)
        try site.save(to: dir)
        XCTAssertEqual(SiteConfig.load(from: dir), site)
        // A file someone edited into something that is no host is no site.
        try Data(#"{"host":"evil.org/x","name":"x","protocol":1}"#.utf8).write(to: dir.appendingPathComponent("site.json"))
        XCTAssertNil(SiteConfig.load(from: dir))
    }
}

final class UnreachableTests: XCTestCase {
    /// The setup window says the cause in one sentence, the DNS case first: a Funkhaus whose
    /// host has no DNS entry yet.
    func testCauses() {
        XCTAssertEqual(SiteConfig.unreachable("funkhaus.example.org", .cannotFindHost), "Für funkhaus.example.org gibt es keinen DNS-Eintrag.")
        XCTAssertEqual(SiteConfig.unreachable("a.b", .dnsLookupFailed), "Für a.b gibt es keinen DNS-Eintrag.")
        XCTAssertEqual(SiteConfig.unreachable("a.b", .timedOut), "a.b antwortet nicht (Zeitüberschreitung).")
        XCTAssertEqual(SiteConfig.unreachable("a.b", .serverCertificateUntrusted), "Mit a.b kommt keine sichere Verbindung zustande (Zertifikat).")
        XCTAssertEqual(SiteConfig.unreachable("a.b", nil), "a.b ist nicht erreichbar.")
    }
}
