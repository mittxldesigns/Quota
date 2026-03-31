import Foundation
import AppKit

// Mitigates the March 2026 Claude Code caching bug.
// Can't patch Claude's binary, but CAN:
// 1. Kill long-running sessions (context balloons → cache re-bills everything)
// 2. Clear stale session files so next launch starts fresh
// 3. Add CLAUDE.md guidance to keep sessions short
// 4. Show user what happened

enum CacheFixer {

    static func fix() {
        var actions: [String] = []

        // 1. Kill long-running Claude Code processes (> 2 hours)
        let killed = killLongSessions()
        if killed > 0 {
            actions.append("Stopped \(killed) long-running session\(killed == 1 ? "" : "s")")
        }

        // 2. Clear stale session files
        let cleared = clearStaleSessions()
        if cleared > 0 {
            actions.append("Cleared \(cleared) stale session file\(cleared == 1 ? "" : "s")")
        }

        // 3. Add cache optimization to global CLAUDE.md
        let addedGuide = addCacheGuidance()
        if addedGuide {
            actions.append("Added cache optimization to CLAUDE.md")
        }

        // Show result
        let alert = NSAlert()
        if actions.isEmpty {
            alert.messageText = "Already optimized"
            alert.informativeText = "No stale sessions found and CLAUDE.md already has cache guidance. You're good."
        } else {
            alert.messageText = "Cache fix applied"
            alert.informativeText = actions.joined(separator: "\n") + "\n\nStart new Claude Code sessions for best results. Avoid --resume for now."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // Kill Claude Code processes that have been running > 2 hours
    private static func killLongSessions() -> Int {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else { return 0 }

        var killed = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let startedAt = json["startedAt"] as? Double else { continue }

            // Check if running
            guard kill(Int32(pid), 0) == 0 else { continue }

            // Check age — kill if > 2 hours old
            let age = Date().timeIntervalSince1970 - (startedAt / 1000)
            if age > 7200 {  // 2 hours in seconds
                kill(Int32(pid), SIGTERM)
                killed += 1
            }
        }
        return killed
    }

    // Remove stale session files (process not running)
    private static func clearStaleSessions() -> Int {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else { return 0 }

        var cleared = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int else { continue }

            // If process is NOT running, the session file is stale
            if kill(Int32(pid), 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                cleared += 1
            }
        }
        return cleared
    }

    // Add cache-saving guidance to ~/.claude/CLAUDE.md
    private static func addCacheGuidance() -> Bool {
        let claudeMd = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/CLAUDE.md")

        let marker = "# Cache Optimization (added by Quota)"
        let guidance = """

        \(marker)
        - Keep sessions under 2 hours to avoid the prompt caching bug (March 2026)
        - Start fresh sessions for new tasks instead of continuing old ones
        - Avoid using --resume flag until the cache regression is patched
        - Break large refactors into smaller, focused sessions
        """

        let fm = FileManager.default
        if fm.fileExists(atPath: claudeMd.path) {
            guard let content = try? String(contentsOf: claudeMd, encoding: .utf8) else { return false }
            if content.contains(marker) { return false }  // Already added
            let updated = content + "\n" + guidance
            try? updated.write(to: claudeMd, atomically: true, encoding: .utf8)
            return true
        } else {
            try? guidance.write(to: claudeMd, atomically: true, encoding: .utf8)
            return true
        }
    }
}
