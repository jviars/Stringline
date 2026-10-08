import SwiftUI

enum TourStop: Int, CaseIterable, Identifiable {
    case today, pipeline, measure, estimate, schedule, settings

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }
    var anchor: String { "tour.\(rawValue)" }
    var next: TourStop? { TourStop(rawValue: rawValue + 1) }
    var previous: TourStop? { TourStop(rawValue: rawValue - 1) }

    var shortName: String {
        switch self {
        case .today: "Today"
        case .pipeline: "Pipeline"
        case .measure: "Measure"
        case .estimate: "Estimate"
        case .schedule: "Schedule"
        case .settings: "Settings"
        }
    }

    var title: String {
        switch self {
        case .today: "Start every morning here"
        case .pipeline: "Every bid on one board"
        case .measure: "Outline the pavement"
        case .estimate: "Set your price with one slider"
        case .schedule: "Plan around the weather"
        case .settings: "Your numbers, your rules"
        }
    }

    var body: String {
        switch self {
        case .today:
            "Today shows go / no-go weather for the next three days, which crew is where, and anything that needs you, like rain on a job day or a bid nobody answered."
        case .pipeline:
            "Drag a card to the next column as a job moves along. When a bid goes quiet for a week, it gets a Follow up tag so nothing slips through."
        case .measure:
            "Pick the Area tool, then click each corner of the lot. Press Return to close the shape. Stringline works out the square feet, square yards and tons for you."
        case .estimate:
            "Your measurements fill in the line items. Drag Profit and watch the bid price, price per square yard and margin change."
        case .schedule:
            "Every day is checked against your weather rules. When rain or cold lands on a booked job, its card turns red so you can move it before the crew rolls out."
        case .settings:
            "Rates, markup, weather rules and your proposal wording all live here. Change a number and every new estimate uses it. Bids you've already sent keep their numbers."
        }
    }

    var tip: String? {
        switch self {
        case .today: "Press ⌘K from anywhere to jump to a job or customer."
        case .measure: "Shortcuts: A area, L line, C count, X cut out, Esc cancel."
        case .estimate: "Try it now: drag the Profit slider."
        default: nil
        }
    }
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks the view the tour should spotlight at this stop.
    func tourAnchor(_ stop: TourStop) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [stop.anchor: $0] }
    }
}

private struct DimShape: Shape {
    var hole: CGRect?
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: 16, height: 16))
        }
        return path
    }
}

struct TourLayer: View {
    @Environment(AppStore.self) private var store
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let stop = store.tourStop {
                let target = anchors[stop.anchor].map { proxy[$0] }
                ZStack(alignment: .topLeading) {
                    DimShape(hole: target?.insetBy(dx: -8, dy: -8))
                        .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    if let target {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.accent, lineWidth: 3)
                            .frame(width: target.width + 16, height: target.height + 16)
                            .position(x: target.midX, y: target.midY)
                            .allowsHitTesting(false)
                    }
                    TourCallout(stop: stop)
                        .frame(width: 372)
                        .position(Self.calloutCenter(target: target, in: proxy.size))
                }
                .animation(.easeInOut(duration: 0.25), value: stop)
            }
        }
    }

    static func calloutCenter(target: CGRect?, in size: CGSize) -> CGPoint {
        let w: CGFloat = 372, h: CGFloat = 270, gap: CGFloat = 24
        guard let t = target else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, w / 2 + 16), size.width - w / 2 - 16) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, h / 2 + 16), size.height - h / 2 - 16) }
        if t.maxY + gap + h < size.height - 16 {
            return CGPoint(x: clampX(t.minX + w / 2), y: t.maxY + gap + h / 2)
        }
        if t.minX - gap - w > 16 {
            return CGPoint(x: t.minX - gap - w / 2, y: clampY(t.minY + h / 2))
        }
        if t.maxX + gap + w < size.width - 16 {
            return CGPoint(x: t.maxX + gap + w / 2, y: clampY(t.minY + h / 2))
        }
        return CGPoint(x: clampX(t.midX), y: clampY(t.minY - gap - h / 2))
    }
}

struct TourCallout: View {
    @Environment(AppStore.self) private var store
    let stop: TourStop

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TOUR · STOP \(stop.number) OF \(TourStop.allCases.count)")
                    .font(.eyebrow).tracking(0.8).foregroundStyle(Palette.tertiary)
                Spacer()
                Button {
                    store.endTour(completed: false)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondary)
                .help("End the tour")
                .accessibilityLabel("End the tour")
            }
            Text(stop.title)
                .font(.display(26))
                .foregroundStyle(Palette.ink)
                .padding(.top, 2)
            Text(stop.body)
                .font(.ui(13.5))
                .foregroundStyle(Color(hex: 0x3F4249))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let tip = stop.tip {
                Text(tip)
                    .font(.ui(12.5, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .padding(.top, 10)
            }
            Divider().padding(.top, 14)
            HStack(spacing: 5) {
                ForEach(TourStop.allCases) { s in
                    Capsule()
                        .fill(s == stop ? Palette.accent : (s.rawValue < stop.rawValue ? Palette.ink : Palette.control))
                        .frame(width: s == stop ? 20 : 7, height: 7)
                }
                Spacer()
                if let previous = stop.previous {
                    Button("Back") { store.goTo(previous) }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Skip tour") { store.endTour(completed: false) }
                        .buttonStyle(.plain)
                        .font(.ui(13, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                if let next = stop.next {
                    Button {
                        store.goTo(next)
                    } label: {
                        Label("Next: \(next.shortName)", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(DarkButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button {
                        store.endTour(completed: true)
                    } label: {
                        Label("Finish tour", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.top, 14)
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        .onExitCommand { store.endTour(completed: false) }
    }
}
