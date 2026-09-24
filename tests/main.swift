// Checks run by `./build.sh test` and before every signed release: a broken updater cannot be fixed remotely.
// Usage: tests <path to the built CaffeineBar executable>
import AppKit
import CryptoKit

var failures = 0

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print(ok ? "ok   \(what)" : "FAIL \(what) (tests/main.swift:\(line))")
    if !ok { failures += 1 }
}

func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try! p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func startTime(_ pid: pid_t) -> Date {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let t = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
}

guard CommandLine.arguments.count > 1 else {
    print("Usage: tests <path to the built CaffeineBar executable>")
    exit(2)
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("caffeinebar-tests-\(getpid())")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// Test bundles get their own id: LaunchServices registers every app it sees, and copies with the real id would
// compete with the installed app.
let testID = "io.github.anton-vinogradov.CaffeineBar.tests"

// Version order.
do {
    func updater(_ version: String) -> Updater {
        let app = tmp.appendingPathComponent("v\(version)-\(UUID()).app")
        try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try! (["CFBundleShortVersionString": version, "CFBundleIdentifier": "x"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return Updater(app: app)
    }

    check(updater("1.9.9").isNewer("1.10.0"), "1.10.0 is newer than 1.9.9")
    check(!updater("1.1.0").isNewer("1.1"), "1.1 equals 1.1.0")
    check(!updater("2.0.0").isNewer("1.99.99"), "1.99.99 is older than 2.0.0")
}

// The updater end to end, on file:// URLs with a throwaway key: no Keychain, no network.
func makeApp(at dir: URL, version: String, id: String, minimumOS: String = "15.0") -> URL {
    let app = dir.appendingPathComponent("CaffeineBar.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    try! FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try! FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: macos.appendingPathComponent("CaffeineBar"))
    let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleExecutable": "CaffeineBar", "CFBundleShortVersionString": version,
                               "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": minimumOS]
    plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    return app
}

func update(newID: String = testID, minimumOS: String = "15.0", tamper: Bool = false,
            signature: Bool = true) async -> (error: Error?, found: Bool, version: String?) {
    let root = tmp.appendingPathComponent("update-\(UUID())")
    let installedDir = root.appendingPathComponent("Applications"), releaseDir = root.appendingPathComponent("release")
    try! FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)

    let installed = makeApp(at: installedDir, version: "1.1.0", id: testID)
    let fresh = makeApp(at: releaseDir, version: "9.9.9", id: newID, minimumOS: minimumOS)
    let zip = root.appendingPathComponent("CaffeineBar-9.9.9.zip")
    _ = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", fresh.path, zip.path])

    let key = Curve25519.Signing.PrivateKey()
    var bytes = try! Data(contentsOf: zip)
    let sig = try! key.signature(for: bytes).base64EncodedString()
    if tamper {
        bytes[bytes.count / 2] ^= 0xFF
        try! bytes.write(to: zip)
    }
    let sigURL = root.appendingPathComponent("CaffeineBar-9.9.9.zip.sig")
    try! sig.write(to: sigURL, atomically: true, encoding: .utf8)

    var assets = [["name": "CaffeineBar-9.9.9.zip", "browser_download_url": zip.absoluteString]]
    if signature { assets.append(["name": "CaffeineBar-9.9.9.zip.sig", "browser_download_url": sigURL.absoluteString]) }
    let feed = root.appendingPathComponent("latest.json")
    try! JSONSerialization.data(withJSONObject: ["tag_name": "v9.9.9", "assets": assets]).write(to: feed)

    let updater = Updater(feed: feed, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), app: installed)
    let version = { NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String }

    do {
        guard let release = try await updater.newer() else { return (nil, false, version()) }
        try await updater.install(release)
        return (nil, true, version())
    }
    catch {
        return (error, true, version())
    }
}

func isError(_ error: Error?, _ expected: UpdateError) -> Bool {
    guard let error = error as? UpdateError else { return false }
    return "\(error)".hasPrefix("\(expected)".prefix { $0 != "(" })
}

let good = await update()
check(good.error == nil && good.version == "9.9.9", "a signed update replaces the bundle (now \(good.version ?? "?"))")
let tampered = await update(tamper: true)
check(isError(tampered.error, .badSignature) && tampered.version == "1.1.0", "a tampered zip is rejected, the old bundle stays")
let foreign = await update(newID: "com.example.Other")
check(isError(foreign.error, .badBundle) && foreign.version == "1.1.0", "another bundle id is rejected, the old bundle stays")
let tooNew = await update(minimumOS: "99.0")
check(isError(tooNew.error, .incompatible("")) && tooNew.version == "1.1.0", "a build for a newer macOS is rejected, the old bundle stays")
let unsigned = await update(signature: false)
check(unsigned.error == nil && !unsigned.found && unsigned.version == "1.1.0", "a release without a signature is not offered")

// caffeinate -w, read the way caffeinate's getopt reads it.
check(waitTarget(in: ["caffeinate", "-dimsu", "-t", "7200", "-w", "45113"]) == 45113, "-w 45113 after other options")
check(waitTarget(in: ["caffeinate", "-iw", "123"]) == 123, "-iw 123")
check(waitTarget(in: ["caffeinate", "-iw123"]) == 123, "-iw123")
check(waitTarget(in: ["caffeinate", "-t7200", "-i"]) == nil, "no -w")
check(waitTarget(in: ["caffeinate", "-w", "5", "make"]) == nil, "-w is ignored when a utility follows")
check(waitTarget(in: ["caffeinate", "-w", "5", "--"]) == 5, "-w 5 -- without a utility")
check(waitTarget(in: ["caffeinate", "-w", "5", "--", "make"]) == nil, "-w 5 -- make")
check(waitTarget(in: ["caffeinate", "-i", "-w", "0"]) == nil, "-w 0 means no -w, as a fresh zsh gives $! = 0")
check(waitTarget(in: ["caffeinate", "-w", "0x10"]) == 16, "-w reads the pid like strtol(…, 0)")

// Claude session files: only a file written for this very process counts.
do {
    let dir = tmp.appendingPathComponent("sessions")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let me = getpid()
    let started = startTime(me)
    let ctime = DateFormatter()
    ctime.locale = Locale(identifier: "en_US_POSIX")
    ctime.timeZone = TimeZone(identifier: "UTC")
    ctime.dateFormat = "EEE MMM d HH:mm:ss yyyy"

    func write(_ json: [String: Any]) {
        try! JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("\(me).json"))
    }

    write(["pid": me, "name": "Fix the build", "status": "idle", "statusUpdatedAt": 1_790_000_000_000, "procStart": ctime.string(from: started)])
    let s = claudeSession(pid: me, startedAt: started, dir: dir)
    check(s?.name == "Fix the build" && s?.status == "idle" && s?.statusSince != nil, "a session file of this process is read")

    write(["pid": me, "name": "Old session", "procStart": ctime.string(from: started.addingTimeInterval(-3600))])
    check(claudeSession(pid: me, startedAt: started, dir: dir) == nil, "a file left by an earlier process with this pid is ignored")

    write(["pid": me, "name": "", "procStart": ctime.string(from: started)])
    check(claudeSession(pid: me, startedAt: started, dir: dir) == nil, "a session without a name is ignored")

    // ctime pads one-digit days with a space: "Fri Sep  4 20:55:47 2026".
    let september4 = Date(timeIntervalSince1970: 1_788_555_347)
    write(["pid": me, "name": "Early September", "procStart": "Fri Sep  4 20:55:47 2026"])
    check(claudeSession(pid: me, startedAt: september4, dir: dir)?.name == "Early September", "a padded ctime date is parsed")
}

// powerd's view of our own caffeinate: undocumented keys (AssertTimeoutTimeLeft, AssertionTrueType) still there?
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
child.arguments = ["-i", "-t", "20", "-w", String(getpid())]
try! child.run()
try? await Task.sleep(for: .milliseconds(500))

let holder = readHolders().first { $0.pid == child.processIdentifier }
check(holder != nil, "readHolders sees our caffeinate")
check(holder?.types.contains("PreventUserIdleSystemSleep") == true && holder?.keepsAwake == true, "type and keepsAwake (\(holder?.flags ?? "-"))")
let left = holder?.endsAt.map { $0.timeIntervalSinceNow } ?? -1
check(abs(left - 19.5) < 2, "time left from powerd: \(String(format: "%.1f", left)) s, expected about 19.5")

let ours = origin(of: child.processIdentifier)
if case .running = ours.launcher { check(true, "our child has a running launcher") } else { check(false, "our child: \(ours.launcher)") }
check(ours.waitsFor?.pid == getpid(), "our child waits for us (-w)")
child.terminate()
child.waitUntilExit()

// "Launcher has quit": a shell that disclaims responsibility starts caffeinate in the background and exits.
typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
let disclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim").map { unsafeBitCast($0, to: Disclaim.self) }
check(disclaim != nil, "responsibility_spawnattrs_setdisclaim resolves")

func orphan(_ caffeinate: String) async -> pid_t? {
    guard let disclaim else { return nil }

    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    _ = disclaim(&attr, 1)
    let pidFile = tmp.appendingPathComponent("orphan-\(UUID())").path
    let argv: [String] = ["/bin/sh", "-c", "\(caffeinate) & echo $! > \(pidFile)"]
    var args = argv.map { strdup($0) } + [nil]
    var shell: pid_t = 0

    guard posix_spawn(&shell, "/bin/sh", nil, &attr, &args, environ) == 0 else { return nil }

    var status: Int32 = 0
    waitpid(shell, &status, 0)
    try? await Task.sleep(for: .milliseconds(500))
    return (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

if let pid = await orphan("/usr/bin/caffeinate -i -t 20") {
    let o = origin(of: pid)
    if case .quit = o.launcher { check(true, "an orphaned caffeinate says its launcher has quit") } else { check(false, "orphan: \(o.launcher)") }
    kill(pid, SIGTERM)
}
else {
    check(false, "could not start an orphan through a disclaiming shell")
}

if let pid = await orphan("/usr/bin/caffeinate -i -t 20 -w \(getpid())") {
    let o = origin(of: pid)
    if case .quit = o.launcher { check(false, "an orphan that waits for a live process is called left over") } else { check(true, "an orphan that waits for a live process is not called left over") }
    kill(pid, SIGTERM)
}

try? FileManager.default.removeItem(at: tmp)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
