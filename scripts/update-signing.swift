// Ed25519 signing for Burrow's in-app updates (see Sources/Burrow/Core/AppUpdate.swift).
//
//   swift scripts/update-signing.swift generate [--key-file PATH] [--force]
//       Creates a new signing key and prints its public key (put that in Resources/Info.plist as
//       BurrowUpdatePublicKey). By default the private key is stored in your login Keychain; --key-file
//       writes it to PATH (mode 0600) instead, for throwaway test keys.
//   swift scripts/update-signing.swift public-key [--key-file PATH]
//   swift scripts/update-signing.swift export-private-key       (for: … | gh secret set BURROW_UPDATE_SIGNING_KEY)
//   swift scripts/update-signing.swift sign FILE [--key-file PATH]       prints the base64 signature
//   swift scripts/update-signing.swift verify FILE SIGNATURE_FILE PUBLIC_KEY_BASE64
//
// The private key is read from, in order: --key-file, the BURROW_UPDATE_SIGNING_KEY environment variable
// (CI), then the Keychain. Keys are base64 of CryptoKit's 32-byte raw representation.
import CryptoKit
import Foundation
import Security

let keychainService = "io.github.pimzino.burrow.update-signing"
let keychainAccount = "BurrowUpdateSigningKey"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func keychainRead() -> Data? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: keychainAccount, kSecReturnData as String: true]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
}

func keychainWrite(_ data: Data) {
    let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                               kSecAttrAccount as String: keychainAccount]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrLabel as String] = "Burrow update signing key"
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("could not store the key in the Keychain (OSStatus \(status))") }
}

func decodeKey(_ text: String, from source: String) -> Curve25519.Signing.PrivateKey {
    guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("the private key in \(source) is not a base64 Ed25519 key")
    }
    return key
}

func loadKey(keyFile: String?) -> Curve25519.Signing.PrivateKey {
    if let keyFile {
        guard let text = try? String(contentsOfFile: keyFile, encoding: .utf8) else { fail("cannot read \(keyFile)") }
        return decodeKey(text, from: keyFile)
    }
    if let env = ProcessInfo.processInfo.environment["BURROW_UPDATE_SIGNING_KEY"], !env.isEmpty {
        return decodeKey(env, from: "BURROW_UPDATE_SIGNING_KEY")
    }
    if let data = keychainRead() {
        return decodeKey(String(decoding: data, as: UTF8.self), from: "the Keychain")
    }
    fail("no signing key: pass --key-file, set BURROW_UPDATE_SIGNING_KEY, or run `generate` first")
}

guard !args.isEmpty else { fail("usage: update-signing.swift generate|public-key|export-private-key|sign|verify …") }
let command = args.removeFirst()
let keyFile = option("--key-file")

switch command {
case "generate":
    let force = flag("--force")
    let key = Curve25519.Signing.PrivateKey()
    let encoded = key.rawRepresentation.base64EncodedString()
    if let keyFile {
        if FileManager.default.fileExists(atPath: keyFile), !force { fail("\(keyFile) exists (use --force to replace it)") }
        FileManager.default.createFile(atPath: keyFile, contents: Data((encoded + "\n").utf8), attributes: [.posixPermissions: 0o600])
    } else {
        // Replacing the key strands every installed copy that trusts the old public key, so never do it silently.
        if keychainRead() != nil, !force { fail("a signing key already exists in the Keychain (use --force to replace it)") }
        keychainWrite(Data(encoded.utf8))
        FileHandle.standardError.write(Data("Stored the private key in your login Keychain (\(keychainService)).\n".utf8))
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public-key":
    print(loadKey(keyFile: keyFile).publicKey.rawRepresentation.base64EncodedString())

case "export-private-key":
    print(loadKey(keyFile: keyFile).rawRepresentation.base64EncodedString())

case "sign":
    guard let path = args.first else { fail("sign needs a file") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { fail("cannot read \(path)") }
    guard let signature = try? loadKey(keyFile: keyFile).signature(for: data) else { fail("signing failed") }
    print(signature.base64EncodedString())

case "verify":
    guard args.count == 3 else { fail("verify needs FILE SIGNATURE_FILE PUBLIC_KEY_BASE64") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[0]), options: .mappedIfSafe),
          let sigText = try? String(contentsOfFile: args[1], encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let keyData = Data(base64Encoded: args[2]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("cannot read the inputs") }
    if publicKey.isValidSignature(signature, for: data) {
        print("OK: \(args[0]) is signed by \(args[2])")
    } else {
        fail("the signature of \(args[0]) does NOT match the public key")
    }

default:
    fail("unknown command \(command)")
}
