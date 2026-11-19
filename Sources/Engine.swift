// Engine — вся логика EarPodsFix.
//
// 1. Держит звук (вывод, системные звуки, микрофон) на выбранных наушниках и их частоту дискретизации.
// 2. Защищает USB-наушники в момент подключения. Некоторые программы подключаются к USB-устройству
//    наушников, и наушники зависают. Список таких программ НЕ задан заранее: приложение само смотрит
//    в реестре IOKit, какие процессы открыли «клиентов» на USB-устройстве наушников, и запоминает их.
//    Когда наушники вынимают, эти программы ставятся на паузу (SIGSTOP — не закрытие!),
//    а когда наушники снова заработали — продолжают работу (SIGCONT).
// 3. Строгий режим: дополнительно ставит на паузу все запущенные программы на Chromium/Electron.

import AppKit
import CoreAudio
import IOKit
import ServiceManagement

// MARK: - Язык

enum Lang: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var title: String { self == .ru ? "Русский" : "English" }
}

enum Loc {
    static var lang: Lang = {
        if let s = UserDefaults.standard.string(forKey: "lang"), let l = Lang(rawValue: s) { return l }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? .ru : .en
    }()
}

/// Строка на текущем языке интерфейса.
func L(_ ru: String, _ en: String) -> String { Loc.lang == .en ? en : ru }

// MARK: - Модели

struct Blocker: Codable, Identifiable, Hashable {
    var path: String          // исполняемый файл процесса, который лез к наушникам
    var name: String
    var detections: Int
    var lastSeen: Date
    var id: String { path }
}

struct LogEvent: Identifiable {
    enum Kind { case info, fix, pause, found, warn }
    let id = UUID()
    let date = Date()
    let text: String
    let kind: Kind
}

enum GuardState { case off, waiting, ok, paused, hung }

// MARK: - Движок

final class Engine: ObservableObject {
    static let shared = Engine()

    let maxPause: TimeInterval = 30
    private let ud = UserDefaults.standard

    // настройки

    @Published var lang: Lang = Loc.lang { didSet { Loc.lang = lang; ud.set(lang.rawValue, forKey: "lang") } }
    @Published var enabled: Bool { didSet { ud.set(enabled, forKey: "enabled"); if !enabled { resume(nil) }; refresh() } }
    @Published var holdInput: Bool { didSet { ud.set(holdInput, forKey: "manageInput"); refresh() } }
    @Published var guardEnabled: Bool { didSet { ud.set(guardEnabled, forKey: "plugGuard"); if !guardEnabled { resume(nil) } } }
    @Published var strictMode: Bool { didSet { ud.set(strictMode, forKey: "strictMode"); refreshCandidates() } }
    /// Какие наушники держать. Пустая строка — автоматически, любые USB-наушники.
    @Published var keyword: String {
        didSet {
            guard keyword != oldValue else { return }
            ud.set(keyword, forKey: "keyword")
            ud.removeObject(forKey: "usbVID"); ud.removeObject(forKey: "usbPID")
            protectedIDs.removeAll()
            wantedRates.removeAll()
            log(L("Слежу за: \(targetLabel)", "Watching: \(targetLabel)"), .info)
            rescanUSB()
            refresh()
        }
    }
    @Published var excluded: Set<String> { didSet { ud.set(Array(excluded), forKey: "excluded") } }
    @Published var blockers: [Blocker] { didSet { saveBlockers() } }

    // состояние для интерфейса

    @Published private(set) var state: GuardState = .waiting
    @Published private(set) var events: [LogEvent] = []
    @Published private(set) var fixCount = 0
    @Published private(set) var pausedNames: [String] = []
    @Published private(set) var pauseEnds: Date?
    @Published private(set) var usbPresent = false
    @Published private(set) var outputNames: [String] = []
    /// Имя подключённых наушников (как его показывает macOS), если они сейчас доступны.
    @Published private(set) var connectedName: String?
    /// Устройство, на которое сейчас реально идёт звук.
    @Published private(set) var activeOutputName = ""
    @Published private(set) var candidates: [(path: String, name: String)] = []
    @Published var launchAtLogin = false

    var targetLabel: String { keyword.isEmpty ? L("любые USB-наушники", "any USB headphones") : keyword }

    private var frozen: [pid_t] = []
    private var hung = false
    private var protectedIDs = Set<UInt64>()     // IORegistry ID подключённых защищаемых USB-устройств
    private var wantedRates: [AudioDeviceID: Float64] = [:]
    private var watchedRate = Set<AudioDeviceID>()
    private var pending: DispatchWorkItem?
    private var safety: DispatchWorkItem?
    private var waitTimer: Timer?
    private var timers: [Timer] = []
    private var port: IONotificationPortRef?
    private var addIter: io_iterator_t = 0
    private var removeIter: io_iterator_t = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var chromiumCache: [String: Bool] = [:]
    private var started = false

    private init() {
        enabled = ud.object(forKey: "enabled") as? Bool ?? true
        holdInput = ud.object(forKey: "manageInput") as? Bool ?? true
        guardEnabled = ud.object(forKey: "plugGuard") as? Bool ?? true
        strictMode = ud.object(forKey: "strictMode") as? Bool ?? false
        keyword = ud.string(forKey: "keyword") ?? ""
        excluded = Set(ud.stringArray(forKey: "excluded") ?? [])
        if let d = ud.data(forKey: "blockers"), let b = try? JSONDecoder().decode([Blocker].self, from: d) {
            blockers = b
        } else {
            blockers = []
        }
    }

    func start() {
        guard !started else { return }
        started = true
        resumeLeftovers()
        installSignalHandlers()
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice,
                    kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var a = addr(sel)
            AudioObjectAddPropertyListenerBlock(systemObject, &a, .main) { [weak self] _, _ in
                if sel == kAudioHardwarePropertyDevices { self?.pruneDead() }
                self?.schedule()
            }
        }
        startUSBWatch()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(afterHang: false) })
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        log(L("EarPodsFix запущен", "EarPodsFix started"), .info)
        refresh()
        scan(afterHang: false)
    }

    // MARK: удержание звука

    private func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func pruneDead() {
        let alive = Set(allDevices())
        watchedRate.formIntersection(alive)
        wantedRates = wantedRates.filter { alive.contains($0.key) }
    }

    private func watchRate(_ dev: AudioDeviceID) {
        guard !watchedRate.contains(dev) else { return }
        watchedRate.insert(dev)
        wantedRates[dev] = sampleRate(dev)
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(dev, &a, .main) { [weak self] _, _ in self?.schedule() }
    }

    func refresh() {
        let outs = allDevices().filter { channels($0, kAudioObjectPropertyScopeOutput) > 0 }
        let names = outs.map(deviceName)
        if names != outputNames { outputNames = names }

        if enabled {
            var targets: [(AudioObjectPropertySelector, AudioObjectPropertyScope, String)] = [
                (kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeOutput, L("Звук", "Output")),
                (kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeOutput, L("Системные звуки", "System sounds")),
            ]
            if holdInput { targets.append((kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeInput, L("Микрофон", "Microphone"))) }
            for (sel, scope, label) in targets {
                guard let want = findAudioDevice(keyword, scope) else { continue }
                watchRate(want)
                let cur = getDefault(sel)
                if cur != want, setDefault(sel, want) {
                    fixCount += 1
                    log("\(label): «\(deviceName(cur))» → «\(deviceName(want))»", .fix)
                }
            }
            for (dev, rate) in wantedRates where rate > 0 {
                let cur = sampleRate(dev)
                if cur > 0, cur != rate {
                    setSampleRate(dev, rate)
                    fixCount += 1
                    log(L("Частота: \(Int(cur)) → \(Int(rate)) Гц", "Sample rate: \(Int(cur)) → \(Int(rate)) Hz"), .fix)
                }
            }
        }

        let target = findAudioDevice(keyword, kAudioObjectPropertyScopeOutput)
        let cn = target.map(deviceName)
        if cn != connectedName { connectedName = cn }
        let active = deviceName(getDefault(kAudioHardwarePropertyDefaultOutputDevice))
        if active != activeOutputName { activeOutputName = active }
        if target != nil { hung = false }
        let s: GuardState = !enabled ? .off : !frozen.isEmpty ? .paused : hung ? .hung : target != nil ? .ok : .waiting
        if s != state { state = s }
    }

    var isConnected: Bool { findAudioDevice(keyword, kAudioObjectPropertyScopeOutput) != nil }

    // MARK: USB-события

    private func entryID(_ s: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(s, &id)
        return id
    }

    /// Подходит ли USB-устройство под выбранные наушники.
    private func isProtected(_ s: io_registry_entry_t) -> Bool {
        if protectedIDs.contains(entryID(s)) { return true }
        if keyword.isEmpty { return usbHasAudioInterface(s) }
        let vid = regInt(s, "idVendor"), pid = regInt(s, "idProduct")
        if let n = regString(s, "USB Product Name"), !n.isEmpty,
           n.localizedCaseInsensitiveContains(keyword) || keyword.localizedCaseInsensitiveContains(n) {
            if let vid, let pid { ud.set(vid, forKey: "usbVID"); ud.set(pid, forKey: "usbPID") }
            return true
        }
        if let vid, let pid, ud.object(forKey: "usbVID") != nil,
           vid == ud.integer(forKey: "usbVID"), pid == ud.integer(forKey: "usbPID") { return true }
        return false
    }

    private func startUSBWatch() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { ref, it in
            Unmanaged<Engine>.fromOpaque(ref!).takeUnretainedValue().drain(it, added: true, initial: false)
        }, me, &addIter)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { ref, it in
            Unmanaged<Engine>.fromOpaque(ref!).takeUnretainedValue().drain(it, added: false, initial: false)
        }, me, &removeIter)
        drain(addIter, added: true, initial: true)
        drain(removeIter, added: false, initial: true)
    }

    /// Пересобрать список подключённых защищаемых устройств (после смены наушников в настройках).
    private func rescanUSB() {
        let devs = usbDevices(where: isProtected)
        protectedIDs = Set(devs.map(entryID))
        devs.forEach { IOObjectRelease($0) }
        usbPresent = !protectedIDs.isEmpty
    }

    private func drain(_ it: io_iterator_t, added: Bool, initial: Bool) {
        var matched = false
        while case let s = IOIteratorNext(it), s != 0 {
            if added {
                // при подключении интерфейсы могут появиться чуть позже — для авто-режима проверим ещё раз
                if isProtected(s) { protectedIDs.insert(entryID(s)); matched = true }
                else if keyword.isEmpty && !initial { recheckLater(entryID(s)) }
            } else if protectedIDs.remove(entryID(s)) != nil || (!keyword.isEmpty && isProtected(s)) {
                matched = true
            }
            IOObjectRelease(s)
        }
        guard matched else { return }
        if added {
            usbPresent = true
            if !initial { plugged() }
        } else if !initial {
            unplugged()
        }
    }

    private func recheckLater(_ id: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let devs = usbDevices { self.entryID($0) == id && usbHasAudioInterface($0) }
            defer { devs.forEach { IOObjectRelease($0) } }
            guard !devs.isEmpty else { return }
            self.protectedIDs.insert(id)
            self.usbPresent = true
            self.plugged()
        }
    }

    private func unplugged() {
        usbPresent = !protectedIDs.isEmpty
        hung = false
        waitTimer?.invalidate()
        log(L("Наушники отключены", "Headphones unplugged"), .info)
        if enabled && guardEnabled { freeze() }
        refresh()
    }

    private func plugged() {
        log(L("Наушники подключены", "Headphones plugged in"), .info)
        waitTimer?.invalidate()
        let t0 = Date()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.isConnected {
                t.invalidate()
                self.hung = false
                let sec = String(format: "%.1f", Date().timeIntervalSince(t0))
                self.log(L("Наушники заработали за \(sec) с", "Headphones ready in \(sec) s"), .fix)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.resume(L("наушники готовы", "headphones ready")) }
                for d in [5.0, 12.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.scan(afterHang: false) } }
                self.refresh()
            } else if Date().timeIntervalSince(t0) > 9 {
                t.invalidate()
                self.hung = true
                self.resume(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.scan(afterHang: true) }
                self.refresh()
            }
        }
    }

    // MARK: поиск мешающих программ

    func scan(afterHang: Bool) {
        let devs = usbDevices(where: isProtected)
        var found: [(path: String, name: String)] = []
        for d in devs {
            for pid in userClientPids(of: d) where pid != getpid() {
                guard let p = processPath(pid), !isSystemPath(p), !p.hasPrefix(Bundle.main.bundlePath) else { continue }
                if !found.contains(where: { $0.path == p }) { found.append((p, displayName(forExec: p))) }
            }
            IOObjectRelease(d)
        }
        var newNames: [String] = []
        for f in found {
            if let i = blockers.firstIndex(where: { $0.path == f.path }) {
                blockers[i].lastSeen = Date()
                if afterHang { blockers[i].detections += 1 }
            } else {
                blockers.append(Blocker(path: f.path, name: f.name, detections: 1, lastSeen: Date()))
                newNames.append(f.name)
            }
        }
        if !newNames.isEmpty {
            let n = newNames.joined(separator: ", ")
            let many = newNames.count > 1
            log(many ? L("Найдены мешающие программы: \(n). Теперь они будут на паузе при переподключении",
                         "Found interfering apps: \(n). They will be paused on reconnect")
                     : L("Найдена мешающая программа: \(n). Теперь она будет на паузе при переподключении",
                         "Found an interfering app: \(n). It will be paused on reconnect"), .found)
        }
        if afterHang {
            let who = found.map(\.name).joined(separator: ", ")
            log(who.isEmpty
                ? L("Наушники зависли, виновник не найден. Выньте и вставьте снова; если повторится — включите строгий режим",
                    "Headphones froze, no culprit found. Replug them; if it happens again, turn on Strict mode")
                : L("Наушники зависли из-за: \(who). Выньте и вставьте снова",
                    "Headphones froze because of: \(who). Unplug and plug them back in"), .warn)
        }
    }

    func forget(_ b: Blocker) {
        blockers.removeAll { $0.path == b.path }
        excluded.remove(b.path)
    }

    func refreshCandidates() {
        guard strictMode else { if !candidates.isEmpty { candidates = [] }; return }
        var out: [(String, String)] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleURL?.path, let exec = app.executableURL?.path,
                  app.processIdentifier != getpid(), !isSystemPath(bundle) else { continue }
            let isCr = chromiumCache[bundle] ?? isChromiumBased(appPath: bundle)
            chromiumCache[bundle] = isCr
            if isCr, !blockers.contains(where: { $0.path == exec }) {
                out.append((exec, app.localizedName ?? displayName(forExec: exec)))
            }
        }
        candidates = out.sorted { $0.1 < $1.1 }
    }

    // MARK: пауза программ

    private func freezePaths() -> Set<String> {
        var paths = Set(blockers.map(\.path))
        if strictMode { refreshCandidates(); paths.formUnion(candidates.map(\.path)) }
        return paths.subtracting(excluded)
    }

    private func freeze() {
        resume(nil)
        let paths = freezePaths()
        guard !paths.isEmpty else { return }
        var pids: [pid_t] = []
        var names = Set<String>()
        for pid in allPids() where pid > 1 && pid != getpid() {
            guard let p = processPath(pid), paths.contains(p), !isSystemPath(p) else { continue }
            pids.append(pid)
            names.insert(displayName(forExec: p))
        }
        guard !pids.isEmpty else { return }
        for p in pids { kill(p, SIGSTOP) }
        frozen = pids
        ud.set(pids.map(Int.init), forKey: "frozenPids")
        pausedNames = names.sorted()
        pauseEnds = Date().addingTimeInterval(maxPause)
        let w = DispatchWorkItem { [weak self] in
            self?.resume(L("прошло \(Int(self?.maxPause ?? 30)) с", "\(Int(self?.maxPause ?? 30)) s passed"))
        }
        safety = w
        DispatchQueue.main.asyncAfter(deadline: .now() + maxPause, execute: w)
        let n = pausedNames.joined(separator: ", ")
        log(L("На паузе: \(n). Вставьте наушники", "Paused: \(n). Plug the headphones back in"), .pause)
        refresh()
    }

    func resume(_ reason: String?) {
        safety?.cancel(); safety = nil
        guard !frozen.isEmpty else { return }
        for p in frozen { kill(p, SIGCONT) }
        frozen = []
        pausedNames = []
        pauseEnds = nil
        ud.removeObject(forKey: "frozenPids")
        if let reason { log(L("Пауза снята: \(reason)", "Resumed: \(reason)"), .info) }
        refresh()
    }

    private func resumeLeftovers() {
        if let left = ud.array(forKey: "frozenPids") as? [Int] {
            for p in left { kill(pid_t(p), SIGCONT) }
            ud.removeObject(forKey: "frozenPids")
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.resume(nil); exit(0) }
            s.resume()
            signalSources.append(s)
        }
    }

    // MARK: прочее

    func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log(L("Автозапуск: \(error.localizedDescription). Перенесите приложение в «Программы»",
                  "Launch at login: \(error.localizedDescription). Move the app to Applications"), .warn)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func log(_ text: String, _ kind: LogEvent.Kind) {
        events.insert(LogEvent(text: text, kind: kind), at: 0)
        if events.count > 40 { events.removeLast(events.count - 40) }
        NSLog("EarPodsFix: %@", text)
    }

    private func saveBlockers() {
        if let d = try? JSONEncoder().encode(blockers) { ud.set(d, forKey: "blockers") }
    }
}
