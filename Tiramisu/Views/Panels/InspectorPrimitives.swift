import SwiftUI

// MARK: - Section

/// Disclosure-style section for the inspector. Replaces the old
/// `SectionDisclosure` with a Tahoe-native header (title-case + medium
/// weight + soft hairline) and a glass-tinted content area.
///
/// Open/closed state persists per-title in UserDefaults so the user's
/// expand/collapse choices survive app restarts.
struct InspectorSection<Content: View>: View {
    let title: String
    let defaultOpen: Bool
    @ViewBuilder let content: () -> Content

    @AppStorage private var open: Bool

    init(_ title: String, defaultOpen: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.defaultOpen = defaultOpen
        self.content = content
        let key = "ai.taiso.tiramisu.section.\(title)"
        self._open = AppStorage(wrappedValue: defaultOpen, key)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    content()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }

            Divider().opacity(0.4)
        }
    }
}

// MARK: - Row

/// Single inspector row: a fixed-width label column followed by a
/// trailing control. Using this everywhere produces a clean baseline
/// alignment across the whole inspector regardless of which panel you're in.
struct InspectorRow<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ label: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: InspectorMetrics.labelWidth, alignment: .leading)
                .lineLimit(1)
            trailing()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Slider with readout

/// Slider with a fixed-width monospaced value readout on the right.
/// Single source of truth for slider chrome — every panel uses this so
/// every slider in the inspector has a readout, and they all align.
struct InspectorSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: ValueFormat
    let onCommit: () -> Void

    enum ValueFormat {
        case integer                   // 32
        case signedInteger             // +5 / -3
        case percent                   // 75%
        case decimal(_ places: Int)    // 1.4
        case degrees                   // 180°

        func string(for v: Double) -> String {
            switch self {
            case .integer:        return "\(Int(v.rounded()))"
            case .signedInteger:  return String(format: "%+d", Int(v.rounded()))
            case .percent:        return "\(Int((v * 100).rounded()))%"
            case .decimal(let p): return String(format: "%.\(p)f", v)
            case .degrees:        return "\(Int(v.rounded()))°"
            }
        }

        var readoutWidth: CGFloat {
            switch self {
            case .integer:       return 32
            case .signedInteger: return 30
            case .percent:       return 38
            case .decimal:       return 36
            case .degrees:       return 38
            }
        }
    }

    init(_ value: Binding<Double>, in range: ClosedRange<Double>, format: ValueFormat = .integer, onCommit: @escaping () -> Void = {}) {
        self._value = value
        self.range = range
        self.format = format
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range)
                .controlSize(.small)
                .onChange(of: value) { onCommit() }
            Text(format.string(for: value))
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: format.readoutWidth, alignment: .trailing)
        }
    }
}

// MARK: - Color well

/// Color picker sized and styled for the inspector. Also accepts a
/// `ColorRGB` get/set convenience binding so the panels don't have to
/// keep open-coding the conversion.
struct InspectorColorWell: View {
    @Binding var color: Color
    var help: String?

    init(color: Binding<Color>, help: String? = nil) {
        self._color = color
        self.help = help
    }

    var body: some View {
        ColorPicker("", selection: $color, supportsOpacity: true)
            .labelsHidden()
            .frame(width: 44, alignment: .leading)
            .help(help ?? "")
    }
}

// MARK: - Style toggle (B / I / U / S)

/// Square pill toggle that actually shows on/off state. Used for the
/// rich-text bold/italic/underline/strike controls.
struct InspectorStyleToggle: View {
    let symbol: String
    let help: String
    @Binding var isOn: Bool

    init(_ symbol: String, help: String, isOn: Binding<Bool>) {
        self.symbol = symbol
        self.help = help
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(help)
    }
}

// MARK: - Footnote

/// Tertiary helper text used at the bottom of panels for tips/explanations.
/// Centralized so the styling is consistent across panels.
struct InspectorFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Metrics

enum InspectorMetrics {
    static let labelWidth: CGFloat = 72
    static let rowSpacing: CGFloat = 8
}
