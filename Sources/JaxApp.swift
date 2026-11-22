import SwiftUI

/// Where Jax lives. Tailscale only: the phone must be on the tailnet.
/// The address comes from JAX_SERVER_URL in Config/*.xcconfig (via Info.plist).
/// Override for testing with the launch argument `-JaxURL <url>`.
enum JaxHost {
    static let base: URL = {
        if let s = UserDefaults.standard.string(forKey: "JaxURL"), let u = URL(string: s) { return u }
        let s = Bundle.main.object(forInfoDictionaryKey: "JaxServerURL") as? String ?? ""
        return URL(string: s) ?? URL(string: "https://your-jax-host:8443/")!
    }()
    static var dashboard: URL { base.appendingPathComponent("dashboard") }
    static var connectors: URL { base.appendingPathComponent("connectors") }
    static var origin: String {
        let port = base.port.map { ":\($0)" } ?? ""
        return "\(base.scheme ?? "https")://\(base.host ?? "")\(port)"
    }
    static var voiceSocket: URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.scheme = base.scheme == "http" ? "ws" : "wss"
        parts.path = "/ws/voice"
        return parts.url!
    }
}

enum Look {
    static let background = Color(red: 0x05 / 255, green: 0x05 / 255, blue: 0x08 / 255)
    static let sky = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)
    static let panel = Color.white.opacity(0.06)
    static let skyHigh = Color(red: 0x7D / 255, green: 0xD3 / 255, blue: 0xFC / 255)
}

@main
struct JaxApp: App {
    init() { WatchRelay.shared.start() }
    var body: some Scene {
        WindowGroup { TalkScreen().preferredColorScheme(.dark) }
    }
}

struct TalkScreen: View {
    @ObservedObject private var jax = JaxClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case history, connections, status
        var id: String { rawValue }
    }
    @State private var pressed = false

    var body: some View {
        ZStack {
            Look.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                OrbView(phase: jax.phase, meter: jax.meter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                words
                controls
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .onChange(of: scenePhase, initial: true) { _, now in
            if now == .active { jax.start() } else if now == .background { jax.pause() }
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                Group {
                    switch which {
                    case .history: MessagesView(jax: jax, store: jax.history)
                    case .connections: StatusPage(url: JaxHost.connectors)
                    case .status: StatusPage(url: JaxHost.dashboard)
                    }
                }
                .background(Look.background)
                .navigationTitle(which == .history ? "Messages" : which == .connections ? "Connections" : "Status")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: pieces

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text("JAX").font(.system(size: 16, weight: .semibold)).tracking(4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Jax, \(caption)")
            Spacer()
            Menu {
                Button { sheet = .history } label: { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                Button { sheet = .connections } label: { Label("Connections", systemImage: "link") }
                Button { sheet = .status } label: { Label("Status", systemImage: "gauge.with.dots.needle.33percent") }
            } label: {
                HStack(spacing: 8) {
                    Text("Menu").font(.system(size: 16, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Look.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: 48)
        .padding(.top, 8)
    }

    private var dotColor: Color {
        switch jax.phase {
        case .offline: return .red
        case .connecting: return .yellow
        default: return .green
        }
    }

    private var caption: String {
        if !jax.notice.isEmpty { return jax.notice }
        switch jax.phase {
        case .connecting: return "Connecting"
        case .offline: return "Can't reach Jax"
        case .ready: return jax.handsFree ? "Listening" : "Ready"
        case .hearing: return "Listening"
        case .thinking: return "Thinking"
        case .searching: return jax.searchLabel.isEmpty ? "Searching" : jax.searchLabel
        case .speaking: return "Speaking"
        }
    }

    /// What was said, both ways. Fixed height so the orb never jumps around.
    private var words: some View {
        VStack(spacing: 12) {
            Text(caption.uppercased())
                .font(.system(size: 16, weight: .semibold)).tracking(3)
                .foregroundStyle(dotColor == .red ? Color.secondary : Look.sky)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: caption)

            Group {
                if case .offline(let why) = jax.phase {
                    VStack(spacing: 8) {
                        Text("Open Tailscale on this phone and check it says Connected. The closet PC must be on and signed in.")
                        Text(why).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                } else if !jax.hint.isEmpty {
                    Text(jax.hint).font(.system(size: 16)).foregroundStyle(.secondary)
                } else if jax.heard.isEmpty, jax.reply.isEmpty, jax.phase == .ready {
                    Text(jax.handsFree ? "Just talk. Jax is listening." : "Hold the button, talk, then let go.")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            if !jax.heard.isEmpty {
                                Text(jax.heard).font(.system(size: 16)).foregroundStyle(.secondary)
                            }
                            if !jax.reply.isEmpty {
                                Text(jax.reply).font(.system(size: 20)).foregroundStyle(.primary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.top, for: .alignment)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .scrollIndicators(.hidden)
                }
            }
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .frame(maxWidth: .infinity)
            .frame(height: 132, alignment: .top)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
        .padding(.bottom, 24)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Button { jax.handsFree.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 16, weight: .semibold))
                    Text(jax.handsFree ? "Hands-free on" : "Hands-free off").font(.system(size: 16, weight: .medium))
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .foregroundStyle(jax.handsFree ? Look.sky : Color.secondary)
                .background(jax.handsFree ? Look.sky.opacity(0.16) : Look.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(jax.handsFree ? Look.sky.opacity(0.9) : Color.white.opacity(0.10),
                                                lineWidth: jax.handsFree ? 2 : 1))
            }
            .accessibilityLabel("Hands-free listening")
            .accessibilityValue(jax.handsFree ? "On" : "Off")
            .sensoryFeedback(.selection, trigger: jax.handsFree)

            mainButton
        }
    }

    @ViewBuilder private var mainButton: some View {
        if case .offline = jax.phase {
            Button { jax.retryNow() } label: { pill("Try again", icon: "arrow.clockwise", filled: true) }
        } else {
            pill(buttonTitle, icon: pressed ? "waveform" : "mic.fill",
                 filled: !pressed && jax.phase != .thinking && jax.phase != .searching && jax.phase != .connecting)
                .scaleEffect(pressed ? 0.96 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
                .animation(.easeOut(duration: 0.2), value: jax.phase)
                .opacity(jax.phase == .connecting ? 0.4 : 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !pressed else { return }
                            pressed = true
                            jax.pressDown()
                        }
                        .onEnded { _ in
                            pressed = false
                            jax.pressUp()
                        })
                .accessibilityLabel("Hold to talk")
                .accessibilityHint("Press and hold, speak, then let go to send")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { pressed ? jax.pressUp() : jax.pressDown(); pressed.toggle() }
        }
    }

    /// The button always says what your thumb can do right now.
    private var buttonTitle: String {
        if pressed { return "Let go to send" }
        switch jax.phase {
        case .speaking: return "Hold to interrupt"
        case .connecting: return "Connecting"
        default: return "Hold to talk"
        }
    }

    private func pill(_ title: String, icon: String, filled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            Text(title).font(.system(size: 20, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .foregroundStyle(filled ? Color.black : Look.sky)
        .background(filled
            ? AnyShapeStyle(LinearGradient(colors: [Look.skyHigh, Look.sky], startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(Look.sky.opacity(0.16)), in: Capsule())
        .overlay(Capsule().strokeBorder(filled ? Color.white.opacity(0.35) : Look.sky.opacity(0.9), lineWidth: filled ? 1 : 2))
        .shadow(color: Look.sky.opacity(filled ? 0.38 : 0), radius: 18, y: 8)
        .contentShape(Capsule())
    }
}
