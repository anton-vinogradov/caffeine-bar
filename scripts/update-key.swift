// Ed25519 key that signs release zips for the built-in updater. The private half lives in the login Keychain,
// and no app is trusted to read it: macOS asks for permission on every use, so no script can take it silently.
//   swift scripts/update-key.swift new         - create the key once; prints the public half for Updater.swift
//   swift scripts/update-key.swift sign <zip>  - write <zip>.sig
//   swift scripts/update-key.swift export      - print the private key as base64, for a backup in a password manager
//   swift scripts/update-key.swift import      - read that base64 from stdin into the Keychain
import CryptoKit
import Foundation
import Security

let service = "caffeine-bar update signing key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func load() -> Curve25519.Signing.PrivateKey? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecReturnData: true,
    ]
    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)

    if status == errSecItemNotFound { return nil }

    guard status == errSecSuccess, let raw = out as? Data else {
        fail("No access to the key in the Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")")
    }

    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

/** Looks for the item by its attributes only: reading them does not touch the key, so macOS does not ask. */
func exists() -> Bool {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnAttributes: true]

    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}

func store(_ key: Curve25519.Signing.PrivateKey) {
    if exists() { fail("The key already exists in the Keychain.") }

    // An empty list of trusted apps: without it, the app that creates the item (swift-frontend, which runs
    // every `swift x.swift`) could read it back without asking.
    var access: SecAccess?
    guard SecAccessCreate(service as CFString, [] as CFArray, &access) == errSecSuccess, let access else {
        fail("Could not create the Keychain access rule.")
    }

    let item: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: "ed25519",
        kSecAttrLabel: service,
        kSecAttrAccess: access,
        kSecValueData: key.rawRepresentation,
    ]
    let status = SecItemAdd(item as CFDictionary, nil)

    guard status == errSecSuccess else { fail("Keychain error \(status)") }
}

/** The public key the app is built with: signing with any other key would only produce updates nobody accepts. */
func appKey() -> String {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Updater.swift")

    guard let text = try? String(contentsOf: source, encoding: .utf8),
          let match = text.firstMatch(of: #/var publicKey = "([^"]+)"/#) else { fail("No publicKey in \(source.path)") }

    return String(match.1)
}

let args = CommandLine.arguments

switch args.count > 1 ? args[1] : "" {
case "new":
    let key = Curve25519.Signing.PrivateKey()
    store(key)

    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign" where args.count == 3:
    guard let key = load() else {
        fail("No key in the Keychain. Restore it from the backup with `import`. Use `new` only if there is no backup: installed copies would stop updating.")
    }

    guard key.publicKey.rawRepresentation.base64EncodedString() == appKey() else {
        fail("The key in the Keychain does not match publicKey in Updater.swift: installed apps would reject this update.")
    }

    let zip = URL(fileURLWithPath: args[2])
    let signature = try key.signature(for: Data(contentsOf: zip))
    let out = zip.appendingPathExtension("sig")
    try (signature.base64EncodedString() + "\n").write(to: out, atomically: true, encoding: .utf8)

    print(out.path)

case "export":
    guard let key = load() else { fail("No key in the Keychain.") }

    FileHandle.standardError.write("This is the private key. Keep it only in a password manager.\n".data(using: .utf8)!)
    print(key.rawRepresentation.base64EncodedString())

case "import":
    guard let line = readLine(), let raw = Data(base64Encoded: line.trimmingCharacters(in: .whitespaces)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("Expected the base64 key from `export` on stdin.") }

    store(key)

    print(key.publicKey.rawRepresentation.base64EncodedString())

default:
    fail("Usage: swift scripts/update-key.swift new | sign <zip> | export | import")
}
