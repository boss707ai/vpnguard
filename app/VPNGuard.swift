// VPN Guard — иконка в строке меню: статус защиты и пульт (пауза / выключить / включить).
// Защита живёт в root-демоне local.vpnguard; приложение читает статус, показывает уведомления сторожа
// и отдаёт команды CLI. Ещё оно раз в 10 с передаёт сторожу адреса серверов из настроек VPN-клиента
// (`vpnguard sync`, адаптер клиента): данные других приложений macOS отдаёт только приложениям
// пользователя с разрешением.
import AppKit

let base = "/Library/Application Support/VPNGuard"
let cli = base + "/vpnguard"
let statusPath = base + "/status"
let eventsPath = base + "/events"

enum GuardState: Equatable {
    case on, blocked, paused(until: Int), off, broken, hung, degraded(String)
}

struct Status {
    var mode = "", until = 0, rules = "", hook = "", pf = "", heartbeat = 0, servers = "", variant = "", provider = ""

    static func read() -> Status? {
        guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return nil }
        var s = Status()
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "mode": s.mode = kv[1]
            case "until": s.until = Int(kv[1]) ?? 0
            case "rules": s.rules = kv[1]
            case "hook": s.hook = kv[1]
            case "pf": s.pf = kv[1]
            case "heartbeat": s.heartbeat = Int(kv[1]) ?? 0
            case "servers": s.servers = kv[1]
            case "variant": s.variant = kv[1]
            case "provider": s.provider = kv[1]
            default: break
            }
        }
        return s
    }
}

func now() -> Int { Int(Date().timeIntervalSince1970) }

// Название VPN-клиента из адаптера (сторож пишет его в статус)
func clientTitle(_ s: Status? = Status.read()) -> String {
    let p = s?.provider ?? ""
    return p.isEmpty ? "VPN-клиент" : p
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func defaultRouteIsTunnel() -> Bool {
    let (_, out) = run("/sbin/route", ["-n", "get", "default"])
    for line in out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("interface:") else { continue }
        let name = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
        return name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }
    return false
}

func currentState() -> GuardState {
    guard let s = Status.read(), now() - s.heartbeat <= 30 else { return .broken }
    if s.pf == "hung" { return .hung }
    switch s.mode {
    case "off": return .off
    case "paused": return .paused(until: s.until)
    case "on":
        if s.rules != "loaded" || s.pf != "Enabled" || s.hook != "present" { return .broken }
        switch s.variant {
        case "noclient": return .degraded("pf не принял адреса серверов из \(clientTitle(s)) — VPN может не подключиться")
        case "noru": return .degraded("Список российских сетей не загрузился — российские сайты напрямую не откроются")
        case "emergency", "bare": return .degraded("Правила защиты повреждены — работает аварийный набор. Поставь защиту заново")
        default: break
        }
        if s.servers.isEmpty { let t = clientTitle(s); return .degraded("Нет адресов VPN-серверов из \(t) — \(t) не подключится. Меню → «Взять адреса из \(t) сейчас»") }
        return defaultRouteIsTunnel() ? .on : .blocked
    default: return .broken
    }
}

func fmtLeft(_ secs: Int) -> String {
    let s = max(0, secs)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

// Экранирование для строкового литерала AppleScript.
func asEsc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func notify(_ text: String) {
    DispatchQueue.global().async {
        run("/usr/bin/osascript", ["-e", "display notification \"\(asEsc(text))\" with title \"VPN Guard\""])
    }
}

// Уведомления сторожа: строки «номер<TAB>время<TAB>текст» в events.
struct GuardEvent { let seq: Int; let time: Int; let text: String }

func readEvents() -> [GuardEvent] {
    guard let text = try? String(contentsOfFile: eventsPath, encoding: .utf8) else { return [] }
    var out: [GuardEvent] = []
    for line in text.split(separator: "\n") {
        let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
        if f.count == 3, let n = Int(f[0]), let t = Int(f[1]) { out.append(GuardEvent(seq: n, time: t, text: f[2])) }
    }
    return out
}

func fileStamp(_ path: String) -> String {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
    return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\(a[.size] ?? 0)"
}

// Вид состояния без срока паузы: повторная пауза — не новое событие.
func kind(_ s: GuardState) -> String {
    switch s {
    case .on: return "on"
    case .blocked: return "blocked"
    case .paused: return "paused"
    case .off: return "off"
    case .broken: return "broken"
    case .hung: return "hung"
    case .degraded: return "degraded"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var state: GuardState = .broken
    var started = false
    var warnedMinute = false
    var announced: GuardState = .broken   // состояние, о котором уже сообщили
    var candidate: GuardState = .broken
    var candidateTicks = 0
    var lastEventSeq = 0
    var eventsStamp = ""
    var syncing = false

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        item.menu = menu
        // Прочитанное помним между запусками: уведомления, пришедшие до входа в систему или пока иконка
        // была скрыта, покажем сейчас (за последние сутки). Первый запуск — старое считаем прочитанным.
        let all = readEvents()
        let maxSeq = all.map { $0.seq }.max() ?? 0
        if let saved = UserDefaults.standard.object(forKey: "lastEventSeq") as? Int, saved <= maxSeq {
            lastEventSeq = saved
            eventsStamp = ""        // checkEvents при первом refresh покажет непрочитанное
        } else {
            lastEventSeq = maxSeq
            eventsStamp = fileStamp(eventsPath)
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        syncClient()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.syncClient() }
    }

    // Адреса серверов из VPN-клиента → сторожу. Первый раз macOS спросит разрешение читать данные клиента.
    func syncClient() {
        guard !syncing else { return }
        syncing = true
        DispatchQueue.global().async {
            run(cli, ["sync", "-q"])
            DispatchQueue.main.async { self.syncing = false }
        }
    }

    func checkEvents() {
        let stamp = fileStamp(eventsPath)
        guard stamp != eventsStamp else { return }
        eventsStamp = stamp
        let all = readEvents()
        let newest = all.map { $0.seq }.max() ?? 0
        if newest < lastEventSeq { lastEventSeq = 0 }   // журнал событий начат заново (переустановка)
        let fresh = all.filter { $0.seq > lastEventSeq && now() - $0.time <= 86400 }
        lastEventSeq = max(lastEventSeq, newest)
        UserDefaults.standard.set(lastEventSeq, forKey: "lastEventSeq")
        for e in fresh.prefix(3) { notify(e.text) }
        if fresh.count > 3 { notify("И ещё уведомлений: \(fresh.count - 3). Все — в меню VPN Guard и в vpnguard status") }
    }

    func refresh() {
        let new = currentState()
        // уведомляем, только если состояние продержалось 3 с: после сна и при смене сети бывают секундные провалы
        if kind(new) == kind(candidate) { candidateTicks += 1 } else { candidate = new; candidateTicks = 1 }
        if !started {
            announced = new
        } else if candidateTicks >= 3 && kind(candidate) != kind(announced) {
            announce(from: announced, to: candidate)
            announced = candidate
        }
        if case .paused(let until) = new {
            let left = until - now()
            if left > 0 && left <= 60 && !warnedMinute { warnedMinute = true; notify("Через минуту защита включится снова.") }
        } else {
            warnedMinute = false
        }
        state = new
        started = true
        checkEvents()
        draw()
    }

    func announce(from old: GuardState, to new: GuardState) {
        switch (old, new) {
        case (.on, .blocked):
            let t = clientTitle()
            notify("\(t) выключен — интернет закрыт защитой. Включи \(t).")
        case (.paused(_), .on), (.paused(_), .blocked), (.off, .on), (.off, .blocked):
            notify("Защита снова включена.")
        case (_, .broken):
            notify("Сторож защиты не отвечает. Проверь: vpnguard status")
        default:
            break
        }
    }

    // (SF Symbol, текст рядом со значком, подсказка)
    func look() -> (String, String, String) {
        switch state {
        case .on: return ("checkmark.shield.fill", "", "Защита включена · VPN работает")
        case .blocked: return ("exclamationmark.shield.fill", "", "VPN выключен — интернет закрыт защитой")
        case .paused(let until): return ("pause.circle", " " + fmtLeft(until - now()), "Пауза защиты")
        case .off: return ("shield.slash", "", "Защита выключена")
        case .broken: return ("exclamationmark.triangle.fill", "", "Сторож защиты не отвечает")
        case .hung: return ("exclamationmark.octagon.fill", "", "pf не отвечает — похоже, зависло ядро. Сохрани работу и перезагрузи Mac")
        case .degraded(let why): return ("shield.lefthalf.filled", "", why)
        }
    }

    func draw() {
        guard let b = item.button else { return }
        let (symbol, title, tip) = look()
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        img?.isTemplate = true
        b.image = img
        b.title = title
        b.imagePosition = .imageLeading
        b.toolTip = tip
    }

    func headerText() -> String {
        switch state {
        case .on: return "Защита включена · VPN работает"
        case .blocked: return "Защита включена · VPN выключен — интернет закрыт"
        case .paused(let until):
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "Пауза до \(f.string(from: Date(timeIntervalSince1970: TimeInterval(until))))"
        case .off: return "Защита выключена"
        case .broken: return "Сторож защиты не отвечает"
        case .hung: return "pf не отвечает — похоже, зависло ядро. Сохрани работу и перезагрузи Mac"
        case .degraded(let why): return "Защита включена, но: " + why
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        var protecting = state == .on || state == .blocked
        if case .degraded = state { protecting = true }
        let stuck = state == .broken || state == .hung   // сторож или pf не отвечают — команды не дойдут
        if !protecting && state != .hung { menu.addItem(action("Включить", #selector(turnOn))) }
        if !stuck {
            menu.addItem(action("Пауза 15 мин", #selector(pause15)))
            let sub = NSMenu()
            for (t, arg) in [("5 мин", "5m"), ("30 мин", "30m"), ("1 час", "1h"), ("3 часа", "3h")] {
                let mi = action(t, #selector(pauseFor(_:)))
                mi.representedObject = arg
                sub.addItem(mi)
            }
            let subItem = NSMenuItem(title: "Пауза на…", action: nil, keyEquivalent: "")
            subItem.submenu = sub
            menu.addItem(subItem)
            if state != .off { menu.addItem(action("Выключить совсем", #selector(turnOff))) }
        }
        menu.addItem(.separator())
        menu.addItem(action("Проверить защиту", #selector(selfTest)))
        menu.addItem(action("Взять адреса из \(clientTitle()) сейчас", #selector(clientNow)))
        let recent = readEvents().suffix(5).reversed()
        if !recent.isEmpty {
            let sub = NSMenu()
            let f = DateFormatter()
            f.dateFormat = "dd.MM HH:mm"
            for e in recent {
                let t = e.text.count > 90 ? String(e.text.prefix(90)) + "…" : e.text
                let mi = NSMenuItem(title: f.string(from: Date(timeIntervalSince1970: TimeInterval(e.time))) + "  " + t, action: nil, keyEquivalent: "")
                mi.toolTip = e.text
                sub.addItem(mi)
            }
            let subItem = NSMenuItem(title: "Последние уведомления", action: nil, keyEquivalent: "")
            subItem.submenu = sub
            menu.addItem(subItem)
        }
        menu.addItem(action("Памятка", #selector(openGuide)))
        menu.addItem(.separator())
        menu.addItem(action("Скрыть иконку до следующего входа", #selector(quit)))
    }

    func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        return mi
    }

    // Снятие защиты — только через системное окно пароля (команда выполняется от root).
    func privileged(_ args: String, prompt: String) {
        let src = "do shell script \"\(asEsc("'\(cli)' \(args)"))\" with prompt \"\(asEsc(prompt))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let e = err, (e[NSAppleScript.errorNumber] as? Int) != -128 {
            alert("Не получилось", "\(e[NSAppleScript.errorMessage] ?? e)")
        }
        refresh()
    }

    @objc func pause15() { privileged("pause 15m", prompt: "VPN Guard: поставить защиту на паузу на 15 минут") }

    @objc func pauseFor(_ sender: NSMenuItem) {
        guard let arg = sender.representedObject as? String else { return }
        privileged("pause \(arg)", prompt: "VPN Guard: поставить защиту на паузу (\(sender.title))")
    }

    @objc func turnOff() { privileged("off", prompt: "VPN Guard: выключить защиту до ручного включения или перезагрузки") }

    @objc func turnOn() {
        DispatchQueue.global().async {
            let (code, out) = run(cli, ["on"])
            DispatchQueue.main.async {
                if code != 0 { self.alert("Не получилось включить", out) }
                self.refresh()
            }
        }
    }

    @objc func selfTest() {
        DispatchQueue.global().async {
            let (code, out) = run(cli, ["test"])
            DispatchQueue.main.async { self.alert(code == 0 ? "Проверка пройдена" : "Проверка: есть проблемы", out) }
        }
    }

    @objc func clientNow() {
        let t = clientTitle()
        DispatchQueue.global().async {
            let (code, out) = run(cli, ["sync"])
            DispatchQueue.main.async { self.alert(code == 0 ? "Адреса из \(t)" : "Не получилось взять адреса из \(t)", out) }
        }
    }

    @objc func openGuide() { NSWorkspace.shared.open(URL(fileURLWithPath: base + "/ПАМЯТКА.md")) }

    @objc func quit() { NSApp.terminate(nil) }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
