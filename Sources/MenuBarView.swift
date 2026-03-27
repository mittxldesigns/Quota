import SwiftUI
import ServiceManagement

// Colors and sizing constants

private enum Theme {
    static let ring5h    = Color(red: 1.0, green: 0.42, blue: 0.32)  // coral
    static let ring7d    = Color(red: 0.22, green: 0.78, blue: 0.88) // teal
    static let critical  = Color(red: 1.0, green: 0.27, blue: 0.22)
    static let safe      = Color(red: 0.28, green: 0.82, blue: 0.50)

    static let trackOpacity: Double = 0.08
    static let glowRadius: CGFloat = 6
    static let outerRing: CGFloat = 104
    static let innerRing: CGFloat = 76
    static let outerWidth: CGFloat = 10
    static let innerWidth: CGFloat = 8
    static let glassTint = Color.white.opacity(0.04)
}

private let appVersion: String = {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
}()



struct MenuBarPopover: View {
    @ObservedObject var service: RateLimitService
    @StateObject private var oauth = OAuthManager()
    // 🔧 DEBUG FLAG (remove with: "remove debug button")
    @State private var showDebug = false

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                if service.showPlanPicker {
                    planPickerView
                } else if !service.isConnected {
                    loginView
                } else if service.isLoading && service.rateLimitData == nil {
                    loadingView
                } else if let err = service.errorMessage, service.rateLimitData == nil {
                    errorView(err)
                } else if let data = service.rateLimitData {
                    connectedView(data)
                }

                // 🔧 DEBUG PANEL (remove with: "remove debug button")
                if showDebug {
                    Divider().padding(.horizontal, 12)
                    DebugPanel(service: service)
                }
            }
        }
    }

    // Connected state

    private func connectedView(_ data: RateLimitData) -> some View {
        VStack(spacing: 8) {
            headerRow(data)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 0)

            
            VStack(spacing: 12) {
                concentricRings(data)
                    .padding(.top, 4)

                HStack(spacing: 16) {
                    legendDot(color: ringColor(for: data.fiveHourUtilization, base: Theme.ring5h),
                              label: "5-Hour", value: data.fiveHourUtilization)
                    legendDot(color: ringColor(for: data.sevenDayUtilization, base: Theme.ring7d),
                              label: "7-Day", value: data.sevenDayUtilization)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassEffect(
                .regular.tint(Theme.glassTint),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .padding(.horizontal, 12)

            
            HStack(spacing: 8) {
                detailCard(
                    label: "5-Hour Window",
                    value: data.fiveHourUtilization,
                    reset: data.fiveHourResetFormatted,
                    isBinding: data.representativeClaim == "five_hour",
                    color: ringColor(for: data.fiveHourUtilization, base: Theme.ring5h)
                )
                detailCard(
                    label: "7-Day Window",
                    value: data.sevenDayUtilization,
                    reset: data.sevenDayResetFormatted,
                    isBinding: data.representativeClaim == "seven_day",
                    color: ringColor(for: data.sevenDayUtilization, base: Theme.ring7d)
                )
            }
            .padding(.horizontal, 12)

            peakStatusRow
                .padding(.horizontal, 12)

            // Burn rate + plan recommendation (only when relevant)
            if let burnRate = data.burnRateEstimate {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                    Text(burnRate)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(
                    .regular.tint(Color.orange.opacity(0.03)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .padding(.horizontal, 12)
            }

            if let planTip = data.planRecommendation {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                    Text(planTip)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(
                    .regular.tint(Color.yellow.opacity(0.03)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .padding(.horizontal, 12)
            }

            if let version = service.updateAvailable {
                HStack(spacing: 6) {
                    if let progress = service.updateProgress {
                        // Updating in progress
                        ProgressView().controlSize(.small)
                        Text(progress)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    } else {
                        // Update available, not started yet
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.blue)
                        Text("v\(version) available")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("Install") { service.performUpdate() }
                            .font(.system(size: 9, weight: .semibold))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .glassEffect(.regular.tint(.blue.opacity(0.3)).interactive(), in: .capsule)
                        Button { service.dismissUpdate() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(
                    .regular.tint(Color.blue.opacity(0.06)),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .padding(.horizontal, 12)
            }

            metaRow(data)
                .padding(.horizontal, 16).padding(.bottom, 2)

            footerBar
                .padding(.horizontal, 16).padding(.bottom, 7)
        }
    }

    

    private func legendDot(color: Color, label: String, value: Double) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(Int(value * 100))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    

    private func headerRow(_ data: RateLimitData) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.open.with.lines.needle.33percent")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(data.status == "allowed"
                        ? AnyShapeStyle(Theme.safe)
                        : AnyShapeStyle(Theme.critical))
                Text("Quota")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let plan = service.planDisplayName {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                }
            }

            Spacer()

            Button { service.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    

    private func concentricRings(_ data: RateLimitData) -> some View {
        let v5 = data.fiveHourUtilization
        let v7 = data.sevenDayUtilization
        let c5 = ringColor(for: v5, base: Theme.ring5h)
        let c7 = ringColor(for: v7, base: Theme.ring7d)

        return ZStack {
            // Outer: 5-Hour
            Circle()
                .stroke(Color.primary.opacity(Theme.trackOpacity), lineWidth: Theme.outerWidth)
                .frame(width: Theme.outerRing, height: Theme.outerRing)
            Circle()
                .trim(from: 0, to: v5)
                .stroke(
                    AngularGradient(
                        colors: [c5.opacity(0.8), c5],
                        center: .center,
                        startAngle: .degrees(0), endAngle: .degrees(360 * v5)
                    ),
                    style: StrokeStyle(lineWidth: Theme.outerWidth, lineCap: .round)
                )
                .frame(width: Theme.outerRing, height: Theme.outerRing)
                .rotationEffect(.degrees(-90))
                .shadow(color: c5.opacity(0.4), radius: Theme.glowRadius)
                .animation(.smooth(duration: 0.25), value: v5)

            // Inner: 7-Day
            Circle()
                .stroke(Color.primary.opacity(Theme.trackOpacity), lineWidth: Theme.innerWidth)
                .frame(width: Theme.innerRing, height: Theme.innerRing)
            Circle()
                .trim(from: 0, to: v7)
                .stroke(
                    AngularGradient(
                        colors: [c7.opacity(0.8), c7],
                        center: .center,
                        startAngle: .degrees(0), endAngle: .degrees(360 * v7)
                    ),
                    style: StrokeStyle(lineWidth: Theme.innerWidth, lineCap: .round)
                )
                .frame(width: Theme.innerRing, height: Theme.innerRing)
                .rotationEffect(.degrees(-90))
                .shadow(color: c7.opacity(0.35), radius: Theme.glowRadius - 1)
                .animation(.smooth(duration: 0.25), value: v7)

            // Center label
            VStack(spacing: -1) {
                Text("\(Int(data.activeLimitPercent * 100))")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: Theme.outerRing + 12)
    }

    

    private func detailCard(
        label: String, value: Double, reset: String,
        isBinding: Bool, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isBinding {
                    Text("\u{25C6}")
                        .font(.system(size: 5))
                        .foregroundStyle(color)
                }
                Spacer()
            }
            Text("\(Int(value * 100))%")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .contentTransition(.numericText())

            // Mini bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.gradient)
                        .frame(width: max(0, geo.size.width * value))
                        .animation(.smooth(duration: 0.2), value: value)
                }
            }
            .frame(height: 3)

            Text("Resets \(reset)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.tint(Theme.glassTint),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    

    private func metaRow(_ data: RateLimitData) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: data.status == "allowed"
                      ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(data.status == "allowed" ? Theme.safe : Theme.critical)
                Text(data.status == "allowed" ? "All clear" : "Limited")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            if service.lastUpdated != nil {
                Text(service.lastUpdatedFormatted)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    

    private var peakStatusRow: some View {
        let status = ClaudePeakStatus.current
        return HStack(spacing: 8) {
            Image(systemName: status.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(status.tip)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !status.timeUntilChange.isEmpty {
                Text(status.timeUntilChange)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(status.color.opacity(0.8))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassEffect(
            .regular.tint(status.color.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    

    private func ringColor(for value: Double, base: Color) -> Color {
        if value >= 0.9 { return Theme.critical }
        if value >= 0.75 { return .orange }
        return base
    }

    // Plan picker — shown once after first login

    private var planPickerView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.safe)

            VStack(spacing: 4) {
                Text("You're in!")
                    .font(.system(size: 16, weight: .semibold))
                Text("What Claude plan are you on?")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                planOption("Free", value: "free", desc: "Limited messages")
                planOption("Pro ($20/mo)", value: "pro", desc: "Standard limits")
                planOption("Max 5x ($100/mo)", value: "max_5", desc: "5x Pro limits")
                planOption("Max 20x ($200/mo)", value: "max_20", desc: "20x Pro limits")
                planOption("Team", value: "team", desc: "Organization plan")
            }
            .padding(.horizontal, 12)

            Text("You can change this anytime in Settings")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)

            Spacer().frame(height: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func planOption(_ label: String, value: String, desc: String) -> some View {
        Button {
            service.userPlan = value
            service.showPlanPicker = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(desc)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Theme.glassTint),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    // Login

    private var loginView: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 4)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.06), lineWidth: Theme.outerWidth)
                        .frame(width: 68, height: 68)
                    Circle()
                        .stroke(Color.primary.opacity(0.05), lineWidth: Theme.innerWidth)
                        .frame(width: 48, height: 48)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.quaternary)
                }

                VStack(spacing: 5) {
                    Text("Sign in with Claude")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Log in with your Pro, Max, or Team\naccount to monitor rate limits.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1.5)
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .glassEffect(
                .regular.tint(Theme.glassTint),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .padding(.horizontal, 12)

            if oauth.isAuthenticating {
                VStack(spacing: 10) {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser\u{2026}")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") { oauth.cancel() }
                        .font(.system(size: 10.5, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
            } else {
                Button {
                    oauth.startLogin { creds in service.connect(credentials: creds) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 12))
                        Text("Continue with Claude")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(
                    .regular.tint(Color(red: 0.92, green: 0.45, blue: 0.25)),
                    in: .capsule
                )
            }

            if let err = oauth.error {
                Text(err)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer().frame(height: 2)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    // Loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.05), lineWidth: Theme.outerWidth)
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(Color.primary.opacity(0.04), lineWidth: Theme.innerWidth)
                    .frame(width: 52, height: 52)
                ProgressView().controlSize(.small)
            }
            Text("Fetching usage\u{2026}")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // Error state

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.05), lineWidth: Theme.outerWidth)
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.yellow)
            }
            Text(msg)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 8) {
                Button("Retry") { service.refresh() }
                    .font(.system(size: 10.5, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .glassEffect(.regular.interactive(), in: .capsule)
                Button("Sign Out") { service.disconnect() }
                    .font(.system(size: 10.5, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 20)
    }

    // Footer

    @AppStorage("launchAtLogin") private var launchAtLogin = true

    private var footerBar: some View {
        HStack(spacing: 6) {
            if service.isConnected {
                Menu {
                    Section("Refresh Interval") {
                        ForEach([60.0, 180.0, 300.0, 600.0], id: \.self) { val in
                            Button {
                                service.refreshInterval = val
                            } label: {
                                HStack {
                                    Text(intervalLabel(val))
                                    if service.refreshInterval == val {
                                        Spacer(); Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            launchAtLogin = newValue
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {}
                        }
                    ))

                    Divider()

                    Section("Plan") {
                        ForEach(["pro", "max_5", "max_20", "team", "free"], id: \.self) { plan in
                            Button {
                                service.userPlan = plan
                            } label: {
                                HStack {
                                    Text(planLabel(plan))
                                    if service.userPlan == plan {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Button("Sign Out", role: .destructive) { service.disconnect() }

                    Divider()

                    Section {
                        Text("Quota v\(appVersion)")
                        Text("Made by Tanish Mittal")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape").font(.system(size: 9))
                        Text("Settings").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
            // 🔧 DEBUG TOGGLE (remove with: "remove debug button")
            Button { showDebug.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 9))
                    Text("Debug")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(showDebug ? Color.orange : Color.gray.opacity(0.5))
                .padding(.horizontal, 6).padding(.vertical, 3)
            }
            .buttonStyle(.borderless)

            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.quaternary)
            }
            .buttonStyle(.borderless)
        }
    }

    private func intervalLabel(_ v: Double) -> String {
        switch v {
        case 60: return "1 minute"; case 180: return "3 minutes"
        case 300: return "5 minutes"; case 600: return "10 minutes"
        default: return "\(Int(v / 60))m"
        }
    }

    private func planLabel(_ p: String) -> String {
        switch p {
        case "pro": return "Pro ($20/mo)"
        case "max_5": return "Max 5x ($100/mo)"
        case "max_20": return "Max 20x ($200/mo)"
        case "team": return "Team"
        case "free": return "Free"
        default: return p.capitalized
        }
    }
}

// MARK: - 🔧 DEBUG PANEL (remove with: "remove debug button")

struct DebugPanel: View {
    @ObservedObject var service: RateLimitService
    @State private var sim5h: Double = 0.13
    @State private var sim7d: Double = 0.05

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.orange)
                Text("Debug Panel")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
            }

            Divider()

            
            Group {
                Text("Simulate 5-Hour Usage")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(value: $sim5h, in: 0...1, step: 0.05)
                    .controlSize(.small)
                Text("\(Int(sim5h * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Group {
                Text("Simulate 7-Day Usage")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(value: $sim7d, in: 0...1, step: 0.05)
                    .controlSize(.small)
                Text("\(Int(sim7d * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Button("Apply Simulated Data") {
                service.simulateUsage(fiveHour: sim5h, sevenDay: sim7d)
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Divider()

            
            Text("Notifications")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Button("50%") { service.debugNotification(level: "soft") }
                    .controlSize(.mini)
                Button("80%") { service.debugNotification(level: "hard") }
                    .controlSize(.mini)
                Button("95%") { service.debugNotification(level: "critical") }
                    .controlSize(.mini)
                    .tint(.red)
            }

            Divider()

            
            Text("App States")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Button("Rate Limited") {
                    service.simulateUsage(fiveHour: 1.0, sevenDay: 0.8)
                }
                .controlSize(.mini)
                .tint(.red)

                Button("Update Banner") {
                    service.debugShowUpdate()
                }
                .controlSize(.mini)
                .tint(.blue)

                Button("Error") {
                    service.debugShowError()
                }
                .controlSize(.mini)
                .tint(.orange)
            }

            HStack(spacing: 4) {
                Button("Reset to Real") {
                    service.refresh()
                }
                .controlSize(.mini)
                .tint(.green)

                Button("Peak: \(ClaudePeakStatus.current.rawValue)") {}
                .controlSize(.mini)
                .disabled(true)
            }
        }
        .padding(12)
        .font(.system(size: 10))
    }
}
