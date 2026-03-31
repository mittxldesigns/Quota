import Foundation

// Tracks real-time token consumption by reading Claude Code's local data:
// 1. Session-meta summaries: ~/.claude/usage-data/session-meta/*.json (historical)
// 2. Live JSONL conversation logs: ~/.claude/projects/*/SESSION_ID.jsonl (real-time)
// 3. Active sessions: ~/.claude/sessions/*.json (which sessions are running now)

struct TokenStats {
    var todayInput: Int = 0
    var todayOutput: Int = 0
    var weekInput: Int = 0
    var weekOutput: Int = 0
    var monthInput: Int = 0
    var monthOutput: Int = 0
    var allTimeInput: Int = 0
    var allTimeOutput: Int = 0
    var sessionCount: Int = 0
    var activeSessions: Int = 0
    var liveInput: Int = 0
    var liveOutput: Int = 0

    // Per-model token tracking for cost calculation (all-time)
    var sonnetInput: Int = 0
    var sonnetOutput: Int = 0
    var opusInput: Int = 0
    var opusOutput: Int = 0
    var haikuInput: Int = 0
    var haikuOutput: Int = 0

    // Per-model this month (for plan comparison)
    var monthSonnetIn: Int = 0
    var monthSonnetOut: Int = 0
    var monthOpusIn: Int = 0
    var monthOpusOut: Int = 0
    var monthHaikuIn: Int = 0
    var monthHaikuOut: Int = 0

    // Cache token tracking (detects the March 2026 caching bug)
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0

    // Cache health: ratio of cache_creation to input tokens
    // Normal: < 5x. Buggy: > 20x (tokens being re-billed every turn)
    var cacheRatio: Double {
        guard allTimeInput > 0 else { return 0 }
        return Double(cacheCreationTokens) / Double(allTimeInput)
    }
    var isCacheBroken: Bool { cacheRatio > 20 }

    // Estimated wasted cost from cache bug (cache creation at 25% of input pricing)
    var cacheBugWastedCost: Double {
        guard isCacheBroken else { return 0 }
        // Cache creation costs 25% of input price. Opus: $15 input -> $3.75 cache create
        // Normal cache creation should be ~1x input tokens. Anything over is waste.
        let normalCacheCreate = allTimeInput  // what it should be
        let excess = max(0, cacheCreationTokens - normalCacheCreate)
        return Double(excess) * 3.75 / 1_000_000  // Opus cache creation pricing
    }

    var todayTotal: Int { todayInput + todayOutput }
    var weekTotal: Int { weekInput + weekOutput }
    var monthTotal: Int { monthInput + monthOutput }
    var allTimeTotal: Int { allTimeInput + allTimeOutput }
    var liveTotal: Int { liveInput + liveOutput }

    // All-time API cost
    var apiCost: Double {
        tokenCost(sIn: sonnetInput, sOut: sonnetOutput,
                  oIn: opusInput, oOut: opusOutput,
                  hIn: haikuInput, hOut: haikuOutput,
                  totalIn: allTimeInput, totalOut: allTimeOutput)
    }

    // This month's API cost (for plan comparison)
    var monthApiCost: Double {
        tokenCost(sIn: monthSonnetIn, sOut: monthSonnetOut,
                  oIn: monthOpusIn, oOut: monthOpusOut,
                  hIn: monthHaikuIn, hOut: monthHaikuOut,
                  totalIn: monthInput, totalOut: monthOutput)
    }

    // Pricing: Sonnet $3/$15, Opus $15/$75, Haiku $0.25/$1.25 per 1M tokens
    private func tokenCost(sIn: Int, sOut: Int, oIn: Int, oOut: Int,
                           hIn: Int, hOut: Int, totalIn: Int, totalOut: Int) -> Double {
        let sonnet = (Double(sIn) * 3.0 + Double(sOut) * 15.0) / 1_000_000.0
        let opus = (Double(oIn) * 15.0 + Double(oOut) * 75.0) / 1_000_000.0
        let haiku = (Double(hIn) * 0.25 + Double(hOut) * 1.25) / 1_000_000.0
        let unknownIn = max(0, totalIn - sIn - oIn - hIn)
        let unknownOut = max(0, totalOut - sOut - oOut - hOut)
        let unknown = (Double(unknownIn) * 3.0 + Double(unknownOut) * 15.0) / 1_000_000.0
        return sonnet + opus + haiku + unknown
    }

    // What the user pays per month for their plan
    static func planCost(_ plan: String) -> Double {
        switch plan.lowercased() {
        case "pro": return 20
        case "max_5", "max5": return 100
        case "max_20", "max20": return 200
        case "team": return 30
        default: return 20
        }
    }

    static func formatCost(_ cost: Double) -> String {
        if cost >= 1000 { return String(format: "$%.0f", cost) }
        if cost >= 100 { return String(format: "$%.0f", cost) }
        if cost >= 10 { return String(format: "$%.1f", cost) }
        return String(format: "$%.2f", cost)
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return m >= 10 ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        } else if count >= 1_000 {
            let k = Double(count) / 1_000.0
            return k >= 10 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
        }
        return "\(count)"
    }
}

class TokenTracker {
    static let shared = TokenTracker()
    private let home: URL
    private let sessionMetaDir: URL
    private let sessionsDir: URL
    private let projectsDir: URL

    init() {
        home = FileManager.default.homeDirectoryForCurrentUser
        sessionMetaDir = home.appendingPathComponent(".claude/usage-data/session-meta", isDirectory: true)
        sessionsDir = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func refresh() -> TokenStats? {
        var stats = TokenStats()

        // 1. Read ALL JSONL files from all projects (complete history + live)
        readAllJSONL(&stats)

        // 2. Tag active sessions
        countActiveSessions(&stats)

        return stats.allTimeTotal > 0 ? stats : nil
    }

    // Read ALL JSONL files from ~/.claude/projects/ (including subagents)
    // This captures complete token history with model info for cost calculation
    private func readAllJSONL(_ stats: inout TokenStats) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else { return }

        // Find all .jsonl files recursively
        guard let enumerator = fm.enumerator(at: projectsDir, includingPropertiesForKeys: [.fileSizeKey],
                                              options: [.skipsHiddenFiles]) else { return }

        // Get active session IDs for "live" tracking
        let activeSessionIds = getActiveSessionIds()

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        var seenSessions = Set<String>()

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            let sessionId = fileURL.deletingPathExtension().lastPathComponent
            // Skip if we already processed this session (can appear in subagents too)
            // But DO process subagent files — they have separate token counts
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let isLive = activeSessionIds.contains(sessionId)
            if !seenSessions.contains(sessionId) {
                seenSessions.insert(sessionId)
                stats.sessionCount += 1
            }

            // Get file modification date for time bucketing
            let fileDate = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? now

            for line in content.components(separatedBy: "\n") where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                let msg = obj["message"] as? [String: Any]
                let model = (msg?["model"] as? String) ?? ""
                let usage = (msg?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])

                guard let u = usage else { continue }
                let inp = (u["input_tokens"] as? Int) ?? 0
                let out = (u["output_tokens"] as? Int) ?? 0
                let cacheCreate = (u["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheRead = (u["cache_read_input_tokens"] as? Int) ?? 0

                stats.allTimeInput += inp
                stats.allTimeOutput += out
                stats.cacheCreationTokens += cacheCreate
                stats.cacheReadTokens += cacheRead

                // Time bucketing based on file mod date
                if fileDate >= startOfToday {
                    stats.todayInput += inp
                    stats.todayOutput += out
                }
                if fileDate >= startOfWeek {
                    stats.weekInput += inp
                    stats.weekOutput += out
                }
                if fileDate >= startOfMonth {
                    stats.monthInput += inp
                    stats.monthOutput += out
                }

                // Live session tracking
                if isLive {
                    stats.liveInput += inp
                    stats.liveOutput += out
                }

                // Model bucketing for cost (all-time + monthly)
                let m = model.lowercased()
                let isThisMonth = fileDate >= startOfMonth
                if m.contains("opus") {
                    stats.opusInput += inp
                    stats.opusOutput += out
                    if isThisMonth { stats.monthOpusIn += inp; stats.monthOpusOut += out }
                } else if m.contains("haiku") {
                    stats.haikuInput += inp
                    stats.haikuOutput += out
                    if isThisMonth { stats.monthHaikuIn += inp; stats.monthHaikuOut += out }
                } else {
                    stats.sonnetInput += inp
                    stats.sonnetOutput += out
                    if isThisMonth { stats.monthSonnetIn += inp; stats.monthSonnetOut += out }
                }
            }
        }
    }

    // Get session IDs of currently running Claude Code processes
    private func getActiveSessionIds() -> Set<String> {
        let fm = FileManager.default
        var ids = Set<String>()
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else { return ids }

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sid = json["sessionId"] as? String,
                  kill(Int32(pid), 0) == 0 else { continue }
            ids.insert(sid)
        }
        return ids
    }

    // Count active sessions
    private func countActiveSessions(_ stats: inout TokenStats) {
        stats.activeSessions = getActiveSessionIds().count
    }
}
