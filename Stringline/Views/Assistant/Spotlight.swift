import SwiftUI

/// Places on screen the assistant can point at when someone asks "where is…?" (see KnowledgeBase.spots).
struct HelpSpotKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as a place the assistant can show with a pulsing ring.
    func helpSpot(_ id: String) -> some View {
        anchorPreference(key: HelpSpotKey.self, value: .bounds) { [id: $0] }
    }
}

/// Draws a pulsing ring and a short label around the spot the assistant is showing. Never blocks clicks.
struct SpotlightLayer: View {
    @Environment(AppStore.self) private var store
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let id = store.assistantSpotlight, let anchor = anchors[id] {
                SpotlightRing(rect: proxy[anchor].insetBy(dx: -6, dy: -6), label: KnowledgeBase.spot(id)?.label ?? "Here", bounds: proxy.size)
                    .id(id)
                    .task(id: id) {
                        try? await Task.sleep(nanoseconds: 9_000_000_000)
                        if store.assistantSpotlight == id { store.assistantSpotlight = nil }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SpotlightRing: View {
    let rect: CGRect
    let label: String
    let bounds: CGSize
    @State private var pulse = false

    var body: some View {
        let below = rect.maxY + 44 < bounds.height
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.accent, lineWidth: 3)
                .frame(width: max(rect.width, 24), height: max(rect.height, 24))
                .shadow(color: Palette.accent.opacity(pulse ? 0.9 : 0.3), radius: pulse ? 16 : 4)
                .scaleEffect(pulse ? 1.04 : 1)
                .position(x: rect.midX, y: rect.midY)
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 11, weight: .bold))
                Text(label.prefix(1).uppercased() + label.dropFirst()).font(.ui(12, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.accent, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .fixedSize()
            .position(x: min(max(rect.midX, 160), bounds.width - 160), y: below ? rect.maxY + 24 : rect.minY - 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The assistant is pointing at \(label)")
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
