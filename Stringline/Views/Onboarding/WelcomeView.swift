import SwiftUI

struct WelcomeView: View {
    var start: () -> Void
    var openExisting: () -> Void

    var body: some View {
        ZStack {
            Palette.asphalt
            AggregateTexture()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    LogoMark(size: 40)
                    Text("WELCOME TO").font(.ui(13, weight: .bold)).tracking(1.3).foregroundStyle(Palette.onDarkMuted)
                }
                Text("Stringline")
                    .font(.display(128))
                    .foregroundStyle(.white)
                    .padding(.top, 10)
                StringlineArt()
                    .frame(height: 96)
                    .padding(.top, 6)
                Text("Measure lots from satellite, price bids in minutes, and keep every crew on a schedule that knows the weather.")
                    .font(.ui(20))
                    .foregroundStyle(Color(hex: 0xD4D5D8))
                    .lineSpacing(4)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.top, 22)
                HStack(spacing: 24) {
                    Button(action: start) {
                        Label("Get started", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                    Button("I already use Stringline on another Mac", action: openExisting)
                        .buttonStyle(.plain)
                        .font(.ui(14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xE6E7E9))
                        .underline(true, color: Color(hex: 0x5A5C62))
                }
                .padding(.top, 30)
                Divider().overlay(Palette.asphaltActive).padding(.top, 52)
                HStack(alignment: .top, spacing: 36) {
                    feature("square.dashed", "Measure from satellite", "Outline a lot and get square yards and tons.")
                    feature("doc.text", "Bids in minutes", "Measurements flow straight into a priced proposal.")
                    feature("cloud.sun", "Weather-smart schedule", "Go or no-go for every crew, every day.")
                }
                .padding(.top, 24)
                Text("No account needed. Your jobs are ordinary files in a folder you own.")
                    .font(.ui(12.5))
                    .foregroundStyle(Palette.sidebarMuted)
                    .padding(.top, 22)
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 48)
        }
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 38, height: 38)
                .background(Palette.asphaltField, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(14, weight: .bold)).foregroundStyle(.white)
                Text(text).font(.ui(13)).foregroundStyle(Palette.onDarkMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Faint speckle, like aggregate in fresh asphalt.
struct AggregateTexture: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x5EED
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(1 << 31)
            }
            let count = Int(size.width * size.height / 900)
            for _ in 0..<count {
                let x = next() * size.width, y = next() * size.height
                let r = 0.5 + next() * 1.2
                let light = next() > 0.3
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                         with: .color(light ? .white.opacity(0.03 + next() * 0.04) : .black.opacity(0.35)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
