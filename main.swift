// Claude 구독 사용량 바탕화면 위젯
// Claude Code CLI 로그인 토큰(키체인 "Claude Code-credentials")으로
// 5시간 세션 한도 / 주간 한도 사용률을 5분마다 가져와 바탕화면에 표시합니다.

import AppKit
import SwiftUI

// MARK: - 자격 증명 (키체인)

enum UsageError: LocalizedError {
    case notLoggedIn, http(Int), badResponse, rateLimited(TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Claude Code 로그인 필요\n터미널에서: claude auth login"
        case .http(let c): return "서버 오류 (HTTP \(c))"
        case .badResponse: return "응답 형식을 읽을 수 없음"
        case .rateLimited: return "요청 제한 — 잠시 후 다시 시도"
        }
    }
}

enum Keychain {
    static let service = "Claude Code-credentials"

    @discardableResult
    static func run(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    static func load() -> [String: Any]? {
        let (status, text) = run(["find-generic-password", "-s", service, "-w"])
        guard status == 0, let d = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj
    }

    static func account() -> String? {
        let (status, text) = run(["find-generic-password", "-s", service])
        guard status == 0 else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"acct\"") {
            if let r = line.range(of: "=\"") {
                return String(line[r.upperBound...].dropLast())
            }
        }
        return nil
    }

    static func save(_ obj: [String: Any]) {
        guard let acct = account(),
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        run(["add-generic-password", "-U", "-s", service, "-a", acct, "-w", s])
    }
}

// MARK: - API

struct LimitItem: Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
}

enum UsageAPI {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static func accessToken() async throws -> String {
        guard var root = Keychain.load(),
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { throw UsageError.notLoggedIn }

        // 만료 1분 전이면 갱신 (Claude Code CLI와 같은 방식으로 키체인에 다시 저장)
        let expiresMs = (oauth["expiresAt"] as? Double) ?? 0
        if expiresMs > 0, Date().timeIntervalSince1970 * 1000 > expiresMs - 60_000,
           let refresh = oauth["refreshToken"] as? String {
            var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newToken = j["access_token"] as? String {
                oauth["accessToken"] = newToken
                if let r = j["refresh_token"] as? String { oauth["refreshToken"] = r }
                if let e = j["expires_in"] as? Double {
                    oauth["expiresAt"] = (Date().timeIntervalSince1970 + e) * 1000
                }
                root["claudeAiOauth"] = oauth
                Keychain.save(root)
                return newToken
            }
            throw UsageError.notLoggedIn
        }
        return token
    }

    static let titles: [String: String] = [
        "five_hour": "5시간 세션",
        "seven_day": "주간 (전체)",
        "seven_day_opus": "주간 (Opus)",
        "seven_day_sonnet": "주간 (Sonnet)",
        "seven_day_oauth_apps": "주간 (앱)",
    ]
    static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    static func fetch() async throws -> [LimitItem] {
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw UsageError.notLoggedIn }
        if code == 429 {
            let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
                .flatMap(Double.init)
            throw UsageError.rateLimited(ra)
        }
        guard code == 200 else { throw UsageError.http(code) }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        func parseDate(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }

        // 신형 응답: "limits" 배열 (모델별 주간 한도 포함)
        if let limits = j["limits"] as? [[String: Any]], !limits.isEmpty {
            var out: [LimitItem] = []
            for (i, l) in limits.enumerated() {
                guard let pct = (l["percent"] as? NSNumber)?.doubleValue else { continue }
                let kind = l["kind"] as? String ?? "limit"
                var title: String
                switch kind {
                case "session": title = "5시간 세션"
                case "weekly_all": title = "주간 (전체)"
                default:
                    let scope = l["scope"] as? [String: Any]
                    let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                    let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                    title = "주간 (\(model ?? surface ?? kind))"
                }
                out.append(LimitItem(id: "\(i)-\(kind)", title: title, percent: pct,
                                     resetsAt: parseDate(l["resets_at"])))
            }
            if !out.isEmpty { return out }
        }

        // 구형 응답: five_hour / seven_day ... 키
        var items: [LimitItem] = []
        for (key, value) in j {
            guard let d = value as? [String: Any],
                  let util = (d["utilization"] as? NSNumber)?.doubleValue else { continue }
            var reset: Date?
            if let s = d["resets_at"] as? String { reset = iso.date(from: s) ?? isoPlain.date(from: s) }
            let title = titles[key] ?? key.replacingOccurrences(of: "_", with: " ")
            items.append(LimitItem(id: key, title: title, percent: util, resetsAt: reset))
        }
        guard !items.isEmpty else { throw UsageError.badResponse }
        return items.sorted {
            (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id)
        }
    }
}

// MARK: - 상태

@MainActor
final class UsageModel: ObservableObject {
    @Published var items: [LimitItem] = []
    @Published var error: String?
    @Published var updated: Date?
    @Published var now = Date()
    @Published var rateLimited = false
    private var timer: Timer?
    private var tick: Timer?
    private var inFlight = false

    // 기본 5분 간격. 요청 제한(429)이 오면 간격을 2배씩 늘림 (최대 30분)
    static let baseInterval: TimeInterval = 300
    static let maxInterval: TimeInterval = 1800
    private var interval: TimeInterval = baseInterval

    func start() {
        refresh()
        tick = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        Task {
            defer { inFlight = false }
            do {
                let r = try await UsageAPI.fetch()
                items = r; error = nil; rateLimited = false; updated = Date()
                interval = Self.baseInterval
            } catch UsageError.rateLimited(let retryAfter) {
                rateLimited = true
                error = UsageError.rateLimited(retryAfter).errorDescription
                interval = min(Self.maxInterval, max(interval * 2, retryAfter ?? 0))
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            schedule(after: interval)
        }
    }
}

// MARK: - 화면

func color(for p: Double, base: Color = Color(red: 0.85, green: 0.47, blue: 0.34)) -> Color {
    p >= 90 ? Color(red: 0.95, green: 0.35, blue: 0.3)
        : p >= 70 ? Color(red: 0.98, green: 0.7, blue: 0.25)
        : base // 기본: Claude 오렌지
}

let sessionGreen = Color(red: 0.3, green: 0.78, blue: 0.45)

func isSession(_ item: LimitItem) -> Bool {
    item.id == "five_hour" || item.id.hasSuffix("-session")
}

func remaining(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return "곧 초기화" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)일 \(h)시간 후 초기화" }
    if h > 0 { return "\(h)시간 \(m)분 후 초기화" }
    return "\(m)분 후 초기화"
}

struct LimitRow: View {
    let item: LimitItem
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(item.percent.rounded()))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.12))
                    Capsule().fill(color(for: item.percent,
                                         base: isSession(item) ? sessionGreen
                                             : Color(red: 0.85, green: 0.47, blue: 0.34)))
                        .frame(width: max(4, g.size.width * min(item.percent, 100) / 100))
                }
            }
            .frame(height: 6)
            Text(remaining(item.resetsAt, now: now))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

struct LimitRing: View {
    let item: LimitItem
    let now: Date
    var label: String {
        // "주간 (전체)" → "전체", "주간 (Fable)" → "Fable"
        if let a = item.title.firstIndex(of: "("), let b = item.title.lastIndex(of: ")"), a < b {
            return String(item.title[item.title.index(after: a)..<b])
        }
        return item.title
    }
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.005, min(item.percent, 100) / 100))
                    .stroke(color(for: item.percent, base: sessionGreen), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(item.percent.rounded()))%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 58, height: 58)
            Text("주간 · \(label)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(remaining(item.resetsAt, now: now).replacingOccurrences(of: " 초기화", with: ""))
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct WidgetView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(color(for: 0))
                Text("Claude 사용량").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let u = model.updated {
                    Text(u, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if let e = model.error, model.items.isEmpty {
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.items.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                // 1단: 5시간 세션 막대
                ForEach(model.items.filter(isSession)) { LimitRow(item: $0, now: model.now) }
                // 2단: 주간 한도 원형 차트 (한 줄)
                let weekly = model.items.filter { !isSession($0) }
                if !weekly.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(weekly) { LimitRing(item: $0, now: model.now) }
                    }
                }
                if model.rateLimited {
                    Text("요청 제한으로 갱신 지연 중").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if let e = model.error {
                    Text("⚠︎ 최근 갱신 실패: \(e)").font(.system(size: 10)).foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(width: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.15)))
        .contextMenu {
            Button("지금 새로고침") { model.refresh() }
            Divider()
            Button("종료") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 앱 / 창

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSPanel!
    let model = UsageModel()

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingView(rootView: WidgetView(model: model))
        host.frame.size = host.fittingSize

        window = DesktopPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // 바탕화면 아이콘 바로 위 레벨: 다른 앱 창 뒤에 깔림
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("ClaudeUsageWidget")
        if !window.setFrameUsingName("ClaudeUsageWidget"), let s = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: s.maxX - window.frame.width - 24,
                                          y: s.maxY - window.frame.height - 24))
        }
        window.orderFront(nil)

        // 항목 수가 바뀌면 창 높이를 맞춤 (상단 고정)
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                               object: host, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit(host) }
        }
        host.postsFrameChangedNotifications = true
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit(host) }
        }

        model.start()
    }

    func fit(_ host: NSView) {
        let size = host.fittingSize
        guard abs(size.height - window.frame.height) > 0.5 else { return }
        var f = window.frame
        f.origin.y += f.height - size.height
        f.size = size
        window.setFrame(f, display: true)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // Dock 아이콘 없음
    app.run()
}
