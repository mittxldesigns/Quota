import Foundation

// Checks the user's Claude Code installation for known issues
// and provides actionable advice.

enum ClaudeCodeHealth {

    struct Alert {
        let icon: String        // SF Symbol
        let title: String
        let message: String
        let severity: Severity  // affects color
        let action: Action?

        enum Severity { case info, warning, critical }
        enum Action {
            case updateClaudeCode
            case openURL(URL)
        }
    }

    /// Checks Claude Code version and known issues. Returns an alert if action needed.
    static func check() -> Alert? {
        let version = getClaudeCodeVersion()

        // Check for autocompact bug (fixed in 2.1.89)
        if let v = version, compareSemver(v, isOlderThan: "2.1.89") {
            return Alert(
                icon: "exclamationmark.triangle.fill",
                title: "Claude Code \(v) has a token drain bug",
                message: "Update to v2.1.89+ to fix the autocompact loop that wastes 10-20x tokens. Run: claude update",
                severity: .critical,
                action: .updateClaudeCode
            )
        }

        // Check for April 2026 third-party OAuth restriction
        // Our app only reads /api/oauth/usage (not inference), but warn if we start getting blocked
        if UserDefaults.standard.bool(forKey: "oauthBlocked") {
            return Alert(
                icon: "lock.shield.fill",
                title: "OAuth access may be restricted",
                message: "Anthropic is limiting third-party OAuth. Quota only reads usage data, but if you're getting errors, this may be why.",
                severity: .warning,
                action: .openURL(URL(string: "https://github.com/mittxldesigns/Quota/issues")!)
            )
        }

        return nil
    }

    /// Get Claude Code version from the CLI
    private static func getClaudeCodeVersion() -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude", "--version"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Output is like "claude-code 2.1.89" or just "2.1.89"
            let parts = output.components(separatedBy: " ")
            return parts.last
        } catch {
            return nil
        }
    }

    /// Simple semver comparison: returns true if `version` < `than`
    private static func compareSemver(_ version: String, isOlderThan than: String) -> Bool {
        let v1 = version.split(separator: ".").compactMap { Int($0) }
        let v2 = than.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(v1.count, v2.count) {
            let a = i < v1.count ? v1[i] : 0
            let b = i < v2.count ? v2[i] : 0
            if a < b { return true }
            if a > b { return false }
        }
        return false
    }
}
