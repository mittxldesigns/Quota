import SwiftUI
import AppKit

// Manages an always-on-top floating window that shows a compact Quota view.
// Users can toggle this from Settings. The window is draggable and stays on all spaces.

class FloatingWindowManager: ObservableObject {
    static let shared = FloatingWindowManager()
    private var window: NSWindow?
    @Published var isVisible = false

    func show(service: RateLimitService) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }

        let view = NSHostingView(rootView: FloatingMiniView(service: service, manager: self))

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 64),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.contentView = view
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.hasShadow = true

        // Position: top-right corner, below menu bar
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 190
            let y = screen.visibleFrame.maxY - 74
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.makeKeyAndOrderFront(nil)
        window = w
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    func toggle(service: RateLimitService) {
        if isVisible { hide() } else { show(service: service) }
    }
}

// Compact floating view — just ring + percentage + key stats
struct FloatingMiniView: View {
    @ObservedObject var service: RateLimitService
    @ObservedObject var manager: FloatingWindowManager

    var body: some View {
        HStack(spacing: 10) {
            // Mini ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 3)
                    .frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: CGFloat(service.menuBarValue))
                    .stroke(service.statusColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 36, height: 36)
                Text("\(Int(service.menuBarValue * 100))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 2) {
                if let data = service.rateLimitData {
                    Text("5h: \(Int(data.fiveHourUtilization * 100))%  7d: \(Int(data.sevenDayUtilization * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        // Peak badge
                        let peak = ClaudePeakStatus.current
                        HStack(spacing: 2) {
                            Image(systemName: peak.icon)
                                .font(.system(size: 7))
                            Text(peak == .peak ? "Peak" : "Off")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(peak.color)

                        if let ts = service.tokenStats, ts.liveTotal > 0 {
                            Text(TokenStats.formatTokens(ts.liveTotal))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                } else {
                    Text("Connecting...")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            // Close button
            Button {
                manager.hide()
                UserDefaults.standard.set(false, forKey: "floatingWindow")
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }
}
