import AppKit
import CryptoKit

/** A newer GitHub release that carries a signed zip. */
struct Release {
    let version: String
    let page: URL
    let zip: URL
    let signature: URL
}

enum UpdateError: LocalizedError {
    case badFeed
    case http(Int)
    case badSignature
    case badBundle
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case .badFeed:
            tr("GitHub returned an unexpected answer.", "GitHub вернул неожиданный ответ.")
        case .http(403), .http(429):
            tr("GitHub limits requests from this network right now. Try again in an hour.",
               "GitHub сейчас ограничивает запросы из этой сети. Попробуйте через час.")
        case .http(let code):
            tr("GitHub answered with HTTP \(code).", "GitHub ответил HTTP \(code).")
        case .badSignature:
            tr("The update is not signed by the author. Nothing was installed. Do not install this version by hand.",
               "Обновление подписано не автором. Ничего не установлено. Не ставьте эту версию вручную.")
        case .badBundle:
            tr("The update archive does not contain the expected app. Nothing was installed.",
               "В архиве обновления не то приложение. Ничего не установлено.")
        case .incompatible(let reason):
            reason
        }
    }
}

/**
 * Checks GitHub for a newer release and swaps the app bundle for it.
 * The zip must carry an Ed25519 signature made by scripts/update-key.swift: without it, whoever took over
 * the GitHub account could push code to every installed copy. Nothing from the API answer except the tag and
 * the asset list is trusted, and page links are built from the repository name, not taken from the answer.
 */
struct Updater {
    static let repo = "anton-vinogradov/caffeine-bar"

    var feed = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!

    var publicKey = "l9oDoBmudJygOVR7rlsOICROr9B4uVxs5DL8fNvzPKA="

    var app = Bundle.main.bundleURL

    var current: String {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /** The latest release if it is newer than this copy and carries a signed zip, else nil. */
    func newer() async throws -> Release? {
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CaffeineBar/\(current)", forHTTPHeaderField: "User-Agent")

        guard let json = (try? JSONSerialization.jsonObject(with: try await fetch(request))) as? [String: Any],
              let tag = json["tag_name"] as? String,
              tag.range(of: #"^v?\d+(\.\d+)*$"#, options: .regularExpression) != nil,
              let assets = json["assets"] as? [[String: Any]] else { throw UpdateError.badFeed }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        guard isNewer(version) else { return nil }

        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }

        // A release without its signature could only be installed by hand, and that is exactly what an attacker
        // with the GitHub account would ask for: such a release is not offered at all.
        guard let zip = asset("CaffeineBar-\(version).zip"), let signature = asset("CaffeineBar-\(version).zip.sig") else { return nil }

        return Release(version: version, page: URL(string: "https://github.com/\(Updater.repo)/releases/tag/\(tag)")!,
                       zip: zip, signature: signature)
    }

    func isNewer(_ version: String) -> Bool {
        let theirs = version.split(separator: ".").map { Int($0) ?? 0 }
        let ours = current.split(separator: ".").map { Int($0) ?? 0 }

        for i in 0..<max(theirs.count, ours.count) {
            let a = i < theirs.count ? theirs[i] : 0, b = i < ours.count ? ours[i] : 0
            if a != b { return a > b }
        }

        return false
    }

    /** Downloads and verifies the release, then replaces the app bundle in place. The caller relaunches. */
    func install(_ release: Release) async throws {
        let zip = try await fetch(URLRequest(url: release.zip))
        let sig = try await fetch(URLRequest(url: release.signature))

        guard let key = Data(base64Encoded: publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
              let signature = Data(base64Encoded: String(decoding: sig, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(signature, for: zip) else { throw UpdateError.badSignature }

        // Same volume as the app, so the final swap is a rename.
        let tmp = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = tmp.appendingPathComponent("update.zip")
        try zip.write(to: archive)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, tmp.path]
        try ditto.run()
        ditto.waitUntilExit()

        let fresh = tmp.appendingPathComponent("CaffeineBar.app")

        guard ditto.terminationStatus == 0,
              let bundle = Bundle(url: fresh),
              bundle.bundleIdentifier == Bundle(url: app)?.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw UpdateError.badBundle
        }

        try checkRuns(bundle)

        _ = try FileManager.default.replaceItemAt(app, withItemAt: fresh)
    }

    /** Refuses a build this Mac cannot start: the old copy is gone once the bundles are swapped. */
    private func checkRuns(_ bundle: Bundle) throws {
        let minimum = (bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "0")
            .split(separator: ".").map { Int($0) ?? 0 }
        let needed = OperatingSystemVersion(majorVersion: minimum.first ?? 0,
                                            minorVersion: minimum.count > 1 ? minimum[1] : 0,
                                            patchVersion: minimum.count > 2 ? minimum[2] : 0)

        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) else {
            let v = minimum.map(String.init).joined(separator: ".")
            throw UpdateError.incompatible(tr("This version needs macOS \(v) or later.", "Этой версии нужна macOS \(v) или новее."))
        }

        #if arch(arm64)
        let arch = NSBundleExecutableArchitectureARM64
        #else
        let arch = NSBundleExecutableArchitectureX86_64
        #endif

        guard bundle.executableArchitectures?.contains(NSNumber(value: arch)) == true else {
            throw UpdateError.incompatible(tr("This version does not run on this Mac's processor.", "Эта версия не работает на процессоре этого мака."))
        }
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }

        return data
    }
}
