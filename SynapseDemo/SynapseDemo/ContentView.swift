import SwiftUI

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
                    .background(.regularMaterial)

                Divider().opacity(0.35)

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
        .task { await vm.checkDaemon() }
    }
}

// MARK: - Liquid Background  (no purple, no lavender)

struct LiquidBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.97, blue: 0.99)   // cool white base

            blob(.init(red: 0.62, green: 0.90, blue: 0.95), 460, x: animate ? -170 : -200, y: animate ? -110 : -150, dur: 9)
            blob(.init(red: 0.58, green: 0.95, blue: 0.82), 400, x: animate ?  160 : 110,  y: animate ?  -70 : -110, dur: 11)
            blob(.init(red: 1.00, green: 0.84, blue: 0.62), 380, x: animate ? -80  : -40,  y: animate ?  155 : 120,  dur: 10)
            blob(.init(red: 0.68, green: 0.88, blue: 1.00), 420, x: animate ?  155 : 200,  y: animate ?  135 : 100,  dur: 12)
        }
        .onAppear { animate = true }
    }

    private func blob(_ color: Color, _ size: CGFloat,
                      x: CGFloat, y: CGFloat, dur: Double) -> some View {
        Circle()
            .fill(color.opacity(0.50))
            .blur(radius: 90)
            .frame(width: size, height: size)
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: dur).repeatForever(autoreverses: true), value: animate)
    }
}

// MARK: - Glass helper

struct Glass<Content: View>: View {
    var radius: CGFloat = 14
    var tint:   Color   = .clear
    var pad:    CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(pad)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius).fill(.regularMaterial)
                    if tint != .clear {
                        RoundedRectangle(cornerRadius: radius).fill(tint.opacity(0.08))
                    }
                    // Specular highlight — Apple Liquid Glass signature
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.70), .white.opacity(0.15)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ), lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.07), radius: 22, x: 0, y: 6)
                .shadow(color: .black.opacity(0.04), radius: 3,  x: 0, y: 1)
            }
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

                Text(String(item.text.prefix(280)))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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

                    Text(result.text)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
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
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.5), lineWidth: 0.5))

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
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
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
                            HStack(spacing: 5) {
                                Text(day).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                Text("· \(nodes.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            }.padding(.top, 8)
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .background(.clear)
        .task { await vm.loadMemory() }
    }
}

private struct MemChip: View {
    let label: String; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? .white : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background {
                    Capsule().fill(active
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.0, green: 0.68, blue: 0.75),
                                     Color(red: 0.0, green: 0.48, blue: 0.58)],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Material.regularMaterial))
                    if !active {
                        Capsule().stroke(.white.opacity(0.5), lineWidth: 0.5)
                    }
                }
        }.buttonStyle(.plain)
    }
}

private struct MemRow: View {
    let node: SynapseViewModel.MemoryNode
    @ObservedObject var vm: SynapseViewModel
    var index: Int = 0
    @State private var hovered  = false
    @State private var appeared = false

    var tint: Color {
        switch node.source.lowercased() {
        case "safari", "chrome":        return .blue
        case "notes", "pages":          return .orange
        case "terminal", "xcode", "code": return .green
        case "mail":                    return Color(red: 0.5, green: 0.2, blue: 0.8)
        default:                        return .teal
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.12)).frame(width: 32, height: 32)
                Image(systemName: SynapseViewModel.sourceIconStatic(node.source))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [tint, tint.opacity(0.7)],
                                                   startPoint: .top, endPoint: .bottom))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.source).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    Spacer()
                    (Text(Date(timeIntervalSince1970: node.timestamp), style: .relative) + Text(" ago"))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Text(node.text).font(.system(size: 12)).foregroundStyle(.primary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).lineSpacing(2.5)
                Text("#\(node.id)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.quaternary)
            }
            if hovered {
                Button { Task { await vm.delete(id: node.id) } } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(hovered ? AnyShapeStyle(Material.regularMaterial) : AnyShapeStyle(Color.clear))
            if hovered {
                RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.5), lineWidth: 0.5)
            }
        }
        .shadow(color: hovered ? tint.opacity(0.15) : .clear, radius: 12, x: 0, y: 4)
        .shadow(color: hovered ? .black.opacity(0.08) : .clear, radius: 4, x: 0, y: 1)
        .scaleEffect(hovered ? 1.008 : 1.0)
        .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { hovered = h } }
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)
                .delay(min(Double(index) * 0.02, 0.3))) { appeared = true }
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
