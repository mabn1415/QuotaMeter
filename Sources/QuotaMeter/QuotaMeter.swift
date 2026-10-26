import SwiftUI
import AppKit
import ServiceManagement
import Charts
import Combine
import Network
import Darwin

struct Limit: Codable { let remainingPercent: Double; let resetAt: Date? }
struct Usage: Codable { let fetchedAt: Date; let source: String; let fiveHour: Limit?; let weekly: Limit? }
struct HistoryPoint: Identifiable { let id = UUID(); let date: Date; let value: Double; let series: String }

enum Storage {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AllowanceMonitor", isDirectory: true)
    // Keep the v3.0 path so Chrome cookies and history stay in place.
    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: raw) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO8601 date")
        }
        return decoder
    }
}

@MainActor final class Monitor: ObservableObject {
    @Published var usage: Usage?
    @Published var history: [HistoryPoint] = []
    @Published var error: String?
    @Published var busy = false
    @Published var setupMode = false
    @Published var now = Date()
    @Published private(set) var networkAvailable = true
    @Published private(set) var networkChecked = false
    @Published var intervalMinutes: Int { didSet { UserDefaults.standard.set(intervalMinutes, forKey: "intervalMinutes") } }
    @Published var displayWeekly: Bool { didSet { UserDefaults.standard.set(displayWeekly, forKey: "displayWeekly") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private var currentProcess: Process?
    private var workerProcess: Process?
    private var workerOutput: Pipe?
    private var pendingRequestID: String?
    private var pendingRequestAt: Date?
    private var workerRestartAt = Date.distantPast
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "QuotaMeter.network", qos: .utility)
    private var pendingRefreshOnReconnect = false

    init() {
        let storedInterval = UserDefaults.standard.object(forKey: "intervalMinutes") as? Int
        intervalMinutes = [1, 2, 3, 5].contains(storedInterval ?? 3) ? (storedInterval ?? 3) : 3
        displayWeekly = false // 5時間枠を常にメニューバーに表示
        load()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.updateNetworkStatus(available)
            }
        }
        pathMonitor.start(queue: pathQueue)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.now = Date()
                self.load()
                self.checkWorkerResponse()
                if self.networkChecked && self.networkAvailable && !self.busy && self.now.timeIntervalSince(self.lastAttempt) >= Double(self.intervalMinutes * 60) { self.refresh() }
            }
        }
        // Wait for the initial NWPathMonitor result before opening Chrome.
    }
    private var hasConfig: Bool { FileManager.default.fileExists(atPath: Storage.directory.appendingPathComponent("config.json").path) }
    private func updateNetworkStatus(_ available: Bool) {
        let wasChecked = networkChecked
        let wasAvailable = networkAvailable
        networkChecked = true
        networkAvailable = available
        if !available {
            pendingRefreshOnReconnect = true
            if !busy { error = "オフラインのため更新を一時停止しています。" }
        } else if !wasChecked || !wasAvailable {
            // An actual fetch may still fail even if the network path is satisfied.
            error = nil
            if hasConfig && !busy {
                pendingRefreshOnReconnect = false
                refresh()
            } else if busy {
                pendingRefreshOnReconnect = true
            }
        }
    }
    var stale: Bool { guard let usage else { return true }; return now.timeIntervalSince(usage.fetchedAt) > max(900, Double(intervalMinutes * 180)) }
    var dataOutdated: Bool { !networkAvailable || stale || error != nil }
    var networkDescription: String {
        if !networkChecked { return "接続確認中" }
        if !networkAvailable { return "オフライン・更新停止中" }
        if error != nil { return "接続あり・取得失敗" }
        return "オンライン"
    }
    var nextRefreshDescription: String {
        if !networkAvailable { return "オンライン復帰後に更新" }
        if busy { return "更新中" }
        let seconds = max(0, Int(Double(intervalMinutes * 60) - now.timeIntervalSince(lastAttempt)))
        return seconds == 0 ? "まもなく更新" : "約\(Int(ceil(Double(seconds) / 60)))分後"
    }
    var selectedLimit: Limit? { usage?.fiveHour }
    var statusText: String { if busy { return "更新中" }; if !networkAvailable { return "オフライン" }; if error != nil { return "取得失敗" }; if stale { return "情報が古い" }; return "最新" }
    func load() {
        if let data = try? Data(contentsOf: Storage.directory.appendingPathComponent("usage.json")), let value = try? Storage.decoder().decode(Usage.self, from: data) { usage = value }
        if let text = try? String(contentsOf: Storage.directory.appendingPathComponent("history.jsonl"), encoding: .utf8) {
            let rows = text.split(separator: "\n").suffix(1500)
            var points: [HistoryPoint] = []
            for row in rows {
                guard let data = String(row).data(using: .utf8), let item = try? Storage.decoder().decode(Usage.self, from: data) else { continue }
                if let value = item.fiveHour?.remainingPercent { points.append(HistoryPoint(date: item.fetchedAt, value: value, series: "5時間")) }
                if let value = item.weekly?.remainingPercent { points.append(HistoryPoint(date: item.fetchedAt, value: value, series: "週間")) }
            }
            history = points
        }
    }
    private var commandURL: URL { Storage.directory.appendingPathComponent("worker-command.json") }
    private var responseURL: URL { Storage.directory.appendingPathComponent("worker-response.json") }
    private func nodeAndScript() -> (URL, URL)? {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("collector/collector.mjs"), FileManager.default.fileExists(atPath: script.path) else {
            error = "取得モジュールが見つかりません。アプリを再ビルドしてください。"; return nil
        }
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "Node.js が見つかりません。"; return nil
        }
        return (URL(fileURLWithPath: node), script)
    }
    private func startWorker() -> Bool {
        if workerProcess?.isRunning == true { return true }
        guard Date().timeIntervalSince(workerRestartAt) > 4, let (node, script) = nodeAndScript() else { return false }
        workerRestartAt = Date()
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path, "--daemon"]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData // Drain output to prevent a blocked worker.
        }
        do {
            try process.run()
            workerProcess = process
            workerOutput = output
            return true
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            self.error = "収集プロセスを起動できません: \(error.localizedDescription)"
            return false
        }
    }
    private func sendWorkerCommand(_ action: String) {
        let id = UUID().uuidString
        let command = ["id": id, "action": action]
        do {
            try Storage.prepare()
            let data = try JSONSerialization.data(withJSONObject: command)
            let temp = Storage.directory.appendingPathComponent("worker-command.tmp")
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: commandURL.path) { try FileManager.default.removeItem(at: commandURL) }
            try FileManager.default.moveItem(at: temp, to: commandURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: commandURL.path)
            pendingRequestID = id
            pendingRequestAt = Date()
        } catch {
            busy = false
            self.error = "更新指示の保存に失敗: \(error.localizedDescription)"
        }
    }
    private func checkWorkerResponse() {
        guard let id = pendingRequestID else { return }
        if let data = try? Data(contentsOf: responseURL),
           let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           response["id"] as? String == id {
            busy = false
            pendingRequestID = nil
            pendingRequestAt = nil
            error = (response["ok"] as? Bool == true) ? nil : (response["error"] as? String ?? "取得失敗")
            load()
            if pendingRefreshOnReconnect && networkAvailable {
                pendingRefreshOnReconnect = false
                refresh()
            }
        } else if let started = pendingRequestAt, Date().timeIntervalSince(started) > 110 {
            busy = false
            pendingRequestID = nil
            pendingRequestAt = nil
            error = "取得がタイムアウトしました。次の更新で再試行します。"
            if workerProcess?.isRunning != true { workerProcess = nil }
        }
    }
    func refresh() {
        guard !busy else { return }
        if networkChecked && !networkAvailable {
            error = "オフラインのため取得できません。接続復帰後に自動更新します。"
            pendingRefreshOnReconnect = true
            return
        }
        busy = true; error = nil; lastAttempt = Date()
        guard startWorker() else { busy = false; return }
        sendWorkerCommand("refresh")
    }
    func beginSetup() {
        guard !busy else { return }
        if networkChecked && !networkAvailable { error = "オフラインのため初期設定できません。"; return }
        // Manual login uses the same persistent Chrome profile: close Playwright first.
        stopWorker()
        busy = true; setupMode = true; error = nil; lastAttempt = Date()
        guard let (node, script) = nodeAndScript() else { busy = false; setupMode = false; return }
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path, "--setup"]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        currentProcess = process
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: String?
            do {
                // The worker must exit before ordinary Chrome opens the same profile.
                Thread.sleep(forTimeInterval: 2)
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = process.terminationStatus == 0 ? nil : String(decoding: data, as: UTF8.self).suffix(800).description
            } catch { result = error.localizedDescription }
            DispatchQueue.main.async { [weak self, result] in
                guard let self else { return }
                self.busy = false; self.setupMode = false; self.currentProcess = nil
                self.error = result; self.load()
                self.workerRestartAt = .distantPast
                if self.networkAvailable { self.refresh() }
            }
        }
    }
    func finishSetup() {
        guard setupMode, let process = currentProcess, process.isRunning else { return }
        process.terminate()
    }
    func stopWorker() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
        currentProcess = nil
        if let process = workerProcess, process.isRunning {
            process.terminate()
        }
        workerOutput?.fileHandleForReading.readabilityHandler = nil
        workerOutput = nil
        workerProcess = nil
        pendingRequestID = nil
        pendingRequestAt = nil
    }
    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { self.error = "ログイン項目の変更に失敗: \(error.localizedDescription)" }
    }
}

struct Meter: View {
    let value: Double?
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(min(100, max(0, value ?? 0))) / 100)
            }
        }.frame(height: 6)
    }
    var tint: Color { guard let value else { return .gray }; return value <= 15 ? .red : value <= 35 ? .orange : .green }
}


struct LimitCard: View {
    let title: String
    let limit: Limit?
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(limit.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—")
                    .font(.system(size: 27, weight: .bold, design: .rounded)).monospacedDigit()
            }
            Meter(value: limit?.remainingPercent)
            Text(resetLabel).font(.caption).foregroundStyle(.secondary)
        }.padding(15).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
    private var resetLabel: String {
        guard let reset = limit?.resetAt else { return "リセット時刻不明" }
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        if minutes == 0 { return "リセット予定時刻を経過・再取得待ち" }
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        return "リセットまで \(days > 0 ? "\(days)日 " : "")\(hours > 0 ? "\(hours)時間 " : "")\(mins)分（概算）"
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    let showDashboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QuotaMeter").font(.title3.weight(.semibold))
                    Text("非公式 · Work & Codex").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if monitor.busy { ProgressView().controlSize(.small) }
                Circle().fill(!monitor.networkAvailable ? .gray : monitor.dataOutdated ? .orange : .green).frame(width: 7, height: 7)
            }
            LimitCard(title: "5時間の利用枠", limit: monitor.usage?.fiveHour, now: monitor.now)
            LimitCard(title: "週間の利用枠", limit: monitor.usage?.weekly, now: monitor.now)
            HStack(spacing: 8) {
                Image(systemName: monitor.networkAvailable ? "wifi" : "wifi.slash")
                Text(monitor.networkDescription)
                Spacer()
                Text("次回: \(monitor.nextRefreshDescription)")
            }.font(.caption).foregroundStyle(.secondary)
            if monitor.dataOutdated && monitor.usage != nil {
                Text("表示中の残量は最後に正常取得した値です。最新とは限りません。")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let error = monitor.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(monitor.usage.map { "取得: \($0.fetchedAt.formatted(date: .omitted, time: .shortened))" } ?? "未取得")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(monitor.busy).help("今すぐ更新")
                Button("詳細・設定") { showDashboard() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(16).frame(width: 330)
    }
}

struct SetupGuideView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if monitor.setupMode {
                Label("Chrome でログインしてください", systemImage: "person.crop.circle.badge.clock")
                    .font(.title3.bold())
                Text("ChatGPT へのログインが完了したら，この画面か Chrome の上に表示される案内から「ログイン完了」を選んでください．")
                    .foregroundStyle(.secondary)
                Button("ログイン完了") { monitor.finishSetup() }
                    .buttonStyle(.borderedProminent)
            } else if monitor.usage == nil {
                Label("最初に ChatGPT へログインします", systemImage: "person.crop.circle.badge.plus")
                    .font(.title3.bold())
                VStack(alignment: .leading, spacing: 8) {
                    Label("Chrome を開く", systemImage: "1.circle.fill")
                    Label("ChatGPT にログイン", systemImage: "2.circle.fill")
                    Label("QuotaMeter で「ログイン完了」を選択", systemImage: "3.circle.fill")
                }
                Button("Chrome を開いてログイン") { monitor.beginSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(monitor.busy)
            } else {
                HStack {
                    Label("自動取得の準備ができています", systemImage: "checkmark.circle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                    Spacer()
                    Button("ログインし直す") { monitor.beginSetup() }
                        .disabled(monitor.busy)
                }
                Text("ウィンドウを閉じてもメニューバーで動作を続けます．残量は標準 3 分間隔で更新します．")
                    .foregroundStyle(.secondary)
            }
            if let error = monitor.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(18)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("QuotaMeter").font(.largeTitle.bold())
                        Text("非公式 · Work & Codex の利用枠").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("今すぐ更新") { monitor.refresh() }.disabled(monitor.busy)
                }
                SetupGuideView(monitor: monitor)
                HStack(alignment: .top, spacing: 14) {
                    LimitCard(title: "5時間の利用枠", limit: monitor.usage?.fiveHour, now: monitor.now)
                    LimitCard(title: "週間の利用枠", limit: monitor.usage?.weekly, now: monitor.now)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("残量の推移").font(.title3.bold())
                    if monitor.history.isEmpty {
                        ContentUnavailableView("履歴はまだありません", systemImage: "chart.xyaxis.line", description: Text("自動取得が成功すると履歴が蓄積されます"))
                    } else {
                        Chart(monitor.history) { point in
                            LineMark(x: .value("日時", point.date), y: .value("残量", point.value))
                                .foregroundStyle(by: .value("枠", point.series))
                        }.chartYScale(domain: 0...100).frame(height: 210)
                    }
                }.padding(18).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 14) {
                    Text("設定").font(.title3.bold())
                    HStack {
                        Label(monitor.networkDescription, systemImage: monitor.networkAvailable ? "wifi" : "wifi.slash")
                        Spacer()
                        Text("次回更新: \(monitor.nextRefreshDescription)")
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("自動更新間隔")
                        Spacer()
                        Picker("自動更新間隔", selection: $monitor.intervalMinutes) {
                            Text("1分").tag(1); Text("2分").tag(2); Text("3分（推奨）").tag(3); Text("5分").tag(5)
                        }.labelsHidden().frame(width: 120)
                    }
                    Text("標準3分。オフライン時は取得を停止し、接続復帰時に再取得します。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("メニューバーは5時間枠を表示（週間枠は詳細で確認）").foregroundStyle(.secondary)
                    Toggle("Macログイン時に自動起動", isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.updateLaunchAtLogin($0) }))
                }.padding(18).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                HStack {
                    Text("最終取得: \(monitor.usage?.fetchedAt.formatted() ?? "未取得")")
                    Spacer()
                    Button("データフォルダを開く") { NSWorkspace.shared.open(Storage.directory) }
                    Button("終了") { NSApp.terminate(nil) }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(minWidth: 630, minHeight: 610)
    }
}

// AppKit owns the menu-bar item because MenuBarExtra labels can discard custom
// SwiftUI drawing on some macOS versions. The rest of the UI stays in SwiftUI.
@MainActor final class StatusBarController: NSObject {
    private let monitor: Monitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var dashboard: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 330, height: 360)
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor, showDashboard: { [weak self] in
            self?.showDashboard()
        }))
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])
        monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateStatus() }
        }.store(in: &subscriptions)
        updateStatus()
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let percent = monitor.selectedLimit?.remainingPercent
        let label = percent.map { "\(Int($0.rounded()))%" } ?? "--%"
        let staleMarker = monitor.dataOutdated ? " !" : ""
        let gauge = StatusGaugeImage.make(percent: percent)
        let attachment = NSTextAttachment()
        attachment.image = gauge
        attachment.bounds = CGRect(x: 0, y: -1, width: StatusGaugeImage.imageWidth, height: 13)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: "  " + label + staleMarker, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]))
        button.attributedTitle = title
        button.toolTip = "QuotaMeter — 5時間の残量: \(label) | \(monitor.networkDescription)\(monitor.dataOutdated ? "（最終正常取得値）" : "")"
        button.image = nil
        button.imagePosition = .noImage
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func showDashboard() {
        popover.performClose(nil)
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "QuotaMeter"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: DashboardView(monitor: monitor))
            dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SetupAssistantView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ChatGPT にログインできましたか？")
                .font(.headline)
            Text("ログイン後に完了を選ぶと，専用 Chrome を閉じて自動取得を開始します．")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("ログイン完了") { monitor.finishSetup() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 390)
    }
}

@MainActor final class SetupAssistantController {
    private let monitor: Monitor
    private var panel: NSPanel?
    private var subscription: AnyCancellable?

    init(monitor: Monitor) {
        self.monitor = monitor
        subscription = monitor.$setupMode.removeDuplicates().sink { [weak self] active in
            if active { self?.show() } else { self?.panel?.orderOut(nil) }
        }
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 145),
                                styleMask: [.titled, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "QuotaMeter — ログイン"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = NSHostingController(rootView: SetupAssistantView(monitor: monitor))
            self.panel = panel
        }
        if let panel, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24,
                                         y: visible.maxY - panel.frame.height - 24))
        }
        panel?.orderFrontRegardless()
    }
}

// Segmented, car-fuel-gauge-style indicator: ten discrete rounded ticks.
// An empty tick stays visible, so 0% and missing data are distinguishable.
enum StatusGaugeImage {
    private static let segmentCount = 10
    private static let segmentWidth: CGFloat = 5
    private static let gap: CGFloat = 2
    private static let segmentHeight: CGFloat = 7
    static let imageWidth: CGFloat = CGFloat(segmentCount) * segmentWidth + CGFloat(segmentCount - 1) * gap

    static func make(percent: Double?) -> NSImage {
        let size = NSSize(width: imageWidth, height: 13)
        let image = NSImage(size: size, flipped: false) { _ in
            let clamped = percent.map { min(100, max(0, $0)) }
            // Round UP so even a tiny positive allowance is visible as one tick.
            let filledCount = clamped.map { Int(ceil($0 / 10.0)) } ?? 0
            let activeColor: NSColor
            if let clamped, clamped <= 20 {
                activeColor = .systemRed
            } else {
                activeColor = .labelColor
            }
            for index in 0..<segmentCount {
                let rect = NSRect(
                    x: CGFloat(index) * (segmentWidth + gap),
                    y: 3,
                    width: segmentWidth,
                    height: segmentHeight
                )
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
                if clamped != nil && index < filledCount {
                    activeColor.setFill()
                } else {
                    NSColor.secondaryLabelColor.withAlphaComponent(0.28).setFill()
                }
                path.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var statusController: StatusBarController?
    private var setupAssistant: SetupAssistantController?
    private var instanceLock: Int32 = -1

    private func prepareLaunch() -> Bool {
        // The v3.0 binary cannot understand our new lock. Refuse to share its profile.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.allowance.monitor").isEmpty {
            let alert = NSAlert()
            alert.messageText = "AllowanceMonitor を終了してください"
            alert.informativeText = "同じChromeプロファイルと履歴を使用します。旧アプリを終了してからQuotaMeterを開いてください。"
            alert.runModal()
            return false
        }
        do {
            try Storage.prepare()
            let lockPath = Storage.directory.appendingPathComponent("quotameter.lock").path
            instanceLock = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
                if instanceLock >= 0 { Darwin.close(instanceLock); instanceLock = -1 }
                return false
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "データフォルダを開けません"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
        PreferencesMigration.apply(to: .standard,
            legacy: UserDefaults.standard.persistentDomain(forName: "dev.allowance.monitor"))
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { monitor?.stopWorker() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.showDashboard()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard prepareLaunch() else { NSApp.terminate(nil); return }
        let monitor = Monitor()
        self.monitor = monitor
        let statusController = StatusBarController(monitor: monitor)
        self.statusController = statusController
        setupAssistant = SetupAssistantController(monitor: monitor)
        statusController.showDashboard()
    }
}

// A pure AppKit lifecycle avoids SwiftUI's implicit Settings window and
// makes this a genuine menu-bar-only application.
@main enum QuotaMeterApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppLifecycle()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
