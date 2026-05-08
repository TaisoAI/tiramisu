import SwiftUI

struct MainWindow: View {
    @Environment(DocumentStore.self) private var store
    @AppStorage("ui.inspector.visible") private var showingInspector: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            ToolSidebar()
                .frame(width: 64)
                .frame(maxHeight: .infinity)
                .background(.bar)
            Divider()
            VStack(spacing: 0) {
                ToolOptionsBar()
                Divider()
                ZStack {
                    Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
                    CanvasView()
                }
                .clipped()  // keep transform-handle overflow from bleeding into toolbar/status bar
                Divider()
                CanvasStatusBar()
            }
            .inspector(isPresented: $showingInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            }
        }
        .toolbar { CanvasToolbar(store: store) }
        .navigationTitle(titleText)
        .navigationSubtitle("\(Int(store.canvasSize.width)) × \(Int(store.canvasSize.height))")
    }
    private var titleText: String {
        let base = store.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return store.isDirty ? "\(base) — Edited" : base
    }
}

/// Bottom status strip below the canvas. Holds zoom controls (left) and
/// document size readout (right). Lives outside the canvas area so it
/// never overlaps content — Photoshop / Pixelmator pattern.
private struct CanvasStatusBar: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            ZoomHUD()
            Spacer()
            Text("\(Int(store.canvasSize.width)) × \(Int(store.canvasSize.height))")
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }
}

private struct CanvasToolbar: ToolbarContent {
    @Bindable var store: DocumentStore
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Thumbnails") {
                    Button("YouTube · 1280 × 720") { setSize(1280, 720) }
                    Button("FHD · 1920 × 1080") { setSize(1920, 1080) }
                    Button("2K · 2560 × 1440") { setSize(2560, 1440) }
                    Button("4K UHD · 3840 × 2160") { setSize(3840, 2160) }
                }
                Section("Instagram") {
                    Button("Square · 1080 × 1080") { setSize(1080, 1080) }
                    Button("Portrait · 1080 × 1350") { setSize(1080, 1350) }
                    Button("Story / Reels · 1080 × 1920") { setSize(1080, 1920) }
                }
                Section("TikTok") {
                    Button("Cover / Reel · 1080 × 1920") { setSize(1080, 1920) }
                }
                Section("X / Twitter") {
                    Button("Post · 1200 × 675") { setSize(1200, 675) }
                    Button("Header · 1500 × 500") { setSize(1500, 500) }
                }
                Section("LinkedIn") {
                    Button("Post · 1200 × 627") { setSize(1200, 627) }
                    Button("Header · 1584 × 396") { setSize(1584, 396) }
                }
                Section("Channel Art / Banners") {
                    Button("YouTube Banner · 2560 × 1440") { setSize(2560, 1440) }
                    Button("Twitch Banner · 1920 × 480") { setSize(1920, 480) }
                    Button("Discord Banner · 960 × 540") { setSize(960, 540) }
                }
                Section("Avatars") {
                    Button("Profile Picture · 1024 × 1024") { setSize(1024, 1024) }
                    Button("Discord Server · 512 × 512") { setSize(512, 512) }
                }
                Section("Podcast Cover") {
                    Button("Apple · 3000 × 3000") { setSize(3000, 3000) }
                    Button("Spotify · 1400 × 1400") { setSize(1400, 1400) }
                }
                Divider()
                Button("Custom Size…") { CanvasSizeDialog.present(store: store) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            } label: {
                Label("Canvas \(Int(store.canvasSize.width))×\(Int(store.canvasSize.height))",
                      systemImage: "rectangle.dashed")
            }

            Menu {
                Toggle("Rule of Thirds", isOn: $store.showRuleOfThirds)
                Toggle("Golden Ratio", isOn: $store.showGoldenRatio)
                Divider()
                Toggle("YouTube Safe Area", isOn: $store.showSafeArea)
                Toggle("YouTube Rounded Corners", isOn: $store.showYTCornerRadius)
                Toggle("YouTube Duration Pill", isOn: $store.showYTDurationPill)
                Divider()
                Toggle("YouTube Banner Safe Areas", isOn: $store.showYTBannerSafeAreas)
                Divider()
                Toggle("PFP Circle Mask", isOn: $store.showPFPCircleMask)
            } label: {
                Label("Guides", systemImage: "squareshape.split.3x3")
            }
            .help("Composition and YouTube-specific guides")
        }
    }
    @MainActor
    private func setSize(_ w: CGFloat, _ h: CGFloat) {
        tlog("setSize → \(w) × \(h)")
        store.canvasSize = CGSize(width: w, height: h)
        store.invalidate()
    }
}

extension ColorRGB {
    var swiftUIColor: Color { Color(nsColor.usingColorSpace(.sRGB) ?? .white) }
}
extension Color {
    var asNSColor: NSColor { NSColor(self) }
}
