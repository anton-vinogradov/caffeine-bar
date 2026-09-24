// Ed25519 key that signs release zips for the built-in updater. The private half lives in the login Keychain,
// and no app is trusted to read it: macOS asks for permission on every use, so no script can take it silently.
//   swift scripts/update-key.swift new         - create the key once; prints the public half for Updater.swift
//   swift scripts/update-key.swift sign <zip>  - write <zip>.sig
//   swift scripts/update-key.swift export      - print the private key as base64, for a backup in a password manager
//   swift scripts/update-key.swift import      - read that base64 from stdin into the Keychain
//   swift scripts/update-key.swift lock        - take back "Always Allow" given to any app
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

func add(_ key: Curve25519.Signing.PrivateKey, access: SecAccess?) -> OSStatus {
    var item: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: "ed25519",
        kSecAttrLabel: service,
        kSecValueData: key.rawRepresentation,
    ]
    if let access { item[kSecAttrAccess] = access }

    return SecItemAdd(item as CFDictionary, nil)
}

func store(_ key: Curve25519.Signing.PrivateKey) {
    if exists() { fail("The key already exists in the Keychain.") }

    // An empty list of trusted apps: without it, the app that creates the item (swift-frontend, which runs
    // every `swift x.swift`) could read it back without asking.
    var access: SecAccess?
    guard SecAccessCreate(service as CFString, [] as CFArray, &access) == errSecSuccess, let access else {
        fail("Could not create the Keychain access rule.")
    }

    let status = add(key, access: access)

    guard status == errSecSuccess else { fail("Keychain error \(status)") }
}

/** Apps that may read the key without asking; nil if the access list cannot be read. "Always Allow" adds the asking app. */
func trustedApps() -> [String]? {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnRef: true]
    var out: CFTypeRef?
    var access: SecAccess?
    var list: CFArray?

    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let ref = out,
          SecKeychainItemCopyAccess(ref as! SecKeychainItem, &access) == errSecSuccess, let access,
          SecAccessCopyACLList(access, &list) == errSecSuccess else { return nil }

    var apps: [String] = []

    for acl in (list as? [SecACL]) ?? [] where (SecACLCopyAuthorizations(acl) as? [String] ?? []).contains("ACLAuthorizationDecrypt") {
        var trusted: CFArray?
        var description: CFString?
        var prompt = SecKeychainPromptSelector()
        SecACLCopyContents(acl, &trusted, &description, &prompt)

        guard let trusted = trusted as? [SecTrustedApplication] else {
            apps.append("any app")
            continue
        }

        for app in trusted {
            var path: CFData?
            SecTrustedApplicationCopyData(app, &path)
            apps.append(path.map { String(decoding: $0 as Data, as: UTF8.self).trimmingCharacters(in: .controlCharacters) } ?? "?")
        }
    }

    return apps
}

/** Rewrites the item with no trusted apps. The key stays the same, so earlier signatures stay valid. */
func lock(_ key: Curve25519.Signing.PrivateKey) {
    let deleted = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    guard deleted == errSecSuccess else { fail("Could not rewrite the key: Keychain error \(deleted)") }

    var access: SecAccess?
    let created = SecAccessCreate(service as CFString, [] as CFArray, &access)
    let status = created == errSecSuccess ? add(key, access: access) : created

    guard status != errSecSuccess else { return }

    // Never lose the key: put it back unprotected, and if even that fails, print it so it can be imported again.
    if add(key, access: nil) == errSecSuccess {
        fail("Could not protect the key (Keychain error \(status)). It is back, but any `swift` script can read it: run `lock` again.")
    }

    fail("""
        Could not write the key back (Keychain error \(status)). It is not in the Keychain now. Save this line and run `import`:
        \(key.rawRepresentation.base64EncodedString())
        """)
}

/** The public key the app is built with: signing with any other key would only produce updates nobody accepts. */
func appKey() -> String {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Updater.swift")

    guard let text = try? String(contentsOf: source, encoding: .utf8),
          let match = text.firstMatch(of: #/var publicKey = "([^"]+)"/#) else { fail("No publicKey in \(source.path)") }

    return String(match.1)
}

struct Refusal: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

/** Reads the key and hands it to the work; afterwards takes back an "Always Allow" given in the prompt, whatever happened. */
func withKey(_ work: (Curve25519.Signing.PrivateKey) throws -> Void) {
    guard let key = load() else {
        fail("No key in the Keychain. Restore it from the backup with `import`. Use `new` only if there is no backup: installed copies would stop updating.")
    }

    var failure: Error?
    do { try work(key) } catch { failure = error }

    if let trusted = trustedApps(), !trusted.isEmpty {
        lock(key)
        FileHandle.standardError.write("""
            "Always Allow" was pressed: \(trusted.joined(separator: ", ")) could read the key silently.
            That is taken back now. Next time press "Allow".

            """.data(using: .utf8)!)
    }

    if let failure { fail("\(failure.localizedDescription)") }
}

let args = CommandLine.arguments

switch args.count > 1 ? args[1] : "" {
case "new":
    let key = Curve25519.Signing.PrivateKey()
    store(key)

    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign" where args.count == 3:
    // Everything that can fail without the key is checked before macOS asks for the password.
    let zip = URL(fileURLWithPath: args[2])
    guard let data = try? Data(contentsOf: zip) else { fail("Cannot read \(zip.path)") }
    let expected = appKey()

    withKey { key in
        guard key.publicKey.rawRepresentation.base64EncodedString() == expected else {
            throw Refusal("The key in the Keychain does not match publicKey in Updater.swift: installed apps would reject this update.")
        }

        let out = zip.appendingPathExtension("sig")
        try (key.signature(for: data).base64EncodedString() + "\n").write(to: out, atomically: true, encoding: .utf8)
        print(out.path)
    }

case "lock":
    guard let trusted = trustedApps() else { fail("Cannot read the key's access list.") }

    if trusted.isEmpty {
        print("The key is protected: no app may read it without asking.")
        exit(0)
    }

    withKey { lock($0) }
    print(trustedApps() == [] ? "The key is protected again." : "Still trusted: \((trustedApps() ?? []).joined(separator: ", "))")

case "export":
    withKey { key in
        FileHandle.standardError.write("This is the private key. Keep it only in a password manager.\n".data(using: .utf8)!)
        print(key.rawRepresentation.base64EncodedString())
    }

case "import":
    guard let line = readLine(), let raw = Data(base64Encoded: line.trimmingCharacters(in: .whitespaces)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("Expected the base64 key from `export` on stdin.") }

    store(key)

    print(key.publicKey.rawRepresentation.base64EncodedString())

default:
    fail("Usage: swift scripts/update-key.swift new | sign <zip> | export | import | lock")
}
