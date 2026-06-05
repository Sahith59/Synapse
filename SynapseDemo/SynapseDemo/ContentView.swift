import SwiftUI
import AppKit

// MARK: - Global cursor tracker
//
// Ported from the web spotlight card's `pointermove` listener: one app-wide
// monitor publishes the cursor location (window coords, top-left origin) so any
// card can paint a glow that follows the pointer.

final class MouseTracker: ObservableObject {
    static let shared = MouseTracker()
    @Published var location: CGPoint = .zero
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            if let window = event.window {
                let p = event.locationInWindow
                let h = window.contentLayoutRect.height
                self?.location = CGPoint(x: p.x, y: h - p.y)
            }
            return event
        }
        DispatchQueue.main.async { NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true } }
    }
}

// MARK: - Synapse card style
//
// One cohesive surface used by every card. Fuses (1) a cursor-tracking radial
// spotlight glow that brightens near the pointer (from the web spotlight card)
// with (2) a neumorphic dark-glass surface: soft dual shadow + specular Liquid
// Glass stroke. Dark iOS-26 aesthetic.

struct SynapseCardStyle: ViewModifier {
    var radius: CGFloat = 18
    var tint: Color = Color(red: 0.0, green: 0.78, blue: 0.85)
    var padding: CGFloat = 16
    var interactive: Bool = true

    @ObservedObject private var mouse = MouseTracker.shared
    @State private var hovered = false
    @State private var cardFrame: CGRect = .zero

    private var localPoint: CGPoint {
        CGPoint(x: mouse.location.x - cardFrame.minX, y: mouse.location.y - cardFrame.minY)
    }

    private var proximity: CGFloat {
        guard cardFrame.width > 0 else { return 0 }
        let dx = mouse.location.x - cardFrame.midX, dy = mouse.location.y - cardFrame.midY
        let dist = sqrt(dx * dx + dy * dy)
        let reach = max(cardFrame.width, cardFrame.height) * 1.1
        return max(0, min(1, 1 - dist / reach))
    }

    // Light neumorphic surface color
    private let surface = Color(red: 0.925, green: 0.935, blue: 0.955)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                ZStack {
                    // Raised whitish-grey neumorphic surface
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(surface)

                    // Soft top-left light highlight built into the fill for the
                    // "extruded" neumorphic look
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.55), Color.clear],
                                startPoint: .topLeading, endPoint: .center))

                    // Cursor spotlight — a gentle colored bloom that follows the pointer
                    if interactive {
                        RadialGradient(
                            colors: [tint.opacity(0.14 + 0.16 * proximity), .clear],
                            center: UnitPoint(
                                x: cardFrame.width  > 0 ? max(0, min(1, localPoint.x / cardFrame.width))  : 0.5,
                                y: cardFrame.height > 0 ? max(0, min(1, localPoint.y / cardFrame.height)) : 0.5),
                            startRadius: 0, endRadius: 240)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .allowsHitTesting(false)
                    }

                    // Hairline edge for crispness
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.7), lineWidth: 0.8)
                }
                // Neumorphic dual shadow: dark cast bottom-right + bright lift top-left
                .shadow(color: Color(red: 0.55, green: 0.58, blue: 0.64).opacity(hovered ? 0.55 : 0.42),
                        radius: hovered ? 22 : 14, x: hovered ? 12 : 8, y: hovered ? 12 : 8)
                .shadow(color: Color.white.opacity(hovered ? 0.95 : 0.85),
                        radius: hovered ? 20 : 13, x: hovered ? -10 : -7, y: hovered ? -10 : -7)
                // Colored hover bloom for liveliness
                .shadow(color: tint.opacity(hovered ? 0.20 : 0.0), radius: 24, x: 0, y: 6)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { cardFrame = geo.frame(in: .global) }
                            .onChange(of: mouse.location) { _ in cardFrame = geo.frame(in: .global) }
                    }
                )
            }
            .scaleEffect(hovered && interactive ? 1.012 : 1.0)
            .animation(.spring(response: 0.30, dampingFraction: 0.72), value: hovered)
            .onHover { h in if interactive { hovered = h } }
    }
}

extension View {
    func synapseCard(radius: CGFloat = 18,
                     tint: Color = Color(red: 0.0, green: 0.78, blue: 0.85),
                     padding: CGFloat = 16,
                     interactive: Bool = true) -> some View {
        modifier(SynapseCardStyle(radius: radius, tint: tint, padding: padding, interactive: interactive))
    }
}

// MARK: - Navigation

enum AppTab: String, Identifiable, CaseIterable, Hashable {
    case intelligence = "Intelligence"
    case memory       = "Memory"
    var id: Self { self }
    var icon: String {
        switch self {
        case .intelligence: "brain.head.profile"
        case .memory:       "cylinder.split.1x2"
        }
    }
}

// MARK: - Root
// Single ZStack: one gradient backdrop, all panels float on top with .regularMaterial.
// No nested backgrounds — that was causing the pane bleed.

struct ContentView: View {
    @StateObject private var vm = SynapseViewModel()
    @State private var tab: AppTab = .intelligence

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ── ONE gradient, fills the whole window ──────────────────────────
            LiquidBackground().ignoresSafeArea()

            // ── App shell ─────────────────────────────────────────────────────
            HStack(spacing: 0) {
                Sidebar(tab: $tab, vm: vm)
                    .frame(width: 210)
                    .background(Color(red: 0.90, green: 0.91, blue: 0.94).opacity(0.6))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.black.opacity(0.06)).frame(width: 0.5)
                    }

                // Detail
                ZStack {
                    switch tab {
                    case .intelligence: IntelligenceView(vm: vm)
                    case .memory:       MemoryView(vm: vm)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Light neumorphic theme: .primary resolves to near-black, readable on the
        // soft whitish-grey glass surfaces.
        .preferredColorScheme(.light)
        .task { await vm.checkDaemon() }
    }
}

// MARK: - Liquid Background  (no purple, no lavender)

struct LiquidBackground: View {
    var body: some View {
        ZStack {
            // Soft whitish-grey neumorphic canvas. Neumorphism reads best on a calm,
            // near-flat surface — the depth comes from the cards' dual shadows, not
            // a busy background.
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.94, blue: 0.96),
                         Color(red: 0.88, green: 0.89, blue: 0.92)],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            // Very subtle cool highlight top-left for a gentle light source
            RadialGradient(
                colors: [Color.white.opacity(0.5), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700)
        }
    }
}

// MARK: - Glass helper

struct Glass<Content: View>: View {
    var radius: CGFloat = 14
    var tint:   Color   = .clear
    var pad:    CGFloat = 14
    @ViewBuilder var content: () -> Content

    // Map the old per-card tints onto the new dark card system. A clear tint
    // falls back to the signature teal so every surface shares one language.
    private var resolvedTint: Color {
        tint == .clear ? Color(red: 0.0, green: 0.78, blue: 0.85) : tint
    }

    var body: some View {
        content()
            .synapseCard(radius: radius, tint: resolvedTint, padding: pad)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var tab: AppTab
    @ObservedObject var vm: SynapseViewModel

    var body: some View {
        VStack(spacing: 0) {

            // App identity
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.0, green: 0.68, blue: 0.75),
                                         Color(red: 0.0, green: 0.52, blue: 0.60)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .shadow(color: Color.teal.opacity(0.35), radius: 8, y: 3)
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Synapse")
                            .font(.system(size: 15, weight: .bold))
                        Text("on-device memory fabric")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Memory count card
                Glass(radius: 12, tint: .teal, pad: 12) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(vm.totalSnippets)")
                                .font(.system(size: 26, weight: .bold, design: .monospaced))
                                .contentTransition(.numericText())
                            Text("memories stored")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "cylinder.split.1x2.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.teal.gradient)
                            .offset(y: -2)
                    }
                }
            }
            .padding(14)

            Divider().opacity(0.3).padding(.horizontal, 14)

            // Nav items
            VStack(spacing: 3) {
                ForEach(AppTab.allCases) { t in
                    NavItem(t: t, active: tab == t) { tab = t }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Spacer()

            // Footer
            Divider().opacity(0.3).padding(.horizontal, 14)
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.daemonRunning ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                        .shadow(color: vm.daemonRunning ? .green.opacity(0.5) : .red.opacity(0.4), radius: 4)
                    Text(vm.daemonRunning ? "Daemon Active" : "Daemon Offline")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await vm.checkDaemon() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.green)
                    Text("0 bytes sent · 100% on-device")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

private struct NavItem: View {
    let t: AppTab; let active: Bool; let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: t.icon)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.teal : Color.secondary)
                    .frame(width: 18)
                Text(t.rawValue)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                Spacer()
                if active {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.teal.opacity(0.5))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? Color.teal.opacity(0.12) : (hovered ? Color.secondary.opacity(0.07) : .clear))
                if active {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.teal.opacity(0.25), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Intelligence View

struct IntelligenceView: View {
    @ObservedObject var vm: SynapseViewModel

    var body: some View {
        HSplitView {
            ObserverPane(vm: vm)
                .frame(minWidth: 240, idealWidth: 278, maxWidth: 318)

            QueryPane(vm: vm)
                .frame(minWidth: 420)
        }
        .task { vm.startLiveContextStreaming() }
        .onDisappear { vm.stopLiveContextStreaming() }
    }
}

// MARK: - Observer Pane

struct ObserverPane: View {
    @ObservedObject var vm: SynapseViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // Header
                Glass(radius: 14, tint: .orange) {
                    HStack(spacing: 10) {
                        LiveRing(active: vm.activeContext != nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live Context")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Active Window Observer")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if vm.activeContext != nil {
                            Text("LIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.orange.gradient)
                                .clipShape(Capsule())
                                .shadow(color: .orange.opacity(0.3), radius: 5, y: 2)
                        }
                    }
                }

                // Context
                if let ctx = vm.activeContext {
                    ContextCard(item: ctx)
                } else {
                    EmptyObserver()
                }

                // How it works
                Glass(radius: 14, pad: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("HOW IT WORKS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary).kerning(0.9)
                        ForEach([
                            ("eye",                 "Reads active macOS window via Accessibility APIs"),
                            ("cpu.fill",            "MiniLM embeddings in PyTorch — ~2ms per query"),
                            ("cylinder.split.1x2",  "FAISS IndexIDMap + SQLite WAL"),
                            ("lock.shield.fill",    "Zero network calls — 100% private"),
                        ], id: \.0) { icon, text in
                            HStack(spacing: 9) {
                                Image(systemName: icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary).frame(width: 16)
                                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(.clear)
    }
}

private struct LiveRing: View {
    let active: Bool
    @State private var ring  = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.orange.opacity(ring ? 0 : 0.4), lineWidth: 1.5)
                .frame(width: ring ? 28 : 10, height: ring ? 28 : 10)
                .animation(active ? .easeOut(duration: 1.6).repeatForever(autoreverses: false) : .default, value: ring)
            Circle()
                .fill(active ? Color.orange : Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
                .shadow(color: active ? .orange.opacity(0.5) : .clear, radius: 6)
                .scaleEffect(pulse ? 0.80 : 1.0)
                .animation(active ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default, value: pulse)
        }
        .frame(width: 28, height: 28)
        .onAppear { if active { ring = true; pulse = true } }
        .onChange(of: active) { ring = active; pulse = active }
    }
}

private struct ContextCard: View {
    let item: SynapseViewModel.ResultItem
    @State private var hovered = false

    var body: some View {
        Glass(radius: 14, tint: .orange, pad: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: SynapseViewModel.sourceIconStatic(item.source))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                    Text(item.source.uppercased())
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.orange).kerning(0.8)
                    Spacer()
                    Text("#\(item.id)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.orange.opacity(0.07))

                Rectangle().fill(Color.orange.opacity(0.12)).frame(height: 0.5)

                Text(String(SynapseViewModel.prettify(item.text).prefix(280)))
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8))
                    .lineSpacing(3.5).lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)

                (Text(Date(timeIntervalSince1970: item.timestamp), style: .relative) + Text(" ago"))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .shadow(color: hovered ? Color.orange.opacity(0.20) : .clear, radius: 16, x: 0, y: 5)
        .shadow(color: hovered ? .black.opacity(0.08) : .clear, radius: 6, x: 0, y: 2)
        .scaleEffect(hovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
    }
}

private struct EmptyObserver: View {
    var body: some View {
        Glass(radius: 14) {
            VStack(spacing: 14) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.tertiary)
                VStack(spacing: 5) {
                    Text("No active context")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Text("Switch to Safari, Notes, or Chrome\nto start capturing context")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).lineSpacing(2)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
        }
    }
}

// MARK: - Query Pane

struct QueryPane: View {
    @ObservedObject var vm: SynapseViewModel
    @FocusState private var focused: Bool

    private let suggestions = [
        ("meeting notes",       "person.2"),
        ("Apple Neural Engine", "cpu"),
        ("grocery list",        "cart"),
        ("travel plans",        "airplane"),
        ("workout routine",     "figure.run"),
        ("code project",        "chevron.left.forwardslash.chevron.right"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Synthesis — only appears after user triggers a search
                if vm.isGenerating || !vm.ragAnswer.isEmpty {
                    SynthesisCard(vm: vm)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity))
                }

                // Search box
                Glass(radius: 16, pad: 14) {
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(focused ? Color.teal : Color.secondary)
                                .animation(.easeInOut(duration: 0.15), value: focused)

                            TextField("What are you looking for?", text: $vm.queryText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 15))
                                .focused($focused)
                                .onSubmit { Task { await vm.query() } }
                                .onAppear {
                                    // Grab keyboard focus so the user can type immediately
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        focused = true
                                    }
                                }

                            if !vm.queryText.isEmpty {
                                Button {
                                    vm.queryText = ""; vm.results = []; vm.ragAnswer = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16)).foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { focused = true }

                        // Search CTA
                        Button { Task { await vm.query() } } label: {
                            HStack(spacing: 8) {
                                if vm.isQuerying {
                                    ProgressView().scaleEffect(0.65).tint(.white)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                Text(vm.isQuerying ? "Searching vectors…" : "Search Memory Fabric")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background {
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(
                                        vm.queryText.isEmpty
                                        ? AnyShapeStyle(Color.secondary.opacity(0.22))
                                        : AnyShapeStyle(LinearGradient(
                                            colors: [Color(red: 0.0, green: 0.65, blue: 0.72),
                                                     Color(red: 0.0, green: 0.48, blue: 0.58)],
                                            startPoint: .leading, endPoint: .trailing))
                                    )
                                    .shadow(color: vm.queryText.isEmpty ? .clear : Color.teal.opacity(0.35),
                                            radius: 10, y: 4)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isQuerying || vm.queryText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .animation(.easeInOut(duration: 0.15), value: vm.queryText.isEmpty)

                        // Suggestion chips
                        if vm.queryText.isEmpty && !vm.isQuerying {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("TRY A SEARCH")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tertiary).kerning(0.9)
                                LazyVGrid(
                                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                                    spacing: 6
                                ) {
                                    ForEach(suggestions, id: \.0) { q, icon in
                                        Button {
                                            vm.queryText = q
                                            Task { await vm.query() }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: icon).font(.system(size: 10))
                                                    .foregroundStyle(Color.teal)
                                                Text(q).font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(.secondary).lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(.regularMaterial)
                                            .clipShape(RoundedRectangle(cornerRadius: 9))
                                            .overlay(RoundedRectangle(cornerRadius: 9)
                                                .stroke(.white.opacity(0.5), lineWidth: 0.5))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }

                // Results
                if !vm.results.isEmpty && !vm.isQuerying {
                    ResultsSection(vm: vm)
                }
            }
            .padding(16)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: vm.ragAnswer)
        }
        .background(.clear)
    }
}

// MARK: - Synthesis Card

struct SynthesisCard: View {
    @ObservedObject var vm: SynapseViewModel
    @State private var dotPhase = 0

    var body: some View {
        Glass(radius: 16, tint: .teal, pad: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.0, green: 0.68, blue: 0.75),
                                         Color(red: 0.0, green: 0.48, blue: 0.58)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 26, height: 26)
                            .shadow(color: Color.teal.opacity(0.4), radius: 6, y: 2)
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .symbolEffect(.pulse, isActive: vm.isGenerating)
                    }
                    Text("Synapse Synthesis")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if vm.isGenerating {
                        HStack(spacing: 4) {
                            ForEach(0..<3) { i in
                                Circle().fill(Color.teal).frame(width: 5, height: 5)
                                    .opacity(dotPhase == i ? 1 : 0.2)
                            }
                        }
                        .animation(.easeInOut(duration: 0.3), value: dotPhase)
                    } else if !vm.ragAnswer.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundStyle(.green)
                            Text(vm.synthesisMs >= 1000
                                 ? String(format: "%.1fs", vm.synthesisMs / 1000)
                                 : String(format: "%.0fms", vm.synthesisMs))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(Color.teal.opacity(0.07))

                Rectangle().fill(Color.teal.opacity(0.15)).frame(height: 0.5)

                if vm.isGenerating && vm.ragAnswer.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonLines()
                        HStack(spacing: 5) {
                            Image(systemName: "cpu.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text("Llama 3.2 3B · 4-bit quantized · Apple MLX")
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(16)
                    .overlay(ShimmerOverlay())
                } else if !vm.ragAnswer.isEmpty {
                    Text(vm.ragAnswer)
                        .font(.system(size: 14)).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(16)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.38, repeats: true) { _ in
                Task { @MainActor in if vm.isGenerating { dotPhase = (dotPhase + 1) % 3 } }
            }
        }
    }
}

// MARK: - Results

private struct ResultsSection: View {
    @ObservedObject var vm: SynapseViewModel

    var deduped: [SynapseViewModel.ResultItem] {
        var seen = Set<String>()
        return vm.results.filter { item in
            let key = String(item.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(80))
            guard !seen.contains(key) else { return false }
            seen.insert(key); return true
        }.prefix(3).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 5) {
                    Text("SUPPORTING CONTEXT").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary).kerning(0.9)
                    Text("· \(deduped.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(String(format: "%.0fms", vm.queryLatencyMs))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 2)

            ForEach(Array(deduped.enumerated()), id: \.element.id) { idx, r in
                ResultCard(result: r, rank: idx + 1, vm: vm)
            }
        }
    }
}

private struct ResultCard: View {
    let result: SynapseViewModel.ResultItem
    let rank: Int
    @ObservedObject var vm: SynapseViewModel
    @State private var appeared = false
    @State private var hovered  = false
    @State private var expanded = false
    @State private var copied   = false

    var accent: Color {
        result.relevance >= 75 ? .green : result.relevance >= 45 ? .teal : .secondary
    }

    var body: some View {
        Glass(radius: 14, pad: 0) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.4)],
                                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 3).padding(.vertical, 10).padding(.leading, 10)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("\(rank)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                            .frame(width: 22, height: 22)
                            .background(accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        HStack(spacing: 4) {
                            Image(systemName: SynapseViewModel.sourceIconStatic(result.source))
                                .font(.system(size: 10))
                            Text(result.source.capitalized).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.secondary.opacity(0.08))
                        .clipShape(Capsule())

                        Spacer()

                        Text("\(result.relevance)%")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                    }

                    Text(SynapseViewModel.prettify(result.text))
                        .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(expanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                        .textSelection(.enabled)

                    HStack(spacing: 5) {
                        Text("#\(result.id)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        Text("·").foregroundStyle(.tertiary)
                        (Text(Date(timeIntervalSince1970: result.timestamp), style: .relative) + Text(" ago"))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                        Spacer()
                        if result.text.count > 140 {
                            Text(expanded ? "Show less" : "Show more")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.teal)
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.text, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }
                }
                .padding(12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { expanded.toggle() }
        }
        // Hover lift: stronger shadow + subtle scale
        .shadow(color: hovered ? accent.opacity(0.18) : .clear, radius: 18, x: 0, y: 6)
        .shadow(color: hovered ? .black.opacity(0.10) : .clear, radius: 8, x: 0, y: 3)
        .scaleEffect(hovered ? 1.012 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 12)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8).delay(Double(rank) * 0.08)) {
                appeared = true
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await vm.delete(id: result.id) }
            } label: { Label("Remove from Memory", systemImage: "trash") }
        }
    }
}

// MARK: - Memory View

struct MemoryView: View {
    @ObservedObject var vm: SynapseViewModel
    @State private var search       = ""
    @State private var sourceFilter: String? = nil

    var filtered: [SynapseViewModel.MemoryNode] {
        vm.memoryNodes.filter {
            (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search))
            && (sourceFilter == nil || $0.source == sourceFilter)
        }
    }

    var grouped: [(String, [SynapseViewModel.MemoryNode])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered) { n -> String in
            let d = Date(timeIntervalSince1970: n.timestamp)
            if cal.isDateInToday(d)     { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f.string(from: d)
        }
        return dict.sorted { ($0.value.first?.timestamp ?? 0) > ($1.value.first?.timestamp ?? 0) }
    }

    var sources: [String] { Array(Set(vm.memoryNodes.map { $0.source })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Search \(vm.totalSnippets) memories…", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 14))
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.925, green: 0.935, blue: 0.955))
                        .shadow(color: Color(red: 0.55, green: 0.58, blue: 0.64).opacity(0.35),
                                radius: 5, x: 3, y: 3)
                        .shadow(color: .white.opacity(0.9), radius: 5, x: -3, y: -3)
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        MemChip(label: "All · \(vm.totalSnippets)", active: sourceFilter == nil) {
                            sourceFilter = nil
                        }
                        ForEach(sources, id: \.self) { src in
                            let n = vm.memoryNodes.filter { $0.source == src }.count
                            MemChip(label: "\(src) · \(n)", active: sourceFilter == src) {
                                sourceFilter = sourceFilter == src ? nil : src
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(Color(red: 0.90, green: 0.91, blue: 0.94).opacity(0.6))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5)
            }

            if vm.isLoadingMemory {
                Spacer()
                ProgressView("Loading memories…").foregroundStyle(.secondary)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: search.isEmpty ? "cylinder.split.1x2" : "magnifyingglass")
                        .font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text(search.isEmpty ? "No memories stored yet" : "No results for \"\(search)\"")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { day, nodes in
                        Section {
                            ForEach(Array(nodes.enumerated()), id: \.element.id) { idx, node in
                                MemRow(node: node, vm: vm, index: idx)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(day.uppercased())
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .kerning(0.6)
                                Text("\(nodes.count)")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.black.opacity(0.06)))
                            }
                            .padding(.top, 10).padding(.bottom, 2)
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .background(Color.clear)
        .task { await vm.loadMemory() }
    }
}

private struct MemChip: View {
    let label: String; let active: Bool; let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? .white : .secondary)
                .padding(.horizontal, 13).padding(.vertical, 6.5)
                .background {
                    Capsule().fill(active
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.0, green: 0.70, blue: 0.78),
                                     Color(red: 0.0, green: 0.50, blue: 0.60)],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color(red: 0.925, green: 0.935, blue: 0.955).opacity(hovered ? 1.0 : 0.85)))
                    if !active {
                        Capsule().stroke(Color.black.opacity(0.06), lineWidth: 0.8)
                    }
                }
                .shadow(color: active ? Color(red: 0.0, green: 0.6, blue: 0.7).opacity(0.35)
                                      : Color(red: 0.55, green: 0.58, blue: 0.64).opacity(hovered ? 0.0 : 0.25),
                        radius: active ? 6 : 3, x: active ? 0 : 2, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hovered = h } }
    }
}

private struct MemRow: View {
    let node: SynapseViewModel.MemoryNode
    @ObservedObject var vm: SynapseViewModel
    var index: Int = 0
    @State private var hovered  = false
    @State private var appeared = false
    @State private var expanded = false
    @State private var copied   = false

    var tint: Color {
        switch node.source.lowercased() {
        case "safari", "chrome", "arc":          return Color(red: 0.30, green: 0.62, blue: 1.0)
        case "notes", "pages":                   return Color(red: 1.0, green: 0.62, blue: 0.18)
        case "terminal", "xcode", "vs code", "code", "cursor":
                                                 return Color(red: 0.30, green: 0.85, blue: 0.55)
        case "mail":                             return Color(red: 0.62, green: 0.40, blue: 1.0)
        default:                                 return Color(red: 0.20, green: 0.80, blue: 0.80)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Source icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.22))
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 0.5)
                    )
                Image(systemName: SynapseViewModel.sourceIconStatic(node.source))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.source)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(tint)
                    Spacer()
                    (Text(Date(timeIntervalSince1970: node.timestamp), style: .relative) + Text(" ago"))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                // Body text — cleaned for display
                Text(SynapseViewModel.prettify(node.text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text("#\(node.id)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if node.text.count > 90 {
                        Text(expanded ? "Show less" : "Show more")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Spacer()
                    if hovered {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.text, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(copied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        Button { Task { await vm.delete(id: node.id) } } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background {
            ZStack {
                // Light neumorphic surface
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.925, green: 0.935, blue: 0.955))
                // Soft top-left highlight
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.5), .clear],
                                         startPoint: .topLeading, endPoint: .center))
                // Source-colored left accent rail
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.4)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 3)
                        .padding(.vertical, 10)
                        .padding(.leading, 2)
                    Spacer()
                }
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.7), lineWidth: 0.8)
            }
            // Neumorphic dual shadow
            .shadow(color: Color(red: 0.55, green: 0.58, blue: 0.64).opacity(hovered ? 0.5 : 0.32),
                    radius: hovered ? 16 : 10, x: hovered ? 9 : 6, y: hovered ? 9 : 6)
            .shadow(color: .white.opacity(hovered ? 0.95 : 0.8),
                    radius: hovered ? 14 : 9, x: hovered ? -8 : -5, y: hovered ? -8 : -5)
            .shadow(color: hovered ? tint.opacity(0.18) : .clear, radius: 18, x: 0, y: 5)
        }
        .scaleEffect(hovered ? 1.012 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.text.count > 90 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { expanded.toggle() }
            }
        }
        .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { hovered = h } }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)
                .delay(min(Double(index) * 0.035, 0.4))) { appeared = true }
        }
    }
}

// MARK: - Skeleton + Shimmer

private struct SkeletonLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkBar(f: 1.00); SkBar(f: 0.86); SkBar(f: 0.70); SkBar(f: 0.48)
        }
    }
}

private struct SkBar: View {
    let f: CGFloat
    @State private var phase: CGFloat = -1.2
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.10)).frame(width: g.size.width * f, height: 10)
                Capsule()
                    .fill(LinearGradient(colors: [.clear, .secondary.opacity(0.18), .clear],
                                        startPoint: .init(x: phase, y: 0),
                                        endPoint:   .init(x: phase + 1, y: 0)))
                    .frame(width: g.size.width * f, height: 10)
            }
        }
        .frame(height: 10)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { phase = 1.4 }
        }
    }
}

private struct ShimmerOverlay: View {
    @State private var phase: CGFloat = -1.4
    var body: some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.12), location: 0.45),
                    .init(color: .white.opacity(0.22), location: 0.5),
                    .init(color: .white.opacity(0.12), location: 0.55),
                    .init(color: .clear, location: 1)],
            startPoint: .init(x: phase, y: 0.3),
            endPoint:   .init(x: phase + 1.4, y: 0.8)
        )
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1.4 }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView().frame(width: 1060, height: 720)
}
