// A detached signature of one file with Slipstream's EdDSA key (docs/release.md, "Updates"):
// the base64 of the Ed25519 signature over the file's exact bytes, one line. A release signs its
// SHA256SUMS this way, so a mirror of the DMG (a Funkhaus's) can check the sums came from here.
//   swift tools/sign.swift <file> <public-key> <out.sig>
// The private key comes from the environment, SPARKLE_ED_PRIVATE_KEY, as for tools/appcast.swift.
// It must belong to <public-key>, the app's SUPublicEDKey; the signature is checked against that
// key before the file is written.
import CryptoKit
import Foundation

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("sign: \(s)\n".utf8))
    exit(1)
}

let a = CommandLine.arguments
guard a.count == 4 else { fail("usage: sign.swift <file> <public-key> <out.sig>") }
let (file, publicKey, out) = (a[1], a[2], a[3])

guard let seedText = ProcessInfo.processInfo.environment["SPARKLE_ED_PRIVATE_KEY"],
      let seed = Data(base64Encoded: seedText.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fail("SPARKLE_ED_PRIVATE_KEY is not a base64 Ed25519 seed of 32 bytes")
}
guard key.publicKey.rawRepresentation.base64EncodedString() == publicKey,
      let verifier = Data(base64Encoded: publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }) else {
    fail("the private key does not belong to the app's public key \(publicKey)")
}
guard let data = FileManager.default.contents(atPath: file) else { fail("cannot read \(file)") }
guard let signature = try? key.signature(for: data),
      verifier.isValidSignature(signature, for: data) else { fail("signing failed") }
do {
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: out))
} catch {
    fail("cannot write \(out): \(error)")
}
print("sign: \(file), \(data.count) bytes, signed for \(publicKey)")
