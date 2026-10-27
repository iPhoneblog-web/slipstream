import AVFoundation
@testable import HelperCore
import XCTest

/// The loopback endpoint as the bridge uses it, on a job store in a temporary folder.
final class LoopbackTests: XCTestCase {
    private var root: URL!
    private let origin = "safari-web-extension://3B1C2D7E-0000-4000-8000-000000000001"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slipstream-jobs-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct FakePairing: Pairing {
        let tunnels = Box<[TunnelConfig]>([])
        func identity() async throws -> PairingIdentity {
            PairingIdentity(name: "Test-Mac", publicKey: "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=", paired: false, tunnelAddress: nil)
        }
        func setTunnel(_ config: TunnelConfig) async throws { tunnels.value.append(config) }
    }

    /// Copies the source as the "intermediate": the store's bookkeeping without VideoToolbox.
    private static let copying: IntermediateEncoder = { source, output, progress in
        progress(EncodeProgress(fraction: 0.5))
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: source, to: output)
        progress(EncodeProgress(fraction: 1))
        let size = Int64(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as! Int)
        return IntermediateInfo(size: size, durationS: 1, width: 2, height: 2, bitRate: 1, codec: "hvc1")
    }

    private func api(_ encoder: @escaping IntermediateEncoder = LoopbackTests.copying, pairing: Pairing = FakePairing()) async throws -> LoopbackAPI {
        let jobs = ProResJobs(root: root, encoder: encoder)
        try await jobs.load()
        return LoopbackAPI(token: "t0ken", version: "1.0.0", name: "Test-Mac", jobs: jobs, pairing: pairing)
    }

    private func call(_ api: LoopbackAPI, _ method: String, _ path: String, body: Data = Data(),
                      headers: [String: String] = [:]) async -> HTTPResponse {
        var h = ["Origin": origin, "X-Slipstream-Token": "t0ken"]
        h.merge(headers) { $1 }
        // As the parser hands it over: the query apart from the path.
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        for pair in parts.count == 2 ? parts[1].split(separator: "&") : [] {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            query[kv[0]] = kv.count == 2 ? kv[1] : ""
        }
        return await api.handle(HTTPRequest(method: method, path: parts[0], query: query, headers: h, body: body))
    }

    private func json(_ r: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    private func waitFor(_ api: LoopbackAPI, _ id: String, phase: String) async throws -> [String: Any] {
        for _ in 0..<200 {
            let j = json(await call(api, "GET", "/v1/jobs/\(id)"))
            if j["phase"] as? String == phase { return j }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("never \(phase)")
        return [:]
    }

    // MARK: - Guards

    func testOnlyTheExtensionsOrigin() async throws {
        let a = try await api()
        let web = await a.handle(HTTPRequest(method: "GET", path: "/v1/ping",
                                             headers: ["Origin": "https://evil.example", "X-Slipstream-Token": "t0ken"]))
        XCTAssertEqual(web.status, 403)
        let none = await a.handle(HTTPRequest(method: "GET", path: "/v1/ping", headers: ["X-Slipstream-Token": "t0ken"]))
        XCTAssertEqual(none.status, 403)
        let wrong = await call(a, "GET", "/v1/ping", headers: ["X-Slipstream-Token": "guess"])
        XCTAssertEqual(wrong.status, 403)
        XCTAssertEqual(wrong.header("Access-Control-Allow-Origin"), origin)
        let ok = await call(a, "GET", "/v1/ping")
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(json(ok)["protocol"] as? Int, 1)
    }

    /// Only a request with the right token counts as the bridge reaching the app.
    func testSeenOnlyWithTheToken() async throws {
        let count = Box(0)
        let jobs = ProResJobs(root: root, encoder: LoopbackTests.copying)
        try await jobs.load()
        let a = LoopbackAPI(token: "t0ken", version: "1", name: "Mac", jobs: jobs, pairing: FakePairing(),
                            seen: { count.value += 1 })
        _ = await call(a, "GET", "/v1/ping", headers: ["X-Slipstream-Token": "guess"])
        XCTAssertEqual(count.value, 0)
        _ = await call(a, "GET", "/v1/ping")
        XCTAssertEqual(count.value, 1)
    }

    func testPreflightAllowsPrivateNetwork() async throws {
        let a = try await api()
        let r = await a.handle(HTTPRequest(method: "OPTIONS", path: "/v1/jobs/u1/source",
                                           headers: ["Origin": origin, "Access-Control-Request-Method": "PUT",
                                                     "Access-Control-Request-Private-Network": "true"]))
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(r.header("Access-Control-Allow-Private-Network"), "true")
        XCTAssertTrue(r.header("Access-Control-Allow-Headers")!.contains("X-Slipstream-Token"))
    }

    // MARK: - A job from first slice to deletion

    func testJobRoundTrip() async throws {
        let a = try await api()
        let file = Data((0..<300).map { UInt8($0 % 251) })
        let open = await call(a, "PUT", "/v1/jobs/u_1", body: Data(#"{"name":"Folge 12.mov","size":300,"last_modified":1}"#.utf8))
        XCTAssertEqual(open.status, 200)
        XCTAssertEqual(json(open)["phase"] as? String, "receiving")
        XCTAssertEqual(json(open)["missing"] as? [[Int]], [[0, 300]])

        // The index first, then the rest: any order.
        let tail = await call(a, "PUT", "/v1/jobs/u_1/source", body: file[200..<300],
                              headers: ["Content-Range": "bytes 200-299/300"])
        XCTAssertEqual(json(tail)["missing"] as? [[Int]], [[0, 200]])
        _ = await call(a, "PUT", "/v1/jobs/u_1/source", body: file[0..<200], headers: ["Content-Range": "bytes 0-199/300"])

        // A second open under the same id, after a closed tab: the same job.
        let again = await call(a, "PUT", "/v1/jobs/u_1", body: Data(#"{"name":"Folge 12.mov","size":300}"#.utf8))
        XCTAssertEqual(again.status, 200)

        let ready = try await waitFor(a, "u_1", phase: "ready")
        XCTAssertEqual((ready["intermediate"] as? [String: Any])?["size"] as? Int, 300)

        let slice = await call(a, "GET", "/v1/jobs/u_1/intermediate", headers: ["Range": "bytes=100-199"])
        XCTAssertEqual(slice.status, 206)
        XCTAssertEqual(slice.header("Content-Range"), "bytes 100-199/300")
        XCTAssertEqual(slice.body, file[100..<200])
        let end = await call(a, "GET", "/v1/jobs/u_1/intermediate", headers: ["Range": "bytes=250-400"])
        XCTAssertEqual(end.body, file[250..<300])
        let past = await call(a, "GET", "/v1/jobs/u_1/intermediate", headers: ["Range": "bytes=300-"])
        XCTAssertEqual(past.status, 416)

        let list = json(await call(a, "GET", "/v1/jobs"))["jobs"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)

        do { let r = await call(a, "DELETE", "/v1/jobs/u_1?reason=finish"); XCTAssertEqual(r.status, 204) }
        do { let r = await call(a, "GET", "/v1/jobs/u_1"); XCTAssertEqual(r.status, 404) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("u_1").path))
    }

    /// The guards fire: another file under the same id, a slice that does not fit, a read before
    /// ready, an unknown or malformed id.
    func testJobRefusals() async throws {
        let never: IntermediateEncoder = { _, _, _ in try await Task.sleep(nanoseconds: 60_000_000_000); throw JobError("internal", "") }
        let a = try await api(never)
        _ = await call(a, "PUT", "/v1/jobs/u2", body: Data(#"{"name":"a.mov","size":10}"#.utf8))
        let other = await call(a, "PUT", "/v1/jobs/u2", body: Data(#"{"name":"b.mov","size":10}"#.utf8))
        XCTAssertEqual(other.status, 409)
        XCTAssertEqual((json(other)["error"] as? [String: Any])?["code"] as? String, "file-mismatch")
        let longer = await call(a, "PUT", "/v1/jobs/u2/source", body: Data(count: 4), headers: ["Content-Range": "bytes 0-4/10"])
        XCTAssertEqual(longer.status, 400)
        let wrongTotal = await call(a, "PUT", "/v1/jobs/u2/source", body: Data(count: 5), headers: ["Content-Range": "bytes 0-4/11"])
        XCTAssertEqual((json(wrongTotal)["error"] as? [String: Any])?["code"] as? String, "file-mismatch")
        let early = await call(a, "GET", "/v1/jobs/u2/intermediate")
        XCTAssertEqual((json(early)["error"] as? [String: Any])?["code"] as? String, "not-ready")
        do { let r = await call(a, "GET", "/v1/jobs/nope"); XCTAssertEqual(r.status, 404) }
        do { let r = await call(a, "GET", "/v1/jobs/a%2Fb"); XCTAssertEqual(r.status, 400) }
        do { let r = await call(a, "PUT", "/v1/jobs/u3", body: Data("{}".utf8)); XCTAssertEqual(r.status, 400) }
    }

    /// Cancel while encoding: the encode stops and both files go.
    func testCancelWhileEncoding() async throws {
        let slow: IntermediateEncoder = { _, _, progress in
            progress(EncodeProgress(fraction: 0.1))
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw JobError("internal", "")
        }
        let a = try await api(slow)
        _ = await call(a, "PUT", "/v1/jobs/c1", body: Data(#"{"name":"a.mov","size":4}"#.utf8))
        _ = await call(a, "PUT", "/v1/jobs/c1/source", body: Data(count: 4), headers: ["Content-Range": "bytes 0-3/4"])
        _ = try await waitFor(a, "c1", phase: "encoding")
        do { let r = await call(a, "DELETE", "/v1/jobs/c1?reason=cancel"); XCTAssertEqual(r.status, 204) }
        do { let r = await call(a, "GET", "/v1/jobs"); XCTAssertEqual(r.body, Data(#"{"jobs":[]}"#.utf8)) }
    }

    func testPairing() async throws {
        let pairing = FakePairing()
        let a = try await api(pairing: pairing)
        let id = json(await call(a, "GET", "/v1/pairing"))
        XCTAssertEqual(id["public_key"] as? String, "HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw=")
        let line = "eqtunnel1 address=10.10.20.11/32 server_public_key=HIgo9xNzJMWLKASShiTqIybxZ0U3wGLiUeJ1PKf8ykw= endpoint=vpn.example.org:51821 allowed_ips=10.10.20.1/32 keepalive=25 api=http://10.10.20.1:8090/v1"
        do { let r = await call(a, "PUT", "/v1/pairing", body: Data(line.utf8)); XCTAssertEqual(r.status, 204) }
        XCTAssertEqual(pairing.tunnels.value.first?.address, "10.10.20.11/32")
        do { let r = await call(a, "PUT", "/v1/pairing", body: Data("eqtunnel1 address=x".utf8)); XCTAssertEqual(r.status, 400) }
    }

    // MARK: - The store across restarts and days

    func testRestartQueuesTheEncodeAgain() async throws {
        let jobs = ProResJobs(root: root, encoder: { _, _, _ in try await Task.sleep(nanoseconds: 60_000_000_000); throw JobError("internal", "") })
        try await jobs.load()
        _ = try await jobs.open(id: "r1", name: "a.mov", size: 2, lastModified: nil)
        _ = try await jobs.receive(id: "r1", range: 0..<2, total: 2, data: Data([1, 2]))
        let first = try await jobs.status(id: "r1")
        XCTAssertEqual(first.phase, .encoding)

        let again = ProResJobs(root: root, encoder: LoopbackTests.copying)
        try await again.load()
        var phase = try await again.status(id: "r1").phase
        for _ in 0..<100 where phase != .ready {
            try await Task.sleep(nanoseconds: 20_000_000)
            phase = try await again.status(id: "r1").phase
        }
        XCTAssertEqual(phase, .ready)
    }

    func testOlderThanSevenDaysGoes() async throws {
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        let jobs = ProResJobs(root: root, encoder: LoopbackTests.copying, now: { clock.value })
        try await jobs.load()
        _ = try await jobs.open(id: "old", name: "a.mov", size: 2, lastModified: nil)
        clock.value = clock.value.addingTimeInterval(6 * 24 * 3600)
        _ = try await jobs.open(id: "new", name: "b.mov", size: 2, lastModified: nil)
        let none = await jobs.cleanUp()
        XCTAssertEqual(none, [])
        clock.value = clock.value.addingTimeInterval(2 * 24 * 3600)
        let gone = await jobs.cleanUp()
        XCTAssertEqual(gone, ["old"])
        let left = await jobs.list().map(\.uploadId)
        XCTAssertEqual(left, ["new"])
    }

    /// The guard fires: a file that does not fit on the disk is refused at open, before a slice.
    func testDiskFullAtOpen() async throws {
        let jobs = ProResJobs(root: root, encoder: LoopbackTests.copying, freeSpace: { _ in 10 << 30 })
        try await jobs.load()
        do {
            _ = try await jobs.open(id: "big", name: "a.mov", size: 9 << 30, lastModified: nil)
            XCTFail("expected disk-full")
        } catch let e as JobError {
            XCTAssertEqual(e.code, "disk-full")
            XCTAssertEqual(e.status, 507)
        }
        let small = try await jobs.open(id: "small", name: "a.mov", size: 1 << 30, lastModified: nil)
        XCTAssertEqual(small.phase, .receiving)
    }

    /// The real encode behind the store: a ProRes fixture becomes a checked hvc1 intermediate.
    func testVideoToolboxEncode() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../DropCoreTests/fixtures/prores-hq-320x180.mov").standardizedFileURL
        let data = try Data(contentsOf: fixture)
        let a = try await api(ProResJobs.videoToolbox)
        _ = await call(a, "PUT", "/v1/jobs/vt", body: Data("{\"name\":\"clip.mov\",\"size\":\(data.count)}".utf8))
        _ = await call(a, "PUT", "/v1/jobs/vt/source", body: data, headers: ["Content-Range": "bytes 0-\(data.count - 1)/\(data.count)"])
        let ready = try await waitFor(a, "vt", phase: "ready")
        let info = try XCTUnwrap(ready["intermediate"] as? [String: Any])
        XCTAssertEqual(info["width"] as? Int, 320)
        XCTAssertEqual(info["codec"] as? String, "hvc1")
        XCTAssertEqual(info["duration_s"] as! Double, 2.0, accuracy: 0.05)
    }

    /// A file AVFoundation cannot read fails with the page's code, not a crash.
    func testNotAVideoFails() async throws {
        let a = try await api(ProResJobs.videoToolbox)
        _ = await call(a, "PUT", "/v1/jobs/nv", body: Data(#"{"name":"x.mov","size":5}"#.utf8))
        _ = await call(a, "PUT", "/v1/jobs/nv/source", body: Data("hello".utf8), headers: ["Content-Range": "bytes 0-4/5"])
        let failed = try await waitFor(a, "nv", phase: "failed")
        XCTAssertEqual((failed["error"] as? [String: Any])?["code"] as? String, "not-a-video")
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
