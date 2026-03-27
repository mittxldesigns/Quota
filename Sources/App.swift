import SwiftUI
import AppKit
import ServiceManagement

@main
struct QuotaApp: App {
    @StateObject private var service = RateLimitService()

    init() {
        // First launch: enable login item by default
        if !UserDefaults.standard.bool(forKey: "didInitialSetup") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didInitialSetup")
            UserDefaults.standard.set(true, forKey: "launchAtLogin")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(service: service)
                .frame(width: 340)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: miniGauge(
                    value: service.menuBarValue,
                    color: NSColor(service.statusColor)
                ))
                Text(service.menuBarLabel)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }

    // Tiny circular arc for the menu bar. Draws a track + colored fill.
    private func miniGauge(value: Double, color: NSColor) -> NSImage {
        let size: CGFloat = 18
        let lw: CGFloat = 2.2
        let inset = lw / 2 + 1
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let center = NSPoint(x: size / 2, y: size / 2)
        let r = (size / 2) - inset

        let img = NSImage(size: rect.size, flipped: true) { _ in
            // Track
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = lw
            NSColor.white.withAlphaComponent(0.15).setStroke()
            track.stroke()

            // Fill
            if value > 0.005 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: r,
                             startAngle: 90, endAngle: 90 - (360 * value), clockwise: true)
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
