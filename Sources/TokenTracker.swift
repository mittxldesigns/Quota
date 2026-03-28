import Foundation

// Reads Claude Code's local session data to track actual token consumption.
// Data lives at ~/.claude/usage-data/session-meta/*.json
// Each file has: input_tokens, output_tokens, start_time, duration_minutes

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

    var todayTotal: Int { todayInput + todayOutput }
    var weekTotal: Int { weekInput + weekOutput }
    var monthTotal: Int { monthInput + monthOutput }
    var allTimeTotal: Int { allTimeInput + allTimeOutput }

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
    private let sessionMetaDir: URL

    init() {
        sessionMetaDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usage-data/session-meta", isDirectory: true)
    }

    func refresh() -> TokenStats? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionMetaDir.path) else { return nil }

        guard let files = try? fm.contentsOfDirectory(at: sessionMetaDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else { return nil }

        if files.isEmpty { return nil }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        var stats = TokenStats()

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let input = (json["input_tokens"] as? Int) ?? 0
            let output = (json["output_tokens"] as? Int) ?? 0
            let timeStr = json["start_time"] as? String ?? ""
            let sessionDate = iso.date(from: timeStr) ?? isoBasic.date(from: timeStr)

            stats.allTimeInput += input
            stats.allTimeOutput += output
            stats.sessionCount += 1

            guard let date = sessionDate else { continue }

            if date >= startOfMonth {
                stats.monthInput += input
                stats.monthOutput += output
            }
            if date >= startOfWeek {
                stats.weekInput += input
                stats.weekOutput += output
            }
            if date >= startOfToday {
                stats.todayInput += input
                stats.todayOutput += output
            }
        }

        return stats
    }
}
