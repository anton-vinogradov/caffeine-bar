import AppKit
import IOKit.ps
import IOKit.pwr_mgt

// UserIsActive keeps the display on, and powerd never idle-sleeps the system while the display is on.
let sleepTypes: Set<String> = [
    "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep", "UserIsActive",
]

// System processes that hold short or permanent assertions of their own; listing them is noise.
let systemHolders: Set<String> = ["powerd", "runningboardd", "WindowServer", "loginwindow"]

private let flagByType: [(type: String, flag: Character)] = [
    ("PreventUserIdleDisplaySleep", "d"),
    ("PreventUserIdleSystemSleep", "i"),
    ("PreventDiskIdle", "m"),
    ("PreventSystemSleep", "s"),
    ("UserIsActive", "u"),
]

/** Process holding power assertions, as powerd sees it. */
struct Holder {
    let pid: pid_t
    let name: String
    let types: Set<String>
    let endsAt: Date?
    let keepsAwake: Bool

    var flags: String { "-" + String(flagByType.filter { types.contains($0.type) }.map(\.flag)) }
}

/** Reads assertions of all processes; nil endsAt means no timeout. */
func readHolders() -> [Holder] {
    var ref: Unmanaged<CFDictionary>?

    guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
          let byPid = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }

    // PreventSystemSleep (caffeinate -s) is honoured on AC power only.
    let onBattery = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? == kIOPMBatteryPowerKey
    let effective = onBattery ? sleepTypes.subtracting(["PreventSystemSleep"]) : sleepTypes

    return byPid.map { pid, assertions in
        var types = Set<String>()
        var ends: [Date] = []
        var forever = false

        for a in assertions {
            let type = (a["AssertionTrueType"] ?? a["AssertType"]) as? String ?? ""
            types.insert(type)

            // AssertTimeoutTimeLeft is a snapshot taken at AssertTimeoutUpdateTime, not a live countdown.
            if let left = (a["AssertTimeoutTimeLeft"] as? NSNumber)?.doubleValue, left > 0,
               let at = a["AssertTimeoutUpdateTime"] as? Date {
                ends.append(at.addingTimeInterval(left))
            }
            else if sleepTypes.contains(type) {
                forever = true
            }
        }

        let name = assertions.first?["Process Name"] as? String ?? "pid \(pid)"

        return Holder(pid: pid.int32Value, name: name, types: types, endsAt: forever ? nil : ends.max(),
                      keepsAwake: !types.isDisjoint(with: effective))
    }
}

/** Who started a process and from which folder, as far as macOS still knows. */
struct Origin {
    enum Launcher {
        case running(name: String, pid: pid_t)
        case quit
        case unknown
    }

    let launcher: Launcher
    let folder: String?
    let startedAt: Date?
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

// Private libsystem call that TCC uses to charge a helper to its app. Unlike the parent pid, it survives
// `nohup … &`: the shell in between exits, launchd adopts the process, but the responsible app stays.
private let responsibleFor: ResponsibleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsibleFn.self) }

/** Start time, parent and group of any process, root's included: proc_pidinfo refuses other users, sysctl does not. */
private func kinfo(_ pid: pid_t) -> (start: Date, ppid: pid_t, pgid: pid_t)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }

    let t = info.kp_proc.p_starttime

    return (Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6), info.kp_eproc.e_ppid, info.kp_eproc.e_pgid)
}

/** Unique id of the parent a process was started by. Unlike ppid, it stays when launchd adopts an orphan. */
private func parentUniqueID(_ pid: pid_t) -> UInt64? {
    // PROC_PIDUNIQIDENTIFIERINFO (17) is private: a 16-byte uuid, then p_uniqueid and p_puniqueid.
    var raw = [UInt8](repeating: 0, count: 56)

    guard proc_pidinfo(pid, 17, 0, &raw, 56) == 56 else { return nil }

    return raw.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
}

private func workingDirectory(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)

    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }

    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }

    return path.isEmpty || path == "/" ? nil : (path as NSString).abbreviatingWithTildeInPath
}

/** Name of the app a process belongs to: the outermost bundle, so a helper is named after the app it serves. */
private func appName(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return NSRunningApplication(processIdentifier: pid)?.localizedName }

    let path = String(cString: buf)

    if let app = path.range(of: ".app/") {
        let outer = String(path[..<app.lowerBound]) + ".app"

        // LaunchServices knows the localized name ("Терминал"), but only for the app's own main process.
        if let running = NSRunningApplication(processIdentifier: pid), running.bundleURL?.path == outer, let name = running.localizedName {
            return name
        }

        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = Bundle(path: outer)?.infoDictionary?[key] as? String { return name }
        }
    }

    return (path as NSString).lastPathComponent
}

func origin(of pid: pid_t) -> Origin {
    guard let me = kinfo(pid) else { return Origin(launcher: .unknown, folder: nil, startedAt: nil) }

    var launcher = Origin.Launcher.unknown

    if let responsible = responsibleFor?(pid), responsible > 1, responsible != pid {
        // A dead launcher's pid may already belong to a newer process: only trust one that started first.
        if let other = kinfo(responsible), other.start <= me.start {
            launcher = .running(name: appName(responsible) ?? "pid \(responsible)", pid: responsible)
        }
        else {
            launcher = .quit
        }
    }
    else if me.ppid > 1 {
        launcher = .running(name: appName(me.ppid) ?? "pid \(me.ppid)", pid: me.ppid)
    }
    else {
        // Once the launcher exits, macOS makes the process responsible for itself and launchd adopts it.
        // A launchd job was started by launchd (unique id 1) and leads its own process group. An orphan fails
        // one of the two: it keeps its original parent's id, or, if the shell exited before its child's exec,
        // it still sits in the shell's process group.
        launcher = parentUniqueID(pid) == 1 && me.pgid == pid ? .running(name: "launchd", pid: 1) : .quit
    }

    return Origin(launcher: launcher, folder: workingDirectory(pid), startedAt: me.start)
}
