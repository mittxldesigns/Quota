import Foundation

// Stores usage snapshots over time and builds predictive models from them.
// All data stays in ~/Library/Application Support/Quota/history.json
// The file grows ~1KB/day (one entry per poll, deduplicated to hourly).

struct UsageSnapshot: Codable {
    let timestamp: Date
    let fiveHour: Double      // 0-1
    let sevenDay: Double      // 0-1
    let isPeak: Bool
    let weekday: Int           // 1=Sun, 7=Sat
    let hour: Int              // 0-23 in user's local time
}

struct UsagePrediction {
    let willHitLimit: Bool
    let estimatedTimeToLimit: TimeInterval?  // seconds
    let peakDayOfWeek: Int?    // which day you tend to use most
    let peakHourOfDay: Int?    // which hour you tend to use most
    let avgDailyBurn: Double   // average % consumed per day (5h window)
    let formatted: String      // human-readable summary
}

class UsageHistory {
    private var snapshots: [UsageSnapshot] = []
    private let maxSnapshots = 2016  // ~2 weeks at 1 per 10min
    private let historyFile: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Quota", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        historyFile = dir.appendingPathComponent("history.json")
        load()
        purgeCorruptedData()

        // Clean up debug file from previous versions
        let debugFile = dir.appendingPathComponent("last_api_response.json")
        try? FileManager.default.removeItem(at: debugFile)
    }

    /// Remove snapshots with bogus values from the v1.0.0 utilization parsing bug
    /// (API returns 0-100 scale but old code treated values <= 1.0 as fractions)
    private func purgeCorruptedData() {
        let before = snapshots.count
        // Any snapshot where fiveHour or sevenDay is exactly 1.0 is suspicious
        // (would mean 100% usage which should be rare), OR values > 1.0 which
        // were previously possible with the old fractional interpretation.
        // Only purge obvious outliers: values that jumped to 1.0 from low usage
        snapshots.removeAll { snap in
            snap.fiveHour > 1.0 || snap.sevenDay > 1.0
        }
        if snapshots.count < before { save() }
    }

    // Record a new data point (called on every successful poll)
    func record(fiveHour: Double, sevenDay: Double) {
        let cal = Calendar.current
        let now = Date()

        // Deduplicate: skip if we already have a snapshot within the last 5 minutes
        if let last = snapshots.last, now.timeIntervalSince(last.timestamp) < 300 {
            return
        }

        let isPeak = ClaudePeakStatus.current == .peak

        let snap = UsageSnapshot(
            timestamp: now,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            isPeak: isPeak,
            weekday: cal.component(.weekday, from: now),
            hour: cal.component(.hour, from: now)
        )
        snapshots.append(snap)

        // Trim to max size
        if snapshots.count > maxSnapshots {
            snapshots = Array(snapshots.suffix(maxSnapshots))
        }

        save()
    }

    // How many days of data we have
    var daysOfData: Int {
        guard let first = snapshots.first else { return 0 }
        return max(1, Int(Date().timeIntervalSince(first.timestamp) / 86400))
    }

    // Predict usage patterns from history
    func predict() -> UsagePrediction? {
        guard snapshots.count >= 12 else { return nil }  // Need at least ~2 hours of data

        // Calculate average burn rate per hour (how fast 5h window fills)
        var hourlyRates: [Double] = []
        for i in 1..<snapshots.count {
            let prev = snapshots[i - 1]
            let curr = snapshots[i]
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0, dt < 3600 else { continue }  // Skip gaps > 1hr

            let delta = curr.fiveHour - prev.fiveHour
            if delta > 0 {  // Only count increases (resets cause drops)
                let ratePerHour = delta / (dt / 3600)
                hourlyRates.append(ratePerHour)
            }
        }

        let avgRate = hourlyRates.isEmpty ? 0 : hourlyRates.reduce(0, +) / Double(hourlyRates.count)

        // Weighted moving average — recent data matters more
        var weightedRate: Double = 0
        var totalWeight: Double = 0
        let recentCount = min(hourlyRates.count, 20)
        for i in (hourlyRates.count - recentCount)..<hourlyRates.count {
            let age = Double(hourlyRates.count - i)
            let weight = 1.0 / age  // More recent = higher weight
            weightedRate += hourlyRates[i] * weight
            totalWeight += weight
        }
        let smoothedRate = totalWeight > 0 ? weightedRate / totalWeight : avgRate

        // Find your heaviest usage day and hour
        var dayBuckets = [Int: Int]()  // weekday -> count of high-usage snapshots
        var hourBuckets = [Int: Int]()
        for snap in snapshots where snap.fiveHour > 0.3 {
            dayBuckets[snap.weekday, default: 0] += 1
            hourBuckets[snap.hour, default: 0] += 1
        }
        let peakDay = dayBuckets.max(by: { $0.value < $1.value })?.key
        let peakHour = hourBuckets.max(by: { $0.value < $1.value })?.key

        // Estimate time to limit from current usage
        let current5h = snapshots.last?.fiveHour ?? 0
        let remaining = 1.0 - current5h
        var timeToLimit: TimeInterval? = nil
        var willHit = false
        if smoothedRate > 0.001 && current5h > 0.05 {
            let hoursLeft = remaining / smoothedRate
            timeToLimit = hoursLeft * 3600
            willHit = hoursLeft < 3  // Will hit within 3 hours
        }

        // Average daily burn (how much of the 5h window you use per day)
        let dailySnapsByDay = Dictionary(grouping: snapshots) { snap in
            Calendar.current.startOfDay(for: snap.timestamp)
        }
        var dailyPeaks: [Double] = []
        for (_, daySnaps) in dailySnapsByDay {
            let maxUsage = daySnaps.map(\.fiveHour).max() ?? 0
            dailyPeaks.append(maxUsage)
        }
        let avgDaily = dailyPeaks.isEmpty ? 0 : dailyPeaks.reduce(0, +) / Double(dailyPeaks.count)

        // Build summary
        var parts: [String] = []
        if daysOfData >= 3 {
            parts.append("Avg daily peak: \(Int(avgDaily * 100))%")
        }
        if let ttl = timeToLimit, willHit {
            let h = Int(ttl / 3600)
            let m = Int(ttl.truncatingRemainder(dividingBy: 3600) / 60)
            if h > 0 {
                parts.append("Hitting limit in ~\(h)h \(m)m")
            } else {
                parts.append("Hitting limit in ~\(m)m")
            }
        }
        if let ph = peakHour, daysOfData >= 2 {
            let ampm = ph >= 12 ? "\(ph == 12 ? 12 : ph - 12)PM" : "\(ph == 0 ? 12 : ph)AM"
            parts.append("Heaviest around \(ampm)")
        }

        let formatted = parts.isEmpty ? "Learning your patterns..." : parts.joined(separator: " · ")

        return UsagePrediction(
            willHitLimit: willHit,
            estimatedTimeToLimit: timeToLimit,
            peakDayOfWeek: peakDay,
            peakHourOfDay: peakHour,
            avgDailyBurn: avgDaily,
            formatted: formatted
        )
    }

    // Persistence
    private func save() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        let tmp = historyFile.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.removeItem(at: historyFile)
        try? FileManager.default.moveItem(at: tmp, to: historyFile)
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyFile),
              let decoded = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else { return }
        snapshots = decoded
    }

    func clear() {
        snapshots.removeAll()
        try? FileManager.default.removeItem(at: historyFile)
    }
}
