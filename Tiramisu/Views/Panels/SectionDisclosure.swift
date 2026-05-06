import SwiftUI

/// Disclosure-group section used throughout the inspector. Persists the
/// open/closed state per-title in UserDefaults so the user's expand/collapse
/// choices survive app restarts.
struct SectionDisclosure<Content: View>: View {
    let title: String
    let defaultOpen: Bool
    @ViewBuilder let content: () -> Content

    @AppStorage private var open: Bool

    init(title: String, defaultOpen: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.defaultOpen = defaultOpen
        self.content = content
        // Per-title persistence key; namespaced under the bundle prefix.
        let key = "world.hanley.tiramisu.section.\(title)"
        self._open = AppStorage(wrappedValue: defaultOpen, key)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.bounce, value: open)
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            Divider()
        }
    }
}
