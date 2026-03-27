import SwiftUI
import AppKit
import ServiceManagement

@main
struct QuotaApp: App {
    @StateObject private var service = RateLimitService()
    @AppStorage("iconStyle") private var iconStyle = "ringAndNumber"  // ringAndNumber, ringOnly, numberOnly

    init() {
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
