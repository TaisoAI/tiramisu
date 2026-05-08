import SwiftUI
import AppKit

/// First-run welcome dialog. Custom SwiftUI window styled to match the
/// marketing-site brand (mascarpone background, espresso/cocoa typography,
/// accent-orange CTA). Stores a "don't show again" preference under
/// `world.hanley.tiramisu.welcomeShown`.
@MainActor
enum WelcomeWindow {
    private static let prefsKey = "world.hanley.tiramisu.welcomeShown"
    private static var window: NSWindow?

    static func showIfNeeded() {
        if UserDefaults.standard.bool(forKey: prefsKey) { return }
        show(forced: false)
    }

    static func show(forced: Bool) {
        window?.close()

        let view = WelcomeView(
            initialDontShow: !forced,
            onAction: { action, dontShow in
                if dontShow { UserDefaults.standard.set(true, forKey: prefsKey) }
                window?.close()
                window = nil
                switch action {
                case .getStarted:
                    break
                case .setupAI:
                    GenerativeFillUI.runLocalFluxBootstrap()
                case .visitWebsite:
                    if let url = URL(string: "https://tiramisu.hanley.world") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        )
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 460, height: 580))
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.level = .floating
        window = win
    }

    static func resetPreference() {
        UserDefaults.standard.removeObject(forKey: prefsKey)
    }
}

private enum WelcomeAction { case getStarted, setupAI, visitWebsite }

// MARK: - View

private struct WelcomeView: View {
    @State private var dontShow: Bool
    let onAction: (WelcomeAction, Bool) -> Void

    init(initialDontShow: Bool, onAction: @escaping (WelcomeAction, Bool) -> Void) {
        self._dontShow = State(initialValue: initialDontShow)
        self.onAction = onAction
    }

    var body: some View {
        ZStack {
            // Mascarpone-to-cream gradient background, with soft warm wash
            // bleeding from the lower-right (matches marketing site hero).
            ZStack {
                LinearGradient(
                    colors: [Brand.mascarpone, Brand.cream],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [Brand.accent.opacity(0.18), .clear],
                    center: UnitPoint(x: 0.85, y: 0.95),
                    startRadius: 30,
                    endRadius: 320
                )
                RadialGradient(
                    colors: [Brand.cocoa.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.1, y: 0.05),
                    startRadius: 20,
                    endRadius: 240
                )
            }
            .ignoresSafeArea()

            VStack(spacing: 22) {
                // Brand mark — app icon, with a soft cocoa-tinted shadow.
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .shadow(color: Brand.cocoa.opacity(0.28), radius: 14, y: 8)
                }

                VStack(spacing: 6) {
                    Text("Tiramisu")
                        .font(.system(size: 44, weight: .heavy, design: .serif))
                        .italic()
                        .tracking(-0.5)
                        .foregroundStyle(Brand.wordmarkGradient)
                        .shadow(color: Brand.cocoa.opacity(0.10), radius: 1, y: 1)

                    Text("A free, AI-native alternative to Photoshop")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.cocoa)
                        .multilineTextAlignment(.center)
                }

                // Metaphor — the line that anchors the brand voice.
                Text("\u{201C}Tiramisu has layers. Image editing has layers.\u{201D}")
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(Brand.cocoaSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                // Pillars — the three things that make Tiramisu Tiramisu.
                HStack(spacing: 8) {
                    PillarChip(label: "FREE", colorA: Brand.cream, colorB: Brand.ladyfinger.opacity(0.6), text: Brand.cocoa)
                    PillarChip(label: "FOR CREATORS", colorA: Brand.accent, colorB: Brand.accentDeep, text: Brand.mascarpone)
                    PillarChip(label: "AI-NATIVE", colorA: Color(red: 0.83, green: 0.69, blue: 0.96), colorB: Color(red: 1.00, green: 0.77, blue: 0.86), text: Brand.espresso)
                }

                Spacer().frame(height: 0)

                // Primary CTA + secondary actions.
                VStack(spacing: 10) {
                    Button { onAction(.getStarted, dontShow) } label: {
                        Text("Get Started")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.mascarpone)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Brand.espresso)
                            .shadow(color: Brand.espresso.opacity(0.30), radius: 8, y: 3)
                    )
                    .keyboardShortcut(.defaultAction)

                    HStack(spacing: 10) {
                        SecondaryButton(label: "Set up Local AI\u{2026}") {
                            onAction(.setupAI, dontShow)
                        }
                        SecondaryButton(label: "Visit Website") {
                            onAction(.visitWebsite, dontShow)
                        }
                    }
                }

                // Don't-show toggle.
                Toggle("Don\u{2019}t show this on startup", isOn: $dontShow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.cocoaSoft)
                    .padding(.top, 4)

                // Footer signature.
                Text("Open source \u{00B7} AGPL-3.0 \u{00B7} Apple Silicon")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Brand.cocoaSoft.opacity(0.7))
                    .tracking(1.2)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(width: 460, height: 580)
        }
    }
}

// MARK: - Subcomponents

private struct PillarChip: View {
    let label: String
    let colorA: Color
    let colorB: Color
    let text: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .heavy, design: .default))
            .tracking(1.4)
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                LinearGradient(colors: [colorA, colorB], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(Brand.cocoa.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Brand.cocoa.opacity(0.10), radius: 2, y: 1)
    }
}

private struct SecondaryButton: View {
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.espresso)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.92 : 0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Brand.cocoa.opacity(hovering ? 0.32 : 0.18), lineWidth: 0.8)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Brand palette (mirrors tiramisu_www CSS variables)

private enum Brand {
    static let espresso  = Color(red: 0.169, green: 0.094, blue: 0.063)  // #2b1810
    static let cocoa     = Color(red: 0.290, green: 0.173, blue: 0.102)  // #4a2c1a
    static let cocoaSoft = Color(red: 0.420, green: 0.290, blue: 0.220)
    static let accent    = Color(red: 0.831, green: 0.510, blue: 0.231)  // #d4823b
    static let accentDeep = Color(red: 0.659, green: 0.380, blue: 0.157) // #a8612a
    static let mascarpone = Color(red: 0.984, green: 0.953, blue: 0.886) // #fbf3e2
    static let cream     = Color(red: 0.961, green: 0.914, blue: 0.831)  // #f5e9d4
    static let ladyfinger = Color(red: 0.784, green: 0.639, blue: 0.439) // #c8a370

    static let wordmarkGradient = LinearGradient(
        colors: [espresso, cocoa, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
