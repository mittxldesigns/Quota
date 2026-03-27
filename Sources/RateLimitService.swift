import Foundation
import SwiftUI
import UserNotifications

// Shell-safe path quoting
private func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// Peak hours tracking

enum ClaudePeakStatus: String {
    case peak      = "Peak Hours"
    case offPeak   = "Off-Peak"
    case weekend   = "Weekend"

    
    static var current: ClaudePeakStatus {
        let pt = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pt
        let now = Date()
        let weekday = cal.component(.weekday, from: now) // 1=Sun, 7=Sat
        let hour = cal.component(.hour, from: now)

        if weekday == 1 || weekday == 7 { return .weekend }
        if hour >= 5 && hour < 11 { return .peak }
        return .offPeak
    }

    var icon: String {
        switch self {
        case .peak:    return "flame.fill"
        case .offPeak: return "moon.fill"
        case .weekend: return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .peak:    return Color(red: 1.0, green: 0.45, blue: 0.25)
        case .offPeak: return Color(red: 0.28, green: 0.82, blue: 0.50)
        case .weekend: return Color(red: 0.28, green: 0.82, blue: 0.50)
        }
    }

    var tip: String {
        switch self {
        case .peak:    return "Tokens cost more during peak (5-11 AM PT weekdays)"
        case .offPeak: return "Normal token rates — best time to use Claude"
        case .weekend: return "Full capacity all day on weekends"
        }
    }

    
    var timeUntilChange: String {
        let pt = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pt
        let now = Date()
        let hour = cal.component(.hour, from: now)

        switch self {
        case .peak:
            // Peak ends at 11:00 AM PT
            if let target = cal.date(bySettingHour: 11, minute: 0, second: 0, of: now),
               target > now {
                return formatCountdown(target.timeIntervalSince(now))
            }
        case .offPeak:
            var targetDate = now
            if hour >= 11 {
                targetDate = cal.date(byAdding: .day, value: 1, to: now) ?? now
            }
            // Skip weekends
            var wd = cal.component(.weekday, from: targetDate)
            while wd == 1 || wd == 7 {
                targetDate = cal.date(byAdding: .day, value: 1, to: targetDate) ?? targetDate
                wd = cal.component(.weekday, from: targetDate)
            }
            if let target = cal.date(bySettingHour: 5, minute: 0, second: 0, of: targetDate),
               target > now {
                return formatCountdown(target.timeIntervalSince(now))
            }
        case .weekend:
            var monday = cal.date(byAdding: .day, value: 1, to: now) ?? now
            while cal.component(.weekday, from: monday) != 2 {
                monday = cal.date(byAdding: .day, value: 1, to: monday) ?? monday
            }
            if let target = cal.date(bySettingHour: 5, minute: 0, second: 0, of: monday),
               target > now {
                return formatCountdown(target.timeIntervalSince(now))
            }
        }
        return ""
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        let mins = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(max(1, mins))m"
    }
}

struct RateLimitData {
    var fiveHourUtilization: Double = 0    // 0.0 to 1.0
    var fiveHourReset: Date = Date()
    var sevenDayUtilization: Double = 0
    var sevenDayReset: Date = Date()
    var status: String = "allowed"
    var planTier: String?

    // Per-model breakdowns (from API)
    var sonnetUtilization: Double?    // 7-day Sonnet usage
    var opusUtilization: Double?      // 7-day Opus usage

    // Extra usage (overage billing)
    var extraUsageEnabled: Bool = false
    var extraUsageCreditsUsed: Double?

    var fiveHourPercent: Double { fiveHourUtilization }
    var sevenDayPercent: Double { sevenDayUtilization }

    var activeLimitPercent: Double { max(fiveHourPercent, sevenDayPercent) }
    var representativeClaim: String {
        sevenDayPercent > fiveHourPercent ? "seven_day" : "five_hour"
    }

    func resetFormatted(_ date: Date) -> String {
        let s = date.timeIntervalSinceNow
        if s <= 0           { return "soon" }
        if s < 60           { return "in \(Int(s))s" }
        if s < 3600         { return "in \(Int(s / 60))m" }
        let h = Int(s / 3600)
        let m = Int((s.truncatingRemainder(dividingBy: 3600)) / 60)
        if h >= 24 {
            return "in \(h / 24)d \(h % 24)h"
        }
        return "in \(h)h \(m)m"
    }

    var fiveHourResetFormatted: String  { resetFormatted(fiveHourReset) }
    var sevenDayResetFormatted: String  { resetFormatted(sevenDayReset) }

    // Burn rate: "At this pace, you'll hit your 5h limit in ~Xh Ym"
    // Uses elapsed time in the current window vs utilization consumed
    var burnRateEstimate: String? {
        guard fiveHourUtilization > 0.05 else { return nil }  // Need some data
        let remaining = 1.0 - fiveHourUtilization
        if remaining <= 0 { return "Limit reached" }
        // Elapsed time in current window = 5h - time until reset
        let windowSeconds: Double = 5 * 3600
        let timeUntilReset = max(0, fiveHourReset.timeIntervalSinceNow)
        let elapsed = windowSeconds - timeUntilReset
        guard elapsed > 60 else { return nil }  // Need at least a minute of data
        let rate = fiveHourUtilization / elapsed  // % per second
        let secondsUntilFull = remaining / rate
        let h = Int(secondsUntilFull / 3600)
        let m = Int(secondsUntilFull.truncatingRemainder(dividingBy: 3600) / 60)
        if h > 10 { return nil }  // Too far out to be useful
        if h > 0 { return "~\(h)h \(m)m left at this pace" }
        if m > 0 { return "~\(m)m left at this pace" }
        return "Almost at limit"
    }

    // Plan recommendation based on usage patterns
    var planRecommendation: String? {
        guard let tier = planTier?.lowercased() else { return nil }
        let v5 = fiveHourUtilization
        let v7 = sevenDayUtilization

        if tier == "pro" {
            if v5 >= 0.9 || v7 >= 0.75 {
                return "You're pushing Pro limits — Max (5x) would give you more headroom"
            }
        } else if tier == "max_5" {
            if v5 >= 0.9 || v7 >= 0.8 {
                return "Hitting Max 5x ceiling often — consider Max 20x"
            }
            if v5 < 0.15 && v7 < 0.15 {
                return "Light usage — Pro might be enough and save you money"
            }
        } else if tier == "max_20" {
            if v5 < 0.1 && v7 < 0.1 {
                return "Very light usage for 20x — you could save with Max 5x"
            }
        }
        return nil
    }
}

@MainActor
class RateLimitService: ObservableObject {
    @Published var rateLimitData: RateLimitData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isConnected = false
    @Published var lastUpdated: Date?
    @Published var refreshInterval: Double = 60 {
        didSet { restartTimer() }
    }

    private var credentials: OAuthCredentials?
    private var timer: Timer?
    private var callsWithCurrentToken = 0
    private let maxCallsPerToken = 4

    // Deduplication: prevent overlapping fetches
    private var isFetching = false

    // Exponential backoff on consecutive failures
    private var consecutiveFailures = 0
    private let maxBackoffInterval: TimeInterval = 600  // 10 min cap

    // Notification thresholds — only fire once per crossing
    private var notified5hSoft = false
    private var notified5hHard = false
    private var notified7dHard = false
    private var notifiedCritical = false
    private var previous5hUtilization: Double = 0  // For detecting resets
    private var previousPeakStatus: ClaudePeakStatus?  // For detecting peak transitions
    private var peakCheckTimer: Timer?

    // User-selected plan (persisted)
    @Published var userPlan: String {
        didSet { UserDefaults.standard.set(userPlan, forKey: "userPlan") }
    }
    @Published var showPlanPicker = false  // Show after first login

    // Live "updated ago" ticker
    private var tickTimer: Timer?

    
    @Published var updateAvailable: String?
    @Published var updateURL: URL?
    private var hasCheckedUpdate = false

    

    var menuBarLabel: String {
        guard let d = rateLimitData else { return "—" }
        return "\(Int(d.fiveHourUtilization * 100))%"
    }

    var menuBarValue: Double {
        rateLimitData?.fiveHourUtilization ?? 0
    }

    var statusColor: Color {
        guard let d = rateLimitData else { return .secondary }
        switch d.fiveHourUtilization {
        case 0.9...:  return Color(red: 1.0, green: 0.27, blue: 0.22)
        case 0.75...: return .orange
        case 0.50...: return .yellow
        default:      return Color(red: 0.28, green: 0.82, blue: 0.50)
        }
    }

    var planDisplayName: String? {
        // User-selected plan takes priority, then API-detected
        let tier = userPlan.isEmpty ? rateLimitData?.planTier : userPlan
        guard let t = tier, !t.isEmpty else { return nil }
        switch t.lowercased() {
        case "pro":           return "Pro"
        case "max_5", "max5": return "Max (5x)"
        case "max_20", "max20": return "Max (20x)"
        case "team":          return "Team"
        case "enterprise":    return "Enterprise"
        case "free":          return "Free"
        default:              return t.capitalized
        }
    }

    @Published var lastUpdatedFormatted: String = "never"

    private func updateTimestamp() {
        guard let d = lastUpdated else { lastUpdatedFormatted = "never"; return }
        let s = Date().timeIntervalSince(d)
        if s < 5  { lastUpdatedFormatted = "just now" }
        else if s < 60 { lastUpdatedFormatted = "\(Int(s))s ago" }
        else { lastUpdatedFormatted = "\(Int(s / 60))m ago" }
    }

    

    init() {
        // Load saved plan
        userPlan = UserDefaults.standard.string(forKey: "userPlan") ?? ""

        requestNotificationPermission()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTimestamp() }
        }

        // Check peak status every 60s — notify when transitioning to off-peak
        previousPeakStatus = ClaudePeakStatus.current
        peakCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPeakTransition() }
        }

        if let creds = CredentialStore.load() {
            credentials = creds
            isConnected = true
            startPolling()
        }
        cleanupOrphanedMount()
        Task { await checkForUpdate() }
    }

    deinit {
        timer?.invalidate()
        tickTimer?.invalidate()
        peakCheckTimer?.invalidate()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    

    private func checkPeakTransition() {
        let current = ClaudePeakStatus.current
        guard let prev = previousPeakStatus, prev != current else {
            previousPeakStatus = current
            return
        }
        previousPeakStatus = current

        // Notify when transitioning TO off-peak or weekend (more limits!)
        if (prev == .peak && current == .offPeak) || (prev == .peak && current == .weekend) {
            sendNotification(
                title: "Off-peak rates active",
                body: "Your tokens go further now. Good time to use Claude.",
                sound: false
            )
        } else if prev != .weekend && current == .weekend {
            sendNotification(
                title: "Weekend rates active",
                body: "Full capacity all weekend. No peak-hour throttling.",
                sound: false
            )
        } else if current == .peak && prev != .peak {
            // Gentle heads-up when peak starts
            sendNotification(
                title: "Peak hours started",
                body: "5-11 AM PT — tokens cost more. Consider waiting for off-peak.",
                sound: false
            )
        }
    }

    func connect(credentials creds: OAuthCredentials) {
        credentials = creds
        CredentialStore.save(creds)
        isConnected = true
        errorMessage = nil
        callsWithCurrentToken = 0
        consecutiveFailures = 0
        if tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateTimestamp() }
            }
        }
        // Show plan picker if user hasn't set their plan yet
        if userPlan.isEmpty {
            showPlanPicker = true
        }
        startPolling()
    }

    func disconnect() {
        credentials = nil
        isConnected = false
        rateLimitData = nil
        lastUpdated = nil
        lastUpdatedFormatted = "never"
        errorMessage = nil
        consecutiveFailures = 0
        isFetching = false
        CredentialStore.delete()
        timer?.invalidate()
        timer = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    

    func refresh() {
        Task { await fetchRateLimits() }
    }

    func startPolling() {
        refresh()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        // Apply backoff: on failures, increase interval up to maxBackoffInterval
        let effectiveInterval = consecutiveFailures > 0
            ? min(refreshInterval * pow(2.0, Double(consecutiveFailures - 1)), maxBackoffInterval)
            : refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    

    private func ensureFreshToken() async throws {
        guard var creds = credentials else { return }

        let needsRefresh = creds.isExpired || callsWithCurrentToken >= maxCallsPerToken

        if needsRefresh {
            creds = try await OAuthManager.refresh(creds)
            credentials = creds
            CredentialStore.save(creds)
            callsWithCurrentToken = 0
        }
    }

    

    private func fetchRateLimits() async {
        guard !isFetching else { return }
        guard var creds = credentials else { return }
        isFetching = true
        defer { isFetching = false }

        // Fix #1: Capture the session token so we can detect sign-out mid-fetch
        let sessionToken = creds.accessToken

        isLoading = rateLimitData == nil

        do {
            try await ensureFreshToken()
            guard let freshCreds = credentials else { isLoading = false; return }
            creds = freshCreds
        } catch {
            errorMessage = "Session expired — please sign in again"
            isConnected = false
            isLoading = false
            timer?.invalidate(); timer = nil  // Fix #6: Stop polling on permanent auth failure
            return
        }

        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(OAuthConfig.betaHeader, forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)

            // Fix #1: If user signed out while we were awaiting, discard results
            guard credentials?.accessToken == sessionToken || credentials != nil else {
                isLoading = false
                return
            }

            guard let http = response as? HTTPURLResponse else {
                handleFetchFailure("Invalid response")
                isLoading = false
                return
            }

            callsWithCurrentToken += 1

            switch http.statusCode {
            case 200:
                if let parsed = parseUsageResponse(data) {
                    rateLimitData = parsed
                    errorMessage = nil
                    consecutiveFailures = 0
                    restartTimer()  // Fix #4: Restore normal polling interval after success
                    checkAndNotify(parsed)
                } else {
                    handleFetchFailure("Could not parse usage data")
                }
                lastUpdated = Date(); updateTimestamp()

            case 429:
                do {
                    let newCreds = try await OAuthManager.refresh(creds)
                    credentials = newCreds
                    CredentialStore.save(newCreds)
                    callsWithCurrentToken = 0
                    var retry = req
                    retry.setValue("Bearer \(newCreds.accessToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResp) = try await URLSession.shared.data(for: retry)
                    if let retryHTTP = retryResp as? HTTPURLResponse, retryHTTP.statusCode == 200,
                       let parsed = parseUsageResponse(retryData) {
                        rateLimitData = parsed
                        errorMessage = nil
                        consecutiveFailures = 0
                        restartTimer()  // Fix #4
                        callsWithCurrentToken = 1
                    } else {
                        handleFetchFailure("Rate limited — will retry shortly")
                    }
                    lastUpdated = Date(); updateTimestamp()
                } catch {
                    handleFetchFailure("Rate limited — will retry shortly")
                }

            case 401:
                do {
                    let newCreds = try await OAuthManager.refresh(creds)
                    credentials = newCreds
                    CredentialStore.save(newCreds)
                    callsWithCurrentToken = 0
                    var retry = req
                    retry.setValue("Bearer \(newCreds.accessToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResp) = try await URLSession.shared.data(for: retry)
                    if let retryHTTP = retryResp as? HTTPURLResponse, retryHTTP.statusCode == 200,
                       let parsed = parseUsageResponse(retryData) {
                        rateLimitData = parsed
                        errorMessage = nil
                        consecutiveFailures = 0
                        restartTimer()  // Fix #4
                        callsWithCurrentToken = 1
                        lastUpdated = Date(); updateTimestamp()
                    } else {
                        errorMessage = "Session expired — please sign in again"
                        isConnected = false
                        timer?.invalidate(); timer = nil  // Fix #6
                    }
                } catch {
                    errorMessage = "Session expired — please sign in again"
                    isConnected = false
                    timer?.invalidate(); timer = nil  // Fix #6
                }

            default:
                handleFetchFailure("Server error (HTTP \(http.statusCode))")
            }

        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                handleFetchFailure("No internet connection")
            case .timedOut:
                handleFetchFailure("Request timed out")
            case .cannotFindHost, .cannotConnectToHost:
                handleFetchFailure("Cannot reach Anthropic servers")
            default:
                handleFetchFailure("Network error")
            }
        } catch {
            handleFetchFailure("Unexpected error")
        }

        isLoading = false
    }

    // Fix #3: Correct backoff progression (1x → 2x → 4x → 8x)
    private func handleFetchFailure(_ message: String) {
        consecutiveFailures += 1
        if rateLimitData == nil {
            errorMessage = message
        }
        if consecutiveFailures >= 1 {
            restartTimer()
        }
    }

    

    private func checkAndNotify(_ data: RateLimitData) {
        let v5 = data.fiveHourUtilization
        let v7 = data.sevenDayUtilization
        let resetStr = data.fiveHourResetFormatted

        if (v5 >= 0.95 || v7 >= 0.95) && !notifiedCritical {
            notifiedCritical = true
            let which = v5 >= 0.95 ? "5-hour" : "7-day"
            sendNotification(
                title: "Claude Limit Critical",
                body: "Your \(which) usage is at \(Int(max(v5, v7) * 100))%. You may be rate-limited soon.",
                sound: true
            )
        }

        if v5 >= 0.80 && !notified5hHard {
            notified5hHard = true
            sendNotification(
                title: "5-Hour Limit at \(Int(v5 * 100))%",
                body: "Resets \(resetStr). Consider pacing your usage.",
                sound: true
            )
        }

        if v5 >= 0.50 && !notified5hSoft {
            notified5hSoft = true
            sendNotification(
                title: "Halfway through 5-hour limit",
                body: "\(Int(v5 * 100))% used. Resets \(resetStr).",
                sound: false
            )
        }

        if v7 >= 0.75 && !notified7dHard {
            notified7dHard = true
            sendNotification(
                title: "Weekly Limit at \(Int(v7 * 100))%",
                body: "7-day usage is getting high. Resets \(data.sevenDayResetFormatted).",
                sound: true
            )
        }

        // Detect 5h window reset (usage dropped significantly = window rolled over)
        if previous5hUtilization >= 0.50 && v5 < 0.10 {
            sendNotification(
                title: "5-hour limit reset",
                body: "Your session window just reset. You're good to go.",
                sound: true
            )
        }
        previous5hUtilization = v5

        // Reset flags when usage drops (hysteresis to prevent notification spam)
        if v5 < 0.40 { notified5hSoft = false; notified5hHard = false }
        if v7 < 0.65 { notified7dHard = false }
        if max(v5, v7) < 0.85 { notifiedCritical = false }
    }

    private func sendNotification(title: String, body: String, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - 🔧 DEBUG METHODS (remove with: "remove debug button")

    func simulateUsage(fiveHour: Double, sevenDay: Double) {
        var d = rateLimitData ?? RateLimitData()
        d.fiveHourUtilization = min(1.0, max(0, fiveHour))
        d.sevenDayUtilization = min(1.0, max(0, sevenDay))
        d.fiveHourReset = Date().addingTimeInterval(3600 * 2)
        d.sevenDayReset = Date().addingTimeInterval(3600 * 24 * 3)
        d.status = (fiveHour >= 1.0 || sevenDay >= 1.0) ? "limited" : "allowed"
        rateLimitData = d
        lastUpdated = Date()
        updateTimestamp()
        checkAndNotify(d)
    }

    func debugNotification(level: String) {
        switch level {
        case "soft":
            sendNotification(title: "[TEST] Halfway through 5-hour limit",
                           body: "50% used. Resets in 2h 30m.", sound: false)
        case "hard":
            sendNotification(title: "[TEST] 5-Hour Limit at 80%",
                           body: "Resets in 1h 45m. Consider pacing your usage.", sound: true)
        case "critical":
            sendNotification(title: "[TEST] Claude Limit Critical",
                           body: "Your 5-hour usage is at 95%. You may be rate-limited soon.", sound: true)
        default: break
        }
    }

    func debugShowUpdate() {
        updateAvailable = "1.1.0"
        updateURL = URL(string: "https://github.com/tanishmittal/Quota/releases")
    }

    func debugShowError() {
        rateLimitData = nil
        errorMessage = "Simulated error — tap Retry or Reset to Real"
    }
    // Update checker — hits GitHub releases API on launch
    private static let githubRepo = "tanishmittal/Quota"

    func checkForUpdate() async {
        guard !hasCheckedUpdate else { return }
        hasCheckedUpdate = true

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

        guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            if isNewerVersion(latestVersion, than: currentVersion) {
                var dmgURL: URL?
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                           let urlStr = asset["browser_download_url"] as? String {
                            dmgURL = URL(string: urlStr)
                            break
                        }
                    }
                }
                if dmgURL == nil, let htmlURL = json["html_url"] as? String {
                    dmgURL = URL(string: htmlURL)
                }

                updateAvailable = latestVersion
                updateURL = dmgURL
            }
        } catch {
            // Silently fail — update check is non-critical
        }
    }

    @Published var updateProgress: String?
    private var isUpdating = false

    private static nonisolated let updateMountPoint = "/tmp/quota-update-mount"

    // Called on launch to clean up any orphaned mount from a crash
    private func cleanupOrphanedMount() {
        Task.detached {
            let mp = RateLimitService.updateMountPoint
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: mp, isDirectory: &isDir), isDir.boolValue {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                p.arguments = ["detach", mp, "-quiet", "-force"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
        }
    }

    func performUpdate() {
        // Fix #2: Check-and-set on MainActor (this method is @MainActor via class)
        guard let url = updateURL, !isUpdating else { return }
        isUpdating = true
        updateProgress = "Downloading..."

        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let dmgPath = fm.temporaryDirectory.appendingPathComponent("Quota-update.dmg")
            let mountPoint = RateLimitService.updateMountPoint
            let scriptPath = fm.temporaryDirectory.appendingPathComponent("quota-update.sh")
            let currentAppPath = Bundle.main.bundlePath

            // Fix #8: Only allow updates when running from /Applications
            guard currentAppPath.hasPrefix("/Applications") else {
                await self?.updateFailed("Move Quota to /Applications first")
                return
            }

            // Fix #4: Detach any orphaned mount from a previous crash
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet", "-force"]
            detach.standardOutput = FileHandle.nullDevice
            detach.standardError = FileHandle.nullDevice
            try? detach.run()
            detach.waitUntilExit()

            try? fm.removeItem(at: dmgPath)
            try? fm.removeItem(at: scriptPath)

            // Fix #1: defer ensures isUpdating resets on any exit path
            defer {
                Task { @MainActor in
                    self?.isUpdating = false
                }
            }

            do {
                // Download
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    await self?.updateFailed("Download failed")
                    return
                }

                // Fix #5: Verify download size matches Content-Length
                let expectedSize = http.expectedContentLength
                if expectedSize > 0 {
                    let actualSize = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
                    if actualSize < expectedSize {
                        await self?.updateFailed("Download incomplete — try again")
                        return
                    }
                }

                try? fm.removeItem(at: dmgPath)
                try fm.moveItem(at: tempURL, to: dmgPath)
                await MainActor.run { [self] in self?.updateProgress = "Verifying..." }

                // Mount
                let mountOK = await self?.runProcessAsync(
                    "/usr/bin/hdiutil",
                    args: ["attach", dmgPath.path, "-nobrowse", "-quiet", "-mountpoint", mountPoint]
                ) ?? false

                guard mountOK else {
                    await self?.updateFailed("Package corrupted")
                    try? fm.removeItem(at: dmgPath)
                    return
                }

                // Find .app — Fix #3: validate the name is safe
                let contents = (try? fm.contentsOfDirectory(atPath: mountPoint)) ?? []
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }),
                      !appName.contains("\""), !appName.contains("'"), !appName.contains(";"),
                      !appName.contains("`"), !appName.contains("$") else {
                    await self?.runProcessAsync("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet"])
                    try? fm.removeItem(at: dmgPath)
                    await self?.updateFailed("Invalid update package")
                    return
                }

                await MainActor.run { [self] in self?.updateProgress = "Installing..." }

                // Pre-escape all paths for safe shell interpolation
                let escApp = shellEscape(currentAppPath)
                let escSrc = shellEscape(mountPoint + "/" + appName)
                let escMount = shellEscape(mountPoint)
                let escDmg = shellEscape(dmgPath.path)
                let escScript = shellEscape(scriptPath.path)

                let script = """
                #!/bin/bash
                for i in $(seq 1 150); do
                    pgrep -f "Quota.app/Contents/MacOS" >/dev/null 2>&1 || break
                    sleep 0.2
                done
                rm -rf \(escApp)
                if cp -R \(escSrc) \(escApp); then
                    hdiutil detach \(escMount) -quiet 2>/dev/null
                    rm -f \(escDmg)
                    rm -f \(escScript)
                    open \(escApp)
                else
                    hdiutil detach \(escMount) -quiet 2>/dev/null
                    rm -f \(escDmg)
                    rm -f \(escScript)
                    osascript -e 'display notification "Update failed" with title "Quota"'
                fi
                """

                try script.write(to: scriptPath, atomically: true, encoding: .utf8)
                _ = await self?.runProcessAsync("/bin/chmod", args: ["+x", scriptPath.path])

                await MainActor.run { [self] in self?.updateProgress = "Restarting..." }

                let launcher = Process()
                launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
                launcher.arguments = [scriptPath.path]
                launcher.standardOutput = FileHandle.nullDevice
                launcher.standardError = FileHandle.nullDevice
                try launcher.run()

                try? await Task.sleep(for: .seconds(0.5))
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }

            } catch {
                await self?.updateFailed("Update failed")
                try? fm.removeItem(at: dmgPath)
                _ = await self?.runProcessAsync("/usr/bin/hdiutil", args: ["detach", mountPoint, "-quiet", "-force"])
            }
        }
    }

    // Fix #7: Non-blocking process execution using terminationHandler
    @discardableResult
    private func runProcessAsync(_ path: String, args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus == 0)
            }
            do {
                try proc.run()
            } catch {
                cont.resume(returning: false)
            }
        }
    }

    private func updateFailed(_ msg: String) async {
        await MainActor.run { self.updateProgress = msg }
        try? await Task.sleep(for: .seconds(3))
        await MainActor.run {
            self.updateProgress = nil
            self.isUpdating = false
        }
    }

    func dismissUpdate() {
        updateAvailable = nil
        updateURL = nil
        updateProgress = nil
        isUpdating = false
    }

    private func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let c = candidate.split(separator: ".").compactMap { Int($0) }
        let v = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(c.count, v.count) {
            let cv = i < c.count ? c[i] : 0
            let vv = i < v.count ? v[i] : 0
            if cv > vv { return true }
            if cv < vv { return false }
        }
        return false
    }

    

    private func parseUsageResponse(_ data: Data) -> RateLimitData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var d = RateLimitData()

        // Plan tier — try direct field first
        for key in ["plan_tier", "tier", "plan"] {
            if let tier = json[key] as? String { d.planTier = tier; break }
        }

        if let fh = json["five_hour"] as? [String: Any] {
            d.fiveHourUtilization = normalizeUtilization(fh["utilization"])
            if let reset = fh["resets_at"] as? String {
                d.fiveHourReset = parseISO8601(reset) ?? Date()
            }
        }

        if let sd = json["seven_day"] as? [String: Any] {
            d.sevenDayUtilization = normalizeUtilization(sd["utilization"])
            if let reset = sd["resets_at"] as? String {
                d.sevenDayReset = parseISO8601(reset) ?? Date()
            }
        }

        // Per-model 7-day breakdowns
        if let sonnet = json["seven_day_sonnet"] as? [String: Any] {
            d.sonnetUtilization = normalizeUtilization(sonnet["utilization"])
        }
        if let opus = json["seven_day_opus"] as? [String: Any] {
            d.opusUtilization = normalizeUtilization(opus["utilization"])
        }

        // Extra usage (overage billing)
        if let extra = json["extra_usage"] as? [String: Any] {
            d.extraUsageEnabled = extra["is_enabled"] as? Bool ?? false
            if let used = extra["used_credits"] as? Double { d.extraUsageCreditsUsed = used }
        }

        // Infer plan tier from available data if not explicitly provided
        // Opus field being present (even if null) suggests Max plan
        // Extra usage being enabled suggests Max plan
        if d.planTier == nil {
            if d.extraUsageEnabled {
                d.planTier = "max"
            } else if json["seven_day_opus"] != nil && !(json["seven_day_opus"] is NSNull) {
                d.planTier = "max"
            }
            // Otherwise we can't tell — leave nil
        }

        d.status = (d.fiveHourUtilization >= 1.0 || d.sevenDayUtilization >= 1.0) ? "limited" : "allowed"

        return d
    }

    // Handle both 0-100 (percentage) and 0-1 (fraction) formats, plus Int types
    private func normalizeUtilization(_ value: Any?) -> Double {
        let raw: Double
        if let d = value as? Double { raw = d }
        else if let i = value as? Int { raw = Double(i) }
        else { return 0 }
        // If > 1, assume it's a percentage (0-100). Otherwise it's already 0-1.
        let normalized = raw > 1.0 ? raw / 100.0 : raw
        return min(1.0, max(0, normalized))
    }

    private func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
