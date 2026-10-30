// Checks an update archive's EdDSA signature against the public key shipped in the app (SUPublicEDKey),
// so a wrong signing key fails the release instead of silently breaking updates.
// Usage: swift .github/verify-sparkle.swift <archive> <base64 signature> <base64 public key>
import CryptoKit
import Foundation

let a = CommandLine.arguments
guard a.count == 4, let data = FileManager.default.contents(atPath: a[1]),
      let sig = Data(base64Encoded: a[2]), let pub = Data(base64Encoded: a[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { print("bad arguments"); exit(2) }
if key.isValidSignature(sig, for: data) { print("update signature OK") } else { print("update signature does NOT match SUPublicEDKey"); exit(1) }
