import Foundation
import CryptoKit
import Darwin

// Derivation/check only: no key generation, Keychain, private output or environment key.
do {
    guard CommandLine.arguments.count == 3 else { throw NSError(domain: "UpdateSigningKey", code: 1) }
    let encoded = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let text = String(data: encoded, encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else {
        throw NSError(domain: "UpdateSigningKey", code: 2)
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    guard key.publicKey.rawRepresentation.base64EncodedString() == CommandLine.arguments[2] else {
        FileHandle.standardError.write(Data("Public key mismatch\n".utf8)); exit(2)
    }
    print("PUBLIC_KEY_MATCH")
} catch {
    FileHandle.standardError.write(Data("Invalid signing seed input\n".utf8)); exit(1)
}
