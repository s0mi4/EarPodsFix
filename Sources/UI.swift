// UI — выпадающая панель в строке меню (SwiftUI MenuBarExtra).

import SwiftUI
import AppKit

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

@main
struct EarPodsFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(engine)
        } label: {
            Image(systemName: engine.state.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Для разработки: `EarPodsFix --snapshot файл.png [dark] [en]` — отрисовать панель в картинку и выйти.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let savedLang = Engine.shared.lang
            Engine.shared.lang = args.contains("en") ? .en : .ru
            Engine.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let dark = args.contains("dark")
                // Настоящее окно AppKit, чтобы системные переключатели отрисовались как в меню.
                let host = NSHostingView(rootView: Panel().environmentObject(Engine.shared))
                let win = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 340, height: 600),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.backgroundColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.95, alpha: 1)
                win.contentView = host
                win.setContentSize(host.fittingSize)
                win.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let v = win.contentView!
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                    }
                    print("fitting width:", host.fittingSize.width)
                    Engine.shared.lang = savedLang      // не меняем язык, выбранный пользователем
                    exit(0)
                }
            }
            return
        }
        Engine.shared.start()
    }
    func applicationWillTerminate(_ n: Notification) {
        Engine.shared.resume(nil)   // никогда не оставляем программы на паузе
    }
}

// MARK: - Оформление состояний

extension GuardState {
    var menuIcon: String {
        switch self {
        case .ok, .waiting: "earpods"
        case .paused: "pause.circle.fill"
        case .hung: "exclamationmark.triangle.fill"
        case .off: "speaker.slash"
        }
    }
    var color: Color {
        switch self {
        case .ok: .green
        case .waiting: .gray
        case .paused: .blue
        case .hung: .orange
        case .off: .secondary
        }
    }
    var badgeIcon: String {
        switch self {
        case .ok: "earpods"
        case .waiting: "cable.connector.slash"
        case .paused: "pause.fill"
        case .hung: "exclamationmark.triangle.fill"
        case .off: "power"
        }
    }
}

extension LogEvent.Kind {
    var color: Color {
        switch self {
        case .info: .secondary
        case .fix: .green
        case .pause: .blue
        case .found: .purple
        case .warn: .orange
        }
    }
}

// MARK: - Панель

struct Panel: View {
    @EnvironmentObject var e: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header()
            if e.state == .paused { PauseBanner() }
            if e.state == .hung { HungBanner() }

            Card(title: L("Защита", "Protection")) {
                SettingRow(icon: "mic.fill", tint: .pink,
                           title: L("Держать микрофон", "Keep microphone"),
                           subtitle: L("наушники как микрофон", "use the headset mic"), isOn: $e.holdInput)
                Divider().padding(.leading, 38)
                SettingRow(icon: "pause.circle.fill", tint: .blue,
                           title: L("Пауза мешающих программ", "Pause interfering apps"),
                           subtitle: L("на время переподключения", "while headphones reconnect"), isOn: $e.guardEnabled)
                Divider().padding(.leading, 38)
                SettingRow(icon: "shield.lefthalf.filled", tint: .indigo,
                           title: L("Строгий режим", "Strict mode"),
                           subtitle: L("плюс все Chromium/Electron", "also all Chromium/Electron apps"), isOn: $e.strictMode)
            }

            BlockersCard()
            LogCard()
            Card(title: L("Настройки", "Settings")) {
                DeviceRow()
                Divider().padding(.leading, 28)
                LanguageRow()
            }
            Footer()
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { e.refresh(); e.refreshCandidates() }
    }
}

struct Header: View {
    @EnvironmentObject var e: Engine

    /// Вверху — имя реальных наушников (или устройства, на которое сейчас идёт звук).
    var title: String {
        switch e.state {
        case .ok: e.connectedName ?? e.activeOutputName
        case .waiting: e.activeOutputName.isEmpty ? L("Нет звука", "No output") : e.activeOutputName
        case .paused: L("Ждём наушники", "Waiting for headphones")
        case .hung: e.connectedName ?? L("Наушники зависли", "Headphones froze")
        case .off: e.activeOutputName
        }
    }
    var subtitle: String {
        switch e.state {
        case .ok: e.fixCount == 0 ? L("Подключены · звук на наушниках", "Connected · audio on headphones")
                                  : L("Подключены · исправлений: \(e.fixCount)", "Connected · fixes: \(e.fixCount)")
        case .waiting: L("Наушники не подключены (\(e.targetLabel))", "Headphones not connected (\(e.targetLabel))")
        case .paused: L("Программы на паузе, вставьте наушники", "Apps paused, plug the headphones in")
        case .hung: L("Зависли — выньте и вставьте снова", "Frozen — unplug and plug back in")
        case .off: L("EarPodsFix выключен", "EarPodsFix is off")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(e.state.color.gradient)
                Image(systemName: e.state.badgeIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: e.state.color.opacity(0.35), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $e.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

struct PauseBanner: View {
    @EnvironmentObject var e: Engine
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").font(.title3).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("На паузе: ", "Paused: ") + e.pausedNames.joined(separator: ", "))
                        .font(.callout.weight(.medium)).lineLimit(2)
                    let s = max(0, Int(e.pauseEnds?.timeIntervalSinceNow ?? 0))
                    Text(L("Снимется сама через \(s) с", "Resumes automatically in \(s) s"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Снять", "Resume")) { e.resume(L("вручную", "manually")) }.controlSize(.small)
            }
            .padding(10)
            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct HungBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
            Text(L("macOS не смогла запустить наушники. Выньте их и вставьте снова — мешающие программы будут на паузе.",
                   "macOS couldn't start the headphones. Unplug and plug them back in — interfering apps will be paused."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Мешающие программы

struct BlockersCard: View {
    @EnvironmentObject var e: Engine

    var body: some View {
        Card(title: L("Мешающие программы", "Interfering apps")) {
            if e.blockers.isEmpty && e.candidates.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                    Text(L("Пока не найдено. Программы, которые подключаются к наушникам, появятся здесь сами.",
                           "None found yet. Apps that connect to your headphones will show up here automatically."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            ForEach(Array(e.blockers.enumerated()), id: \.element.id) { i, b in
                if i > 0 { Divider().padding(.leading, 38) }
                AppRow(path: b.path, name: b.name,
                       subtitle: b.detections > 1
                           ? L("найдена автоматически · \(b.detections) раз", "auto-detected · \(b.detections) times")
                           : L("найдена автоматически", "auto-detected"),
                       badge: L("авто", "auto"), badgeColor: .purple,
                       onForget: { e.forget(b) })
            }
            ForEach(Array(e.candidates.enumerated()), id: \.element.path) { i, c in
                if i > 0 || !e.blockers.isEmpty { Divider().padding(.leading, 38) }
                AppRow(path: c.path, name: c.name, subtitle: L("строгий режим", "strict mode"),
                       badge: "Chromium", badgeColor: .indigo, onForget: nil)
            }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var e: Engine
    let path: String
    let name: String
    let subtitle: String
    let badge: String
    let badgeColor: Color
    let onForget: (() -> Void)?
    @StateObject private var hover = Flag()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: outerAppPath(path) ?? path))
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name).font(.callout).lineLimit(1)
                    Text(badge).font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(badgeColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(badgeColor)
                }
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let onForget, hover.on {
                Button(action: onForget) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help(L("Забыть эту программу", "Forget this app"))
            }
            Toggle("", isOn: Binding(
                get: { !e.excluded.contains(path) },
                set: { on in if on { e.excluded.remove(path) } else { e.excluded.insert(path) } }
            ))
            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            .help(L("Ставить на паузу при переподключении наушников", "Pause while headphones reconnect"))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}

// MARK: - Журнал

struct LogCard: View {
    @EnvironmentObject var e: Engine
    @StateObject private var expanded = Flag()
    private let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        Card(title: L("Журнал", "Log"), trailing: {
            if e.events.count > 4 {
                Button(expanded.on ? L("Свернуть", "Less") : L("Ещё \(e.events.count - 4)", "\(e.events.count - 4) more")) {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.on.toggle() }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }) {
            ForEach(e.events.prefix(expanded.on ? 40 : 4)) { ev in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(ev.kind.color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(f.string(from: ev.date)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    Text(ev.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 1)
            }
        }
    }
}

// MARK: - Настройки и низ панели

struct DeviceRow: View {
    @EnvironmentObject var e: Engine
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones").foregroundStyle(.secondary).frame(width: 18)
            Text(L("Наушники", "Headphones")).font(.callout).lineLimit(1).fixedSize()
            Spacer()
            Picker("", selection: $e.keyword) {
                Text(L("Авто (USB)", "Auto (USB)")).tag("")
                Divider()
                ForEach(Array(Set(e.outputNames + (e.keyword.isEmpty ? [] : [e.keyword]))).sorted(), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(maxWidth: 170)
        }
    }
}

struct LanguageRow: View {
    @EnvironmentObject var e: Engine
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 18)
            Text(L("Язык", "Language")).font(.callout).lineLimit(1).fixedSize()
            Spacer()
            Picker("", selection: $e.lang) {
                ForEach(Lang.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)
            .frame(width: 160)
        }
    }
}

struct Footer: View {
    @EnvironmentObject var e: Engine
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle(L("Запускать при входе", "Launch at login"),
                       isOn: Binding(get: { e.launchAtLogin }, set: { e.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label(L("Выйти", "Quit"), systemImage: "power").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut("q")
            }
            HStack(spacing: 4) {
                Text("EarPodsFix \(appVersion)").foregroundStyle(.tertiary)
                Text("·").foregroundStyle(.tertiary)
                AuthorLink()
            }
            .font(.caption2)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
    }
}

/// «by s0mi4» — ссылка на GitHub автора.
struct AuthorLink: View {
    @StateObject private var hover = Flag()
    var body: some View {
        Link(destination: URL(string: "https://github.com/s0mi4")!) {
            HStack(spacing: 3) {
                Text("by s0mi4").fontWeight(.semibold)
                Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold))
                    .opacity(hover.on ? 1 : 0)
            }
            .foregroundStyle(hover.on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .onHover { h in
            hover.on = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("github.com/s0mi4")
    }
}

// MARK: - Компоненты

/// Локальный флажок для View (замена @State, которому нужен плагин макросов Xcode).
final class Flag: ObservableObject { @Published var on = false }

struct Card<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 4) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

extension Card where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

struct SettingRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        .padding(.vertical, 2)
    }
}
