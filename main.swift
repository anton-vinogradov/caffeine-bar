import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

// UserIsActive keeps the display on, and powerd never idle-sleeps the system while the display is on.
private let sleepTypes: Set<String> = [
    "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep", "UserIsActive",
]

// System processes that hold short or permanent assertions of their own; listing them is noise.
private let systemHolders: Set<String> = ["powerd", "runningboardd", "WindowServer", "loginwindow"]

private let flagByType: [(type: String, flag: Character)] = [
    ("PreventUserIdleDisplaySleep", "d"),
    ("PreventUserIdleSystemSleep", "i"),
    ("PreventDiskIdle", "m"),
    ("PreventSystemSleep", "s"),
    ("UserIsActive", "u"),
]

private let russian = Locale.preferredLanguages.first?.hasPrefix("ru") == true

/** Menu text in Russian on a Russian system, in English otherwise. */
private func tr(_ en: String, _ ru: String) -> String { russian ? ru : en }

private let durations: [(title: String, seconds: Int)] = [
    (tr("30 minutes", "30 минут"), 1800),
    (tr("1 hour", "1 час"), 3600),
    (tr("2 hours", "2 часа"), 7200),
    (tr("4 hours", "4 часа"), 14400),
    (tr("8 hours", "8 часов"), 28800),
    (tr("No limit", "Бессрочно"), 0),
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private let menu = NSMenu()

    private var own: Process?

    /** Deadline of own caffeinate in systemUptime: like caffeinate's -t timer, it stands still while the Mac sleeps. */
    private var ownDeadline: TimeInterval?

    private var holders: [Holder] = []

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var allowDisplaySleep: Bool {
        get { UserDefaults.standard.bool(forKey: "allowDisplaySleep") }
        set { UserDefaults.standard.set(newValue, forKey: "allowDisplaySleep") }
    }

    private var ownLeft: TimeInterval? {
        ownDeadline.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) }
    }

    private var foreign: [Holder] {
        holders.filter { $0.name == "caffeinate" && $0.keepsAwake && $0.pid != own?.processIdentifier }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refresh()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationWillTerminate(_ note: Notification) {
        own?.terminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again is the only way in when a full menu bar has hidden the icon behind the notch.
        let alert = NSAlert()
        alert.messageText = summary()
        alert.informativeText = tr(
            "If you cannot see the icon in the menu bar, the notch hides it: hold ⌘ and drag icons, or hide some in System Settings → Menu Bar.",
            "Если значка не видно в строке меню, его закрыл вырез экрана: перетащите значки с зажатой ⌘ или скройте лишние в Настройках → Строка меню.")
        alert.addButton(withTitle: own == nil ? tr("Keep awake", "Не давать спать") : tr("Turn off", "Выключить"))
        alert.addButton(withTitle: tr("Close", "Закрыть"))

        NSApp.activate()

        if alert.runModal() == .alertFirstButtonReturn {
            toggleOwn()
        }

        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        let ownPid = own?.processIdentifier

        let caffeinates = holders
            .filter { $0.name == "caffeinate" }
            .sorted { ($0.endsAt ?? .distantFuture) > ($1.endsAt ?? .distantFuture) }

        let others = Set(holders.filter { $0.name != "caffeinate" && !systemHolders.contains($0.name) && $0.keepsAwake }.map(\.name))

        for line in summary().split(separator: "\n") {
            menu.addItem(withTitle: String(line), action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())

        let toggle = entry(tr("Keep awake", "Не давать спать") + (own == nil ? "" : " — \(until(ownLeft))"), #selector(toggleFromMenu))
        toggle.state = own == nil ? .off : .on
        toggle.representedObject = own != nil
        menu.addItem(toggle)

        let timed = NSMenu()
        for d in durations {
            let it = entry(d.title, #selector(startTimed))
            it.representedObject = d.seconds
            timed.addItem(it)
        }
        let timedItem = NSMenuItem(title: tr("Keep awake for…", "Включить на…"), action: nil, keyEquivalent: "")
        timedItem.submenu = timed
        menu.addItem(timedItem)

        let display = entry(tr("Display may sleep", "Экран может гаснуть"), #selector(toggleDisplaySleep))
        display.state = allowDisplaySleep ? .on : .off
        menu.addItem(display)

        if !caffeinates.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: tr("caffeinate now", "caffeinate сейчас")))

            for h in caffeinates {
                let mine = h.pid == ownPid

                var title = "\(h.flags) · \(until(mine ? ownLeft : h.endsAt.map { $0.timeIntervalSinceNow }))"
                if mine { title += tr(" · mine", " · моё") }
                if !h.keepsAwake { title += tr(" · does not block sleep", " · сон не держит") }

                let stop = entry(tr("Stop", "Остановить") + " (pid \(h.pid))", #selector(stopHolder))
                stop.representedObject = h.pid
                let sub = NSMenu()
                sub.addItem(stop)

                let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                it.submenu = sub
                menu.addItem(it)
            }

            if caffeinates.count > 1 {
                menu.addItem(entry(tr("Stop all caffeinate", "Остановить все caffeinate"), #selector(stopAll)))
            }
        }

        if !others.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: tr("Also blocking idle sleep", "Ещё не дают уснуть")))

            for name in others.sorted() {
                menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
            }
        }

        menu.addItem(.separator())

        let login = entry(tr("Start at login", "Запускать при входе"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: tr("Quit", "Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || !event.modifierFlags.isDisjoint(with: [.control, .option]) {
            item.menu = menu
            item.button?.performClick(nil)
        }
        else {
            toggleOwn()
        }
    }

    private func toggleOwn() {
        own == nil ? start(for: nil) : stop()
    }

    @objc private func toggleFromMenu(_ sender: NSMenuItem) {
        // Act on what the menu showed: a timer may have run out while the menu was open.
        if sender.representedObject as? Bool == true {
            stop()
        }
        else {
            start(for: nil)
        }
    }

    @objc private func startTimed(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }

        start(for: seconds > 0 ? seconds : nil)
    }

    @objc private func toggleDisplaySleep() {
        allowDisplaySleep.toggle()

        if own != nil {
            start(for: ownLeft.map { max(1, Int($0.rounded(.up))) })
        }
    }

    @objc private func stopHolder(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t else { return }

        stop(pids: [pid])
    }

    @objc private func stopAll() {
        stop(pids: readHolders().filter { $0.name == "caffeinate" }.map(\.pid))
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp

        do {
            if service.status == .enabled {
                try service.unregister()
            }
            else {
                try service.register()
            }
        }
        catch {
            show(error)
        }

        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func start(for seconds: Int?) {
        stop()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")

        // -w ties caffeinate to this app, so it dies with us even on a crash or kill -9.
        var args = [allowDisplaySleep ? "-ims" : "-dims", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if let seconds { args += ["-t", String(seconds)] }
        p.arguments = args

        p.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self else { return }

                if self.own === ended {
                    self.own = nil
                    self.ownDeadline = nil
                }

                self.refresh()
            }
        }

        do {
            try p.run()
        }
        catch {
            show(error)
            return
        }

        own = p
        ownDeadline = seconds.map { ProcessInfo.processInfo.systemUptime + TimeInterval($0) }

        refresh()
    }

    private func stop() {
        guard let p = own else { return }

        own = nil
        ownDeadline = nil

        p.terminate()
        p.waitUntilExit()

        refresh()
    }

    private func stop(pids: [pid_t]) {
        // The menu may be stale: re-check that each pid is still a caffeinate before signalling it.
        let alive = Set(readHolders().filter { $0.name == "caffeinate" }.map(\.pid))

        for pid in pids where alive.contains(pid) {
            if pid == own?.processIdentifier {
                stop()
            }
            else if kill(pid, SIGTERM) != 0 {
                // Most likely a caffeinate started by root or another user.
                NSSound.beep()
            }
        }

        // powerd drops the killed processes' assertions a moment later.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refresh()
        }
    }

    private func refresh() {
        holders = readHolders()

        let symbol = own != nil ? "cup.and.heat.waves.fill" : foreign.isEmpty ? "cup.and.saucer" : "cup.and.heat.waves"

        let text = summary()

        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        img?.isTemplate = true

        item.button?.image = img
        item.button?.toolTip = text + tr("\nClick: on/off. Right-click: menu", "\nКлик — вкл/выкл, правый клик — меню")
    }

    private func summary() -> String {
        let n = foreign.count

        if own == nil {
            return n > 0
                ? tr("No idle sleep: other caffeinate × \(n)", "Не уснёт от простоя: чужие caffeinate × \(n)")
                : tr("No caffeinate running", "caffeinate не запущен")
        }

        let mine = tr("No idle sleep: on here, ", "Не уснёт от простоя: включено здесь, ") + until(ownLeft)

        return n > 0 ? mine + tr("\nPlus other caffeinate × \(n)", "\nПлюс чужие caffeinate × \(n)") : mine
    }

    private func until(_ left: TimeInterval?) -> String {
        guard let left else { return tr("no limit", "бессрочно") }

        let minutes = (max(0, Int(left)) + 59) / 60
        let h = "\(minutes / 60) " + tr("h", "ч"), m = "\(minutes % 60) " + tr("min", "мин")
        let rest = minutes < 60 ? m : minutes % 60 == 0 ? h : "\(h) \(m)"
        let end = clock.string(from: Date().addingTimeInterval(left))

        return tr("\(rest) left, until \(end)", "ещё \(rest), до \(end)")
    }

    private func show(_ error: Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
