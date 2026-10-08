import SwiftUI

// MARK: - Surfaces

struct CardStyle: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border))
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = 14) -> some View {
        modifier(CardStyle(padding: padding, radius: radius))
    }
}

struct CardHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(15, weight: .bold)).foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle).font(.ui(12)).foregroundStyle(Palette.tertiary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

struct PageHeader<Trailing: View>: View {
    var eyebrow: String?
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow).font(.ui(12.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                Text(title).font(.display(36)).foregroundStyle(Palette.ink)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = EmptyView()
    }
}

// MARK: - Pills and badges

enum Tone {
    case go, noGo, watch, info, neutral, accent, dark

    var colors: (fg: Color, bg: Color) {
        switch self {
        case .go: (Palette.goInk, Palette.goBg)
        case .noGo: (Palette.noGoInk, Palette.noGoBg)
        case .watch: (Palette.watchInk, Palette.watchBg)
        case .info: (Palette.infoInk, Palette.infoBg)
        case .neutral: (Color(hex: 0x3F4249), Palette.chip)
        case .accent: (Palette.ink, Palette.accent)
        case .dark: (.white, Palette.ink)
        }
    }

    init(_ level: GoLevel) {
        switch level {
        case .go, .goLater: self = .go
        case .watch: self = .watch
        case .noGo: self = .noGo
        }
    }
}

struct Pill: View {
    let text: String
    var tone: Tone = .neutral
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .heavy)) }
            Text(text).font(.ui(11.5, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(tone.colors.fg)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(tone.colors.bg, in: Capsule())
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.ui(11.5))
            .foregroundStyle(Color(hex: 0x3F4249))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct KeyCap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.ui(11.5, weight: .bold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: 0xDCDCD7)))
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(large ? 15 : 13, weight: .bold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, large ? 22 : 14)
            .frame(height: large ? 46 : 34)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous).strokeBorder(.black.opacity(0.08)))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(large ? 14 : 13, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, large ? 18 : 13)
            .frame(height: large ? 44 : 34)
            .background(configuration.isPressed ? Palette.chip : Palette.surface, in: RoundedRectangle(cornerRadius: large ? 11 : 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: large ? 11 : 9, style: .continuous).strokeBorder(Color(hex: 0xDCDCD7)))
            .contentShape(Rectangle())
    }
}

struct DarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Palette.ink.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12.5, weight: .semibold))
            .foregroundStyle(Palette.amberInk.opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Rectangle())
    }
}

struct SmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(configuration.isPressed ? Palette.chip : Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(hex: 0xDCDCD7)))
            .contentShape(Rectangle())
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Fields

struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var height: CGFloat = 36
    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.control))
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.ui(12.5, weight: .semibold)).foregroundStyle(Color(hex: 0x3F4249))
                if let hint { Text("· \(hint)").font(.ui(12.5)).foregroundStyle(Palette.tertiary) }
            }
            content
        }
    }
}

struct TextBox: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var hint: String?
    /// Apple Maps suggestions as you type, for address fields.
    var suggestsAddresses = false

    var body: some View {
        LabeledField(label: label, hint: hint) {
            FieldBox {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(13.5))
                    .accessibilityLabel(label)
                    .addressSuggestions($text, enabled: suggestsAddresses)
            }
        }
    }
}

struct NumberBox: View {
    let label: String
    @Binding var value: Double
    var unit: String = ""
    var prefix: String = ""
    var decimals = 0

    var body: some View {
        LabeledField(label: label) {
            FieldBox {
                if !prefix.isEmpty { Text(prefix).foregroundStyle(Palette.tertiary) }
                TextField(label, value: $value, format: .number.precision(.fractionLength(0...max(decimals, 2))))
                    .textFieldStyle(.plain)
                    .font(.ui(13.5, weight: .semibold))
                    .monospacedDigit()
                    .labelsHidden()
                if !unit.isEmpty { Text(unit).font(.ui(12)).foregroundStyle(Palette.tertiary).fixedSize() }
            }
        }
    }
}

/// Edits whole cents as dollars.
struct MoneyInput: View {
    @Binding var cents: Int
    var label = "Price"
    var width: CGFloat? = nil

    var body: some View {
        FieldBox(content: {
            Text("$").foregroundStyle(Palette.tertiary)
            TextField(label, value: Binding(
                get: { Double(cents) / 100 },
                set: { cents = Int(($0 * 100).rounded()) }
            ), format: .number.precision(.fractionLength(2)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.ui(13, weight: .semibold))
            .monospacedDigit()
            .labelsHidden()
            .accessibilityLabel(label)
        }, height: 30)
        .frame(width: width)
    }
}

// MARK: - Brand

struct RoadMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let o = CGPoint(x: rect.midX - 12 * s, y: rect.midY - 12 * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        path.move(to: p(4, 20)); path.addLine(to: p(10, 4))
        path.move(to: p(20, 20)); path.addLine(to: p(14, 4))
        path.move(to: p(12, 19)); path.addLine(to: p(12, 16))
        path.move(to: p(12, 12.5)); path.addLine(to: p(12, 10))
        path.move(to: p(12, 7)); path.addLine(to: p(12, 5.5))
        return path
    }
}

struct LogoMark: View {
    var size: CGFloat = 34
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Palette.accent)
            .frame(width: size, height: size)
            .overlay(
                RoadMark()
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                    .padding(size * 0.12)
            )
            .accessibilityHidden(true)
    }
}

/// Two stakes, flagging tape, a taut line and a line level. The app's signature drawing.
struct StringlineArt: View {
    var lineColor: Color = Palette.accent
    var levelBody: Color = Color(hex: 0xE6E7E9)
    var ground: Color? = Color(hex: 0x2A2B30)

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stakeW = max(10, h * 0.14), lineY = h * 0.32
            if let ground {
                ctx.fill(Path(CGRect(x: 0, y: h - 2, width: w, height: 2)), with: .color(ground))
            }
            for left in [true, false] {
                let x = left ? w * 0.022 : w - w * 0.022 - stakeW
                var stake = Path()
                stake.move(to: CGPoint(x: x, y: h * 0.1))
                stake.addLine(to: CGPoint(x: x + stakeW, y: h * 0.1))
                stake.addLine(to: CGPoint(x: x + stakeW, y: h * 0.86))
                stake.addLine(to: CGPoint(x: x + stakeW / 2, y: h * 0.97))
                stake.addLine(to: CGPoint(x: x, y: h * 0.86))
                stake.closeSubpath()
                ctx.fill(stake, with: .color(Palette.wood))
                ctx.fill(Path(CGRect(x: left ? x : x + stakeW * 0.7, y: h * 0.1, width: stakeW * 0.3, height: h * 0.76)),
                         with: .color(left ? Color(hex: 0xC9A06A) : Palette.woodShade))
                let tapeX = left ? x + stakeW : x
                let dir: CGFloat = left ? 1 : -1
                var tape = Path()
                tape.move(to: CGPoint(x: tapeX, y: h * 0.17))
                tape.addCurve(to: CGPoint(x: tapeX + dir * stakeW * 2.6, y: h * 0.21),
                              control1: CGPoint(x: tapeX + dir * stakeW * 1.1, y: h * 0.12),
                              control2: CGPoint(x: tapeX + dir * stakeW * 1.6, y: h * 0.26))
                tape.addLine(to: CGPoint(x: tapeX + dir * stakeW * 2.45, y: h * 0.3))
                tape.addCurve(to: CGPoint(x: tapeX, y: h * 0.27),
                              control1: CGPoint(x: tapeX + dir * stakeW * 1.5, y: h * 0.33),
                              control2: CGPoint(x: tapeX + dir * stakeW * 1.0, y: h * 0.24))
                tape.closeSubpath()
                ctx.fill(tape, with: .color(Palette.flagging))
            }
            let startX = w * 0.022 + stakeW, endX = w - w * 0.022 - stakeW
            ctx.stroke(Path { $0.move(to: CGPoint(x: startX, y: lineY)); $0.addLine(to: CGPoint(x: endX, y: lineY)) },
                       with: .color(lineColor), lineWidth: max(2, h * 0.025))
            let lw = max(40, h * 0.5), lh = max(13, h * 0.15)
            let level = CGRect(x: w / 2 - lw / 2, y: lineY + 3, width: lw, height: lh)
            ctx.fill(Path(roundedRect: level, cornerRadius: lh / 2), with: .color(levelBody))
            let vial = level.insetBy(dx: lw * 0.22, dy: lh * 0.2)
            ctx.fill(Path(roundedRect: vial, cornerRadius: vial.height / 2), with: .color(Palette.vial))
            ctx.fill(Path(ellipseIn: CGRect(x: level.midX - vial.height * 0.6, y: vial.midY - vial.height * 0.32,
                                            width: vial.height * 1.2, height: vial.height * 0.64)), with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}

/// Progress drawn as a string line with a level riding along it.
struct StakeProgress: View {
    var fraction: Double
    var track: Color = Palette.asphaltRule

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let inner = max(0, w - 18)
            let x = 9 + inner * min(max(fraction, 0), 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.wood).frame(width: 9, height: 32)
                RoundedRectangle(cornerRadius: 2).fill(Palette.wood).frame(width: 9, height: 32).offset(x: w - 9)
                Rectangle().fill(Palette.flagging).frame(width: 14, height: 6).offset(x: 9, y: 4)
                Rectangle().fill(track).frame(width: inner, height: 2).offset(x: 9, y: 12)
                Rectangle().fill(Palette.accent).frame(width: max(0, x - 9), height: 2).offset(x: 9, y: 12)
                Capsule().fill(Color(hex: 0xE6E7E9)).frame(width: 32, height: 14)
                    .overlay(Capsule().fill(Palette.vial).frame(width: 18, height: 8)
                        .overlay(Ellipse().fill(.white).frame(width: 7, height: 4)))
                    .offset(x: x - 16, y: 6)
            }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }
}

// MARK: - Empty states

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var tint: Tone = .neutral

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint.colors.fg)
                .frame(width: 48, height: 48)
                .background(tint.colors.bg, in: Circle())
            Text(title).font(.ui(15, weight: .bold)).foregroundStyle(Palette.ink).padding(.top, 4)
            Text(message)
                .font(.ui(13))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct IconTile: View {
    let systemName: String
    var tone: Tone = .neutral
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tone.colors.fg)
            .frame(width: size, height: size)
            .background(tone.colors.bg, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct StatBlock: View {
    let label: String
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.ui(12)).foregroundStyle(Palette.secondary)
            Text(value).font(.display(30)).foregroundStyle(Palette.ink).monospacedDigit()
            if let note { Text(note).font(.ui(12)).foregroundStyle(Palette.tertiary) }
        }
    }
}

extension Stage {
    var dotColor: Color {
        switch self {
        case .lead: Palette.sidebarMuted
        case .siteVisit: Palette.blue
        case .estimating: Palette.accent
        case .sent: Color(hex: 0xE8710A)
        case .won: Color(hex: 0x17804A)
        case .lost: Color(hex: 0xB42318)
        }
    }
}

/// Thin horizontal rule. Use instead of Divider() inside overlays, where Divider can turn vertical.
struct Hairline: View {
    var body: some View { Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true) }
}

/// Thin vertical rule between side-by-side stats.
struct VRule: View {
    var body: some View { Rectangle().fill(Palette.hairline).frame(width: 1).accessibilityHidden(true) }
}
