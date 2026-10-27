// The Sparkle appcast of a release: one item for the archive, signed with Slipstream's EdDSA key
// (docs/release.md, "Updates").
//   swift tools/appcast.swift <archive> <short-version> <build> <archive-url> <public-key> <out.xml>
// The private key comes from the environment, SPARKLE_ED_PRIVATE_KEY: the base64 of the 32-byte
// Ed25519 seed, as Sparkle's generate_keys exports it. It must belong to <public-key>, the app's
// SUPublicEDKey; the signature is checked against that key before the file is written.
import CryptoKit
import Foundation

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("appcast: \(s)\n".utf8))
    exit(1)
}

let a = CommandLine.arguments
guard a.count == 7 else { fail("usage: appcast.swift <archive> <short-version> <build> <archive-url> <public-key> <out.xml>") }
let (archive, short, build, url, publicKey, out) = (a[1], a[2], a[3], a[4], a[5], a[6])

guard let seedText = ProcessInfo.processInfo.environment["SPARKLE_ED_PRIVATE_KEY"],
      let seed = Data(base64Encoded: seedText.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fail("SPARKLE_ED_PRIVATE_KEY is not a base64 Ed25519 seed of 32 bytes")
}
guard key.publicKey.rawRepresentation.base64EncodedString() == publicKey else {
    fail("the private key does not belong to the app's public key \(publicKey)")
}
guard let data = FileManager.default.contents(atPath: archive) else { fail("cannot read \(archive)") }
guard let signature = try? key.signature(for: data),
      key.publicKey.isValidSignature(signature, for: data) else { fail("signing failed") }

func xml(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}
let date = DateFormatter()
date.locale = Locale(identifier: "en_US_POSIX")
date.timeZone = TimeZone(identifier: "UTC")
date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
let release = "https://github.com/kyrios/slipstream/releases/tag/v\(short)"

let feed = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Slipstream</title>
    <link>https://github.com/kyrios/slipstream</link>
    <item>
      <title>Slipstream \(xml(short))</title>
      <pubDate>\(date.string(from: Date()))</pubDate>
      <link>\(xml(release))</link>
      <sparkle:version>\(xml(build))</sparkle:version>
      <sparkle:shortVersionString>\(xml(short))</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>\(xml(release))</sparkle:fullReleaseNotesLink>
      <enclosure url="\(xml(url))" length="\(data.count)" type="application/octet-stream"
        sparkle:edSignature="\(signature.base64EncodedString())"/>
    </item>
  </channel>
</rss>

"""
do {
    try Data(feed.utf8).write(to: URL(fileURLWithPath: out))
} catch {
    fail("cannot write \(out): \(error)")
}
print("appcast: \(short) (\(build)), \(data.count) bytes, signed for \(publicKey)")
