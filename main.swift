// ClaudeQuota — macOS menu bar app showing Claude usage limits.
// Menu bar: "7%·2h10" = session REMAINING % · time to 5h reset.
// Popover: session + weekly all models + weekly Fable, reset times, settings.
// Auth: reads Claude Code's Keychain credential, auto-refreshes, writes back.

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Constants

let kKeychainService = "Claude Code-credentials"
let kClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
let kTokenURL = "https://platform.claude.com/v1/oauth/token"
let kUsageURL = "https://api.anthropic.com/api/oauth/usage"
let kBetaHeader = "oauth-2025-04-20"
let kPollInterval: TimeInterval = 60
let kTickInterval: TimeInterval = 20
let kStateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ClaudeQuota")

// MARK: - Prefs

enum Prefs {
    static let d = UserDefaults.standard
    static var notifyReset: Bool {
        get { d.object(forKey: "notifyReset") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyReset") }
    }
    static var showUsed: Bool {
        get { d.bool(forKey: "showUsed") }
        set { d.set(newValue, forKey: "showUsed") }
    }
    static var stacked: Bool {
        get { d.object(forKey: "stacked") as? Bool ?? true }
        set { d.set(newValue, forKey: "stacked") }
    }
}

// MARK: - Shell helper

@discardableResult
func shell(_ launchPath: String, _ args: [String], stdin: String? = nil) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = Pipe()
    if let s = stdin {
        let inPipe = Pipe()
        p.standardInput = inPipe
        inPipe.fileHandleForWriting.write(s.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
    }
    do { try p.run() } catch { return ("", -1) }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}

// MARK: - Credentials

struct Creds {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double // ms epoch
    var scopes: [String]
    var rateLimitTier: String
    var raw: [String: Any] // full keychain JSON, preserved on write-back
}

final class CredsManager {
    static let shared = CredsManager()
    private let account = NSUserName()

    func read() -> Creds? {
        let r = shell("/usr/bin/security",
                      ["find-generic-password", "-s", kKeychainService, "-a", account, "-w"])
        guard r.code == 0 else { return nil }
        var text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil,
           let d = Data(hexString: text), let s = String(data: d, encoding: .utf8) {
            text = s
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let at = oauth["accessToken"] as? String, !at.isEmpty
        else { return nil }
        return Creds(
            accessToken: at,
            refreshToken: oauth["refreshToken"] as? String ?? "",
            expiresAt: (oauth["expiresAt"] as? Double) ?? 0,
            scopes: oauth["scopes"] as? [String] ?? [],
            rateLimitTier: oauth["rateLimitTier"] as? String ?? "",
            raw: json)
    }

    func writeBack(_ creds: Creds) {
        var json = creds.raw
        var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = creds.accessToken
        oauth["refreshToken"] = creds.refreshToken
        oauth["expiresAt"] = creds.expiresAt
        json["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let s = String(data: data, encoding: .utf8) else { return }
        shell("/usr/bin/security",
              ["add-generic-password", "-U", "-a", account, "-s", kKeychainService, "-w", s])
    }

    /// Refresh if expiring within 5 minutes (or force). Synchronous network call on caller's queue.
    func refreshedCreds(force: Bool = false) -> Creds? {
        guard var creds = read() else { return nil }
        let msLeft = creds.expiresAt - Date().timeIntervalSince1970 * 1000
        if !force && msLeft > 5 * 60 * 1000 { return creds }
        guard !creds.refreshToken.isEmpty else { return force ? nil : creds }

        var req = URLRequest(url: URL(string: kTokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": kClientID,
            "scope": creds.scopes.joined(separator: " ")
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)

        guard let r = result, let at = r["access_token"] as? String else {
            return force ? nil : creds
        }
        creds.accessToken = at
        if let rt = r["refresh_token"] as? String, !rt.isEmpty { creds.refreshToken = rt }
        let expiresIn = (r["expires_in"] as? Double) ?? 28800
        creds.expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        writeBack(creds)
        return creds
    }
}

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var idx = hexString.startIndex
        for _ in 0..<len {
            let next = hexString.index(idx, offsetBy: 2)
            guard let b = UInt8(hexString[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
}

// MARK: - Usage model

struct LimitRow: Identifiable {
    let id: String
    let label: String
    let percent: Double   // used, 0-100
    let resetsAt: Date?
    let isActive: Bool
}

enum AppStatus: Equatable {
    case ok
    case stale(String)
    case authError
    case starting
}

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func parseUsage(_ data: Data) -> [LimitRow] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    var rows: [LimitRow] = []
    if let limits = json["limits"] as? [[String: Any]] {
        for l in limits {
            let kind = l["kind"] as? String ?? "unknown"
            let group = l["group"] as? String ?? ""
            let pct = (l["percent"] as? Double) ?? (l["percent"] as? Int).map(Double.init) ?? 0
            let resets = parseISO(l["resets_at"] as? String)
            let active = l["is_active"] as? Bool ?? false
            var label: String
            switch kind {
            case "session": label = "Session (5h)"
            case "weekly_all": label = "Week · all models"
            case "weekly_scoped":
                var name = "scoped"
                if let scope = l["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let dn = model["display_name"] as? String { name = dn }
                label = "Week · \(name)"
            default: label = "\(group.isEmpty ? kind : group) · \(kind)"
            }
            rows.append(LimitRow(id: kind + label, label: label, percent: pct, resetsAt: resets, isActive: active))
        }
    }
    // Fallback for older/simpler schema
    if rows.isEmpty {
        if let fh = json["five_hour"] as? [String: Any] {
            rows.append(LimitRow(id: "session", label: "Session (5h)",
                                 percent: (fh["utilization"] as? Double) ?? 0,
                                 resetsAt: parseISO(fh["resets_at"] as? String), isActive: false))
        }
        if let sd = json["seven_day"] as? [String: Any] {
            rows.append(LimitRow(id: "weekly_all", label: "Week · all models",
                                 percent: (sd["utilization"] as? Double) ?? 0,
                                 resetsAt: parseISO(sd["resets_at"] as? String), isActive: false))
        }
    }
    return rows
}

// MARK: - Formatting

func countdownString(to date: Date?) -> String {
    guard let date = date else { return "–" }
    let secs = max(0, date.timeIntervalSinceNow)
    let mins = Int(secs / 60)
    let h = mins / 60, m = mins % 60
    if h > 0 { return "\(h)h" + String(format: "%02d", m) }
    return "\(m)m"
}

func absoluteResetString(_ date: Date?) -> String {
    guard let date = date else { return "–" }
    let f = DateFormatter()
    f.locale = Locale.current
    if date.timeIntervalSinceNow > 22 * 3600 {
        f.dateFormat = "EEE HH:mm"
    } else {
        f.dateFormat = "HH:mm"
    }
    return f.string(from: date)
}

// MARK: - Observable model

final class Model: ObservableObject {
    @Published var rows: [LimitRow] = []
    @Published var status: AppStatus = .starting
    @Published var lastUpdate: Date? = nil
    @Published var tier: String = ""
    @Published var notifyReset: Bool = Prefs.notifyReset { didSet { Prefs.notifyReset = notifyReset } }
    @Published var showUsed: Bool = Prefs.showUsed { didSet { Prefs.showUsed = showUsed; onChange?() } }
    @Published var stacked: Bool = Prefs.stacked { didSet { Prefs.stacked = stacked; onChange?() } }
    @Published var launchAtLogin: Bool = false

    var onChange: (() -> Void)?
    var lastHTTP: Int = 0
    var lastErrorBody: String = ""
    var session: LimitRow? { rows.first { $0.id.hasPrefix("session") } }
    var scoped: LimitRow? { rows.first { $0.id.hasPrefix("weekly_scoped") } }
}

// MARK: - Fetcher

final class Fetcher {
    private var lastSessionReset: Date?
    private let queue = DispatchQueue(label: "quota.fetch")
    private var failStreak = 0
    private var pausedUntil: Date?

    func fetch(model: Model, statusUpdate: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let p = self.pausedUntil, p > Date() { return } // 429 backoff window
            guard let creds = CredsManager.shared.refreshedCreds() else {
                DispatchQueue.main.async {
                    model.status = .authError
                    statusUpdate()
                }
                return
            }
            self.request(token: creds.accessToken) { data, code in
                if code == 401 {
                    // stale token → force refresh once
                    guard let fresh = CredsManager.shared.refreshedCreds(force: true) else {
                        DispatchQueue.main.async { model.status = .authError; statusUpdate() }
                        return
                    }
                    self.request(token: fresh.accessToken) { data2, code2 in
                        self.finish(model: model, data: data2, code: code2, tier: fresh.rateLimitTier, statusUpdate: statusUpdate)
                    }
                } else {
                    self.finish(model: model, data: data, code: code, tier: creds.rateLimitTier, statusUpdate: statusUpdate)
                }
            }
        }
    }

    private func request(token: String, done: @escaping (Data?, Int) -> Void) {
        var req = URLRequest(url: URL(string: kUsageURL)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kBetaHeader, forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            done(data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
    }

    private func finish(model: Model, data: Data?, code: Int, tier: String, statusUpdate: @escaping () -> Void) {
        let rows = data.flatMap { code == 200 ? parseUsage($0) : nil } ?? []
        let bodyPrefix = (code != 200) ? String(data: data?.prefix(200) ?? Data(), encoding: .utf8) ?? "" : ""
        if code == 200 && !rows.isEmpty {
            failStreak = 0; pausedUntil = nil
        } else if code == 429 || code >= 500 {
            failStreak += 1
            pausedUntil = Date().addingTimeInterval(min(300, 60 * pow(2, Double(failStreak - 1))))
        }
        DispatchQueue.main.async {
            model.lastHTTP = code
            model.lastErrorBody = bodyPrefix
            if !rows.isEmpty {
                // session-reset notification
                if let newReset = rows.first(where: { $0.id.hasPrefix("session") })?.resetsAt {
                    if let old = self.lastSessionReset, newReset.timeIntervalSince(old) > 60,
                       Prefs.notifyReset {
                        notify("Fresh 5h session window started")
                    }
                    self.lastSessionReset = newReset
                }
                model.rows = rows
                model.lastUpdate = Date()
                model.status = .ok
                if tier.contains("max_5x") { model.tier = "Max 5×" }
                else if tier.contains("max_20x") { model.tier = "Max 20×" }
                else if !tier.isEmpty { model.tier = tier }
                writeStateLog(model: model)
            } else if code == 401 || code == 403 {
                model.status = .authError
            } else if case .ok = model.status, model.lastUpdate != nil {
                model.status = .stale("HTTP \(code)")
            } else if model.lastUpdate == nil {
                model.status = .stale("HTTP \(code)")
            }
            if rows.isEmpty { writeStateLog(model: model) }
            statusUpdate()
        }
    }
}

func notify(_ text: String) {
    DispatchQueue.global().async {
        shell("/usr/bin/osascript", ["-e",
            "display notification \"\(text)\" with title \"ClaudeQuota\""])
    }
}

func writeStateLog(model: Model) {
    try? FileManager.default.createDirectory(at: kStateDir, withIntermediateDirectories: true)
    var dict: [String: Any] = [
        "ts": ISO8601DateFormatter().string(from: Date()),
        "status": "\(model.status)",
        "http": model.lastHTTP,
        "error_body": model.lastErrorBody
    ]
    dict["rows"] = model.rows.map { r -> [String: Any] in
        ["id": r.id, "label": r.label, "percent": r.percent, "active": r.isActive,
         "resets_at": r.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
    }
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
        try? data.write(to: kStateDir.appendingPathComponent("state.json"))
    }
}

func loadCachedRows() -> [LimitRow] {
    guard let data = try? Data(contentsOf: kStateDir.appendingPathComponent("state.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = json["rows"] as? [[String: Any]] else { return [] }
    return arr.compactMap { r in
        guard let id = r["id"] as? String, let label = r["label"] as? String else { return nil }
        return LimitRow(id: id, label: label,
                        percent: (r["percent"] as? Double) ?? 0,
                        resetsAt: parseISO(r["resets_at"] as? String),
                        isActive: r["active"] as? Bool ?? false)
    }
}

// MARK: - Popover view

struct LimitRowView: View {
    let row: LimitRow
    let showUsed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.label).font(.system(size: 12, weight: .medium))
                if row.isActive {
                    Text("active limit")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundColor(.orange)
                }
                Spacer()
                Text(showUsed
                     ? "\(Int(row.percent.rounded()))% used"
                     : "\(Int((100 - row.percent).rounded()))% left")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(color)
            }
            ProgressView(value: min(max(row.percent, 0), 100), total: 100)
                .tint(color)
            HStack {
                Spacer()
                Text("resets \(absoluteResetString(row.resetsAt)) (\(countdownString(to: row.resetsAt)))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }
    var color: Color {
        if row.percent >= 90 { return .red }
        if row.percent >= 75 { return .orange }
        return .accentColor
    }
}

struct PopoverView: View {
    @ObservedObject var model: Model
    var onRefresh: () -> Void
    var onToggleLogin: (Bool) -> Void
    var onQuit: () -> Void
    @State private var now = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude usage").font(.system(size: 13, weight: .bold))
                if !model.tier.isEmpty {
                    Text(model.tier).font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                statusBadge
            }

            if model.status == .authError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Can't read Claude credentials.").font(.system(size: 12))
                    Text("Run `claude auth login` in Terminal, then Refresh.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
            }

            ForEach(model.rows) { row in
                LimitRowView(row: row, showUsed: model.showUsed)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Notify when 5h session resets", isOn: $model.notifyReset)
                    .font(.system(size: 11))
                Toggle("Show % used (instead of % left)", isOn: $model.showUsed)
                    .font(.system(size: 11))
                Toggle("Compact menu bar (2 lines)", isOn: $model.stacked)
                    .font(.system(size: 11))
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { onToggleLogin($0) }))
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            Divider()

            HStack {
                Text(updatedText)
                    .font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                Spacer()
                Button("Refresh") { onRefresh() }.font(.system(size: 11))
                Button("claude.ai") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }.font(.system(size: 11))
                Button("Quit") { onQuit() }.font(.system(size: 11))
            }
        }
        .padding(14)
        .frame(width: 340)
        .onReceive(timer) { now = $0 }
    }

    var updatedText: String {
        guard let t = model.lastUpdate else { return "never updated" }
        let s = Int(now.timeIntervalSince(t))
        return s < 120 ? "updated \(max(0, s))s ago" : "updated \(s / 60)m ago"
    }

    @ViewBuilder var statusBadge: some View {
        switch model.status {
        case .ok: EmptyView()
        case .starting: Text("loading…").font(.system(size: 10)).foregroundColor(.secondary)
        case .authError: Text("auth ⚠").font(.system(size: 10)).foregroundColor(.red)
        case .stale(let why): Text("stale · \(why)").font(.system(size: 10)).foregroundColor(.orange)
        }
    }
}

// MARK: - Panel background

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel?
    var panelMonitors: [Any] = []
    let model = Model()
    let fetcher = Fetcher()
    var pollTimer: Timer?
    var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        renderTitle()

        // Seed UI from last snapshot so the menu bar never starts empty
        let cached = loadCachedRows()
        if !cached.isEmpty {
            model.rows = cached
            model.status = .stale("cached")
        }

        model.onChange = { [weak self] in self?.renderTitle() }
        if #available(macOS 13.0, *) {
            model.launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: kPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: kTickInterval, repeats: true) { [weak self] _ in
            self?.renderTitle()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        poll()
    }

    @objc func didWake() { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.poll() } }

    func poll() {
        fetcher.fetch(model: model) { [weak self] in self?.renderTitle() }
    }

    @objc func togglePopover() {
        if let p = panel, p.isVisible { closePanel() } else { showPanel() }
    }

    func showPanel() {
        closePanel()
        let root = PopoverView(
            model: model,
            onRefresh: { [weak self] in self?.poll() },
            onToggleLogin: { [weak self] on in self?.setLaunchAtLogin(on) },
            onQuit: { NSApp.terminate(nil) })
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        let hosting = NSHostingView(rootView: AnyView(root))
        let size = hosting.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.isReleasedWhenClosed = false
        p.contentView = hosting

        if let btnWindow = statusItem.button?.window,
           let screen = btnWindow.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            var x = btnWindow.frame.midX - size.width / 2
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
            let y = vf.maxY - size.height - 6
            p.setFrameOrigin(NSPoint(x: x, y: y))
            let log = "{\"panel_top\":\(Int(y + size.height)),\"menu_bar_bottom\":\(Int(vf.maxY)),\"x\":\(Int(x)),\"w\":\(Int(size.width)),\"h\":\(Int(size.height))}"
            try? log.data(using: .utf8)?.write(to: kStateDir.appendingPathComponent("panel.json"))
        }
        p.orderFrontRegardless()
        panel = p

        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.closePanel()
        }) { panelMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] ev in
            guard let self = self else { return ev }
            if ev.type == .keyDown {
                if ev.keyCode == 53 { self.closePanel(); return nil }
                return ev
            }
            // Ignore clicks on the status item itself — togglePopover handles those
            // (otherwise the panel closes on mouseDown and reopens on mouseUp).
            if ev.window !== self.panel && ev.window !== self.statusItem.button?.window {
                self.closePanel()
            }
            return ev
        }) { panelMonitors.append(l) }
    }

    func closePanel() {
        for m in panelMonitors { NSEvent.removeMonitor(m) }
        panelMonitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {}
            model.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func renderTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        guard model.status != .authError else {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "CQ ⚠", attributes: [
                .font: font, .foregroundColor: NSColor.systemRed])
            return
        }
        guard let session = model.session else {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "…", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor])
            return
        }

        let used = session.percent
        let value = Prefs.showUsed ? used : (100 - used)
        let pctText = "\(Int(value.rounded()))%"
        let cdText = countdownString(to: session.resetsAt)
        let fCritical = (model.scoped?.percent ?? 0) >= 90

        var color = NSColor.labelColor
        var isStale = false
        if used >= 90 { color = .systemRed }
        else if used >= 75 { color = .systemOrange }
        if case .stale = model.status { isStale = true; color = .secondaryLabelColor }

        if Prefs.stacked {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = stackedImage(top: pctText, bottom: cdText, color: color,
                                        template: color == .labelColor && !fCritical && !isStale,
                                        fCritical: fCritical)
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            let plain = color == NSColor.labelColor
            let attrs: [NSAttributedString.Key: Any] = plain
                ? [.font: font, .foregroundColor: color]
                : AppDelegate.outlinedAttrs(font: font, color: color)
            let title = NSMutableAttributedString(string: "\(pctText)·\(cdText)", attributes: attrs)
            if fCritical {
                title.append(NSAttributedString(string: "·F",
                    attributes: AppDelegate.outlinedAttrs(font: font, color: .systemRed)))
            }
            button.attributedTitle = title
        }
    }

    /// Attributes for colored (non-template) menu bar text: white outline + soft white
    /// glow so orange/red stay readable over any wallpaper (e.g. blue menu bars).
    static func outlinedAttrs(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2.0
        shadow.shadowOffset = .zero
        return [.font: font,
                .foregroundColor: color,
                .strokeColor: NSColor.white,
                .strokeWidth: -4.5,
                .shadow: shadow]
    }

    func stackedImage(top: String, bottom: String, color: NSColor, template: Bool, fCritical: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let baseAttrs: [NSAttributedString.Key: Any] = template
            ? [.font: font, .foregroundColor: NSColor.black]
            : AppDelegate.outlinedAttrs(font: font, color: color)
        let topAttr = NSMutableAttributedString(string: top, attributes: baseAttrs)
        if fCritical {
            topAttr.append(NSAttributedString(string: "•",
                attributes: AppDelegate.outlinedAttrs(font: font, color: .systemRed)))
        }
        let botAttr = NSAttributedString(string: bottom, attributes: baseAttrs)
        let w = ceil(max(topAttr.size().width, botAttr.size().width)) + 4
        let h: CGFloat = 22
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let ts = topAttr.size(), bs = botAttr.size()
            topAttr.draw(at: NSPoint(x: (w - ts.width) / 2, y: h / 2 - 0.5))
            botAttr.draw(at: NSPoint(x: (w - bs.width) / 2, y: h / 2 - bs.height + 0.5))
            return true
        }
        img.isTemplate = template
        return img
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
