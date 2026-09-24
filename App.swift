import AppKit
import ServiceManagement

// The bundle's own pick among its localizations: the same one AppKit uses for system buttons such as OK.
private let russian = Bundle.main.preferredLocalizations.first == "ru"

/** Menu text in Russian on a Russian system, in English otherwise. */
func tr(_ en: String, _ ru: String) -> String { russian ? ru : en }

private let durations: [(title: String, seconds: Int)] = [
    (tr("30 minutes", "30 минут"), 1800),
    (tr("1 hour", "1 час"), 3600),
    (tr("2 hours", "2 часа"), 7200),
    (tr("4 hours", "4 часа"), 14400),
    (tr("8 hours", "8 часов"), 28800),
    (tr("No limit", "Бессрочно"), 0),
]

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private let menu = NSMenu()

    private var own: Process?

    /** Deadline of own caffeinate in systemUptime: like caffeinate's -t timer, it stands still while the Mac sleeps. */
    private var ownDeadline: TimeInterval?

    private var holders: [Holder] = []

    private var shown = ""

    private let updater = Updater()

    private var update: Release?

    private var checking = false

    private var installing = false

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
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

        resume()
        refresh()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)

        // A Timer counts awake time only, so "once a day" is judged by the wall clock, hourly and on wake.
        let hourly = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(hourly, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }

        present(after: 1) { [weak self] in
            self?.welcomeOnFirstLaunch()
            self?.checkIfDue()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        own?.terminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again is the only way in when a full menu bar has hidden the icon behind the notch.
        let wasOn = own != nil

        let alert = NSAlert()
        alert.messageText = summary()
        alert.informativeText = tr(
            "If you cannot see the icon in the menu bar, the notch hides it: hold ⌘ and drag icons, or hide some in System Settings → Menu Bar.",
            "Если значка не видно в строке меню, его закрыл вырез экрана: перетащите значки с зажатой ⌘ или скройте лишние в Системных настройках → Строка меню.")
        alert.addButton(withTitle: wasOn ? tr("Turn off", "Выключить") : tr("Keep awake", "Не давать спать"))
        alert.addButton(withTitle: tr("Close", "Закрыть"))

        // Act on what the button said: a timer may run out while the alert is open.
        if ask(alert) == .alertFirstButtonReturn {
            wasOn ? stop() : start(for: nil)
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

        if let update {
            menu.addItem(installing
                ? NSMenuItem(title: tr("Installing \(update.version)…", "Устанавливаю \(update.version)…"), action: nil, keyEquivalent: "")
                : entry(tr("Update to \(update.version)…", "Обновить до \(update.version)…"), #selector(offerUpdate)))
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
                menu.addItem(caffeinateItem(h, mine: h.pid == ownPid))
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

        menu.addItem(checking
            ? NSMenuItem(title: tr("Checking for updates…", "Проверяю обновления…"), action: nil, keyEquivalent: "")
            : entry(tr("Check for updates", "Проверить обновления"), #selector(checkNow)))

        menu.addItem(NSMenuItem(title: tr("Quit", "Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    /** One caffeinate: who started it and the time left; the details and Stop go into its submenu. */
    private func caffeinateItem(_ h: Holder, mine: Bool) -> NSMenuItem {
        let o = origin(of: h.pid)
        let place = o.folder.map { ($0 as NSString).lastPathComponent }

        var who: String
        var details: [String] = []

        switch o.launcher {
        case _ where mine:
            who = tr("This app", "Это приложение")
        case .running(let name, let pid):
            who = place.map { "\(name) (\($0))" } ?? name
            details.append(tr("Started by", "Запустил") + ": \(name), pid \(pid)")
        case .quit:
            who = tr("Launcher has quit", "Запустивший уже закрыт") + (place.map { " (\($0))" } ?? "")
            details.append(tr("Started by: a process that has quit", "Запустил: процесс, который уже закрыт"))
        case .unknown:
            who = tr("Unknown launcher", "Запустивший неизвестен") + (place.map { " (\($0))" } ?? "")
        }

        if let folder = o.folder { details.append(tr("Folder", "Папка") + ": \(folder)") }

        if let at = o.startedAt {
            let when = Calendar.current.isDateInToday(at) ? clock.string(from: at) : day.string(from: at)
            details.append(tr("Started", "Запущен") + ": \(when)")
        }

        details.append(tr("Flags", "Флаги") + ": \(h.flags)")

        var title = "\(who) · \(until(mine ? ownLeft : h.endsAt.map { $0.timeIntervalSinceNow }))"
        if !h.keepsAwake { title += tr(" · does not block sleep", " · сон не держит") }

        let sub = NSMenu()
        for line in details {
            sub.addItem(withTitle: line, action: nil, keyEquivalent: "")
        }
        sub.addItem(.separator())

        let stop = entry(tr("Stop", "Остановить") + " (pid \(h.pid))", #selector(stopHolder))
        stop.representedObject = h.pid
        sub.addItem(stop)

        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
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
        setLogin(SMAppService.mainApp.status != .enabled)
    }

    private func setLogin(_ on: Bool) {
        let service = SMAppService.mainApp

        do {
            if on {
                try service.register()
            }
            else {
                try service.unregister()
            }
        }
        catch {
            show(error, title: tr("Could not change the login items", "Не удалось изменить автозапуск"))
        }

        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func welcomeOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "welcomed") else { return }

        UserDefaults.standard.set(true, forKey: "welcomed")

        guard SMAppService.mainApp.status != .enabled else { return }

        let alert = NSAlert()
        alert.messageText = tr("CaffeineBar is in the menu bar", "CaffeineBar — в строке меню")
        alert.informativeText = tr(
            "Click the cup to keep the Mac awake or to let it sleep again. Right-click opens the menu.\n\nStart CaffeineBar when you log in?",
            "Клик по чашке не даёт маку уснуть и снова разрешает сон. Правый клик открывает меню.\n\nЗапускать CaffeineBar при входе в систему?")
        alert.addButton(withTitle: tr("Start at login", "Запускать при входе"))
        alert.addButton(withTitle: tr("Not now", "Не сейчас"))

        if ask(alert) == .alertFirstButtonReturn {
            setLogin(true)
        }
    }

    @objc private func checkNow() {
        checkForUpdates(manual: true)
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast

        // abs: a check saved while the clock ran ahead must not silence the next ones until that date.
        if abs(Date().timeIntervalSince(last)) > 23 * 3600 {
            checkForUpdates(manual: false)
        }
    }

    private func checkForUpdates(manual: Bool) {
        guard !checking else { return }

        checking = true

        Task {
            do {
                let found = try await updater.newer()
                update = found?.version == UserDefaults.standard.string(forKey: "rejectedVersion") ? nil : found
                checking = false
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                refresh()

                guard manual else { return }

                present { [self] in
                    if update != nil {
                        offerUpdate()
                    }
                    else {
                        let alert = NSAlert()
                        alert.messageText = tr("CaffeineBar \(updater.current) is the latest version", "CaffeineBar \(updater.current) — последняя версия")
                        ask(alert)
                    }
                }
            }
            catch {
                checking = false

                if manual {
                    present { [self] in show(error, title: tr("Could not check for updates", "Не удалось проверить обновления")) }
                }
            }
        }
    }

    @objc private func offerUpdate() {
        guard let release = update, !installing else { return }

        let alert = NSAlert()
        alert.messageText = tr("CaffeineBar \(release.version) is available", "Доступна версия CaffeineBar \(release.version)")
        alert.informativeText = tr(
            "You have \(updater.current). The app downloads the new version, checks the author's signature and restarts.",
            "У вас \(updater.current). Приложение скачает новую версию, проверит подпись автора и перезапустится.")
        alert.addButton(withTitle: tr("Install and restart", "Установить и перезапустить"))
        alert.addButton(withTitle: tr("What's new", "Что нового"))
        alert.addButton(withTitle: tr("Later", "Позже"))

        switch ask(alert) {
        case .alertFirstButtonReturn:
            install(release)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    private func install(_ release: Release) {
        guard !installing else { return }

        installing = true

        Task {
            do {
                try await updater.install(release)
                relaunch()
            }
            catch {
                installing = false

                // A bad signature, a wrong archive or a build for another Mac will not get better on retry.
                if error is UpdateError {
                    UserDefaults.standard.set(release.version, forKey: "rejectedVersion")
                    update = nil
                    refresh()
                }

                present { [self] in show(error, title: tr("The update was not installed", "Обновление не установлено")) }
            }
        }
    }

    /** Starts the new copy once this process is gone and hands it the time left on own caffeinate. */
    private func relaunch() {
        var open = [Bundle.main.bundlePath]

        if own != nil {
            // Arguments, not saved state: if the new copy never starts, nothing is left to resume by surprise later.
            open += ["--args", "--resume", String(ownLeft.map { max(1, Int($0.rounded(.up))) } ?? 0)]
        }

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$@\"", "sh"] + open
        try? sh.run()

        NSApp.terminate(nil)
    }

    /** `--resume <seconds>` from relaunch(): 0 means no time limit. */
    private func resume() {
        let args = CommandLine.arguments

        guard let i = args.firstIndex(of: "--resume"), i + 1 < args.count, let seconds = Int(args[i + 1]) else { return }

        start(for: seconds > 0 ? seconds : nil)
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
            show(error, title: tr("Could not start caffeinate", "Не удалось запустить caffeinate"))
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

        var text = summary()
        if let update { text += tr("\nUpdate available: \(update.version)", "\nЕсть обновление: \(update.version)") }

        // Redrawing the status item costs ~20x more than reading the assertions, so skip it when nothing changed.
        guard symbol + text != shown else { return }
        shown = symbol + text

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

    /**
     * Shows UI from a run loop source. A modal alert inside a main-queue Task would hold up all other
     * main-queue work, such as caffeinate exit handlers, until it closes.
     */
    private func present(after delay: TimeInterval = 0, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /** Runs a modal alert in front: an accessory app is not active on its own, so keys would go elsewhere. */
    @discardableResult
    private func ask(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }

    private func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        ask(alert)
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }
}
