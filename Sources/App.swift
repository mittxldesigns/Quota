import SwiftUI
import AppKit
import ServiceManagement

@main
struct QuotaApp: App {
    @StateObject private var service = RateLimitService.shared
    @AppStorage("iconStyle") private var iconStyle = "ringAndNumber"  // ringAndNumber, ringOnly, numberOnly

    init() {
        if !UserDefaults.standard.bool(forKey: "didInitialSetup") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didInitialSetup")
            UserDefaults.standard.set(true, forKey: "launchAtLogin")
        }
        DispatchQueue.main.async { Self.moveToApplicationsIfNeeded() }

        // Show floating window if user had it enabled
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if UserDefaults.standard.bool(forKey: "floatingWindow") {
                FloatingWindowManager.shared.show(service: RateLimitService.shared)
            }
        }

        // Register global keyboard shortcut: ⌘+Shift+Q to toggle floating window
        DispatchQueue.main.async {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "q" {
                    FloatingWindowManager.shared.toggle(service: RateLimitService.shared)
                    return nil
                }
                return event
            }
        }
    }

    /// Checks if the app is running from outside /Applications and offers to move it there.
    private static func moveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        let appName = Bundle.main.bundleURL.lastPathComponent  // "Quota.app"

        // Already in /Applications — nothing to do
        if bundlePath.hasPrefix("/Applications") { return }

        // Don't nag on dev builds (running from build/ or Xcode)
        if bundlePath.contains("/build/") || bundlePath.contains("/DerivedData/") { return }

        let dest = "/Applications/\(appName)"

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "Quota works best from your Applications folder. Move it there now?\n\nThis also helps with macOS security — apps in /Applications are trusted more by Gatekeeper."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.icon = NSImage(named: NSImage.applicationIconName)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let fm = FileManager.default
            // Remove old copy if present
            if fm.fileExists(atPath: dest) {
                try fm.removeItem(atPath: dest)
            }
            try fm.copyItem(atPath: bundlePath, toPath: dest)

            // Remove quarantine attribute on the new copy
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            proc.arguments = ["-cr", dest]
            try? proc.run()
            proc.waitUntilExit()

            // Relaunch from /Applications
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", dest]
            try task.run()

            // Quit current instance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Couldn't move Quota"
            errAlert.informativeText = "Please drag Quota.app to your Applications folder manually.\n\nThen right-click it → Open to launch."
            errAlert.alertStyle = .warning
            errAlert.runModal()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(service: service)
                .frame(width: 340)
        } label: {
            switch iconStyle {
            case "ringOnly":
                Image(nsImage: drawRing(value: service.menuBarValue, color: NSColor(service.statusColor), size: 18))
            case "numberOnly":
                Text(service.menuBarLabel)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(service.statusColor)
            default:
                HStack(spacing: 3) {
                    Image(nsImage: drawRing(value: service.menuBarValue, color: NSColor(service.statusColor), size: 16))
                    Text(service.menuBarLabel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func drawRing(value: Double, color: NSColor, size: CGFloat) -> NSImage {
        let lw: CGFloat = 2.0
        let inset = lw / 2 + 0.5
        let center = NSPoint(x: size / 2, y: size / 2)
        let r = (size / 2) - inset

        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = lw
            NSColor.white.withAlphaComponent(0.12).setStroke()
            track.stroke()

            if value > 0.005 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: r,
                             startAngle: 90, endAngle: 90 - (360 * min(1, value)), clockwise: true)
                arc.lineWidth = lw
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
