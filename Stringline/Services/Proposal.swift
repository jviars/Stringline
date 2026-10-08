import SwiftUI
import MapKit
import AppKit
import PDFKit

// MARK: - Map snapshot with the measured shapes drawn on top

enum MapSnapshot {
    static func make(takeoff: Takeoff, size: CGSize = CGSize(width: 1100, height: 560)) async -> NSImage? {
        let points = takeoff.shapes.flatMap(\.points)
        let region: MKCoordinateRegion
        if !points.isEmpty {
            let lats = points.map(\.lat), lons = points.map(\.lon)
            let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
            let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.5, 0.0008),
                                        longitudeDelta: max((lons.max()! - lons.min()!) * 1.5, 0.0008))
            region = MKCoordinateRegion(center: center, span: span)
        } else if let center = takeoff.center {
            region = MKCoordinateRegion(center: Geo.cl(center), latitudinalMeters: takeoff.spanMeters ?? 300, longitudinalMeters: takeoff.spanMeters ?? 300)
        } else {
            return nil
        }
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        options.pointOfInterestFilter = .excludingAll
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        return NSImage(size: size, flipped: true) { rect in
            snapshot.image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            for shape in takeoff.shapes {
                let color = NSColor(hex: shape.workType.hex)
                let pts = shape.points.map { snapshot.point(for: Geo.cl($0)) }
                switch shape.kind {
                case .area where pts.count >= 3:
                    let path = NSBezierPath()
                    path.windingRule = .evenOdd
                    path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }; path.close()
                    for hole in shape.holes where hole.count >= 3 {
                        let hp = hole.map { snapshot.point(for: Geo.cl($0)) }
                        path.move(to: hp[0]); hp.dropFirst().forEach { path.line(to: $0) }; path.close()
                    }
                    color.withAlphaComponent(0.25).setFill(); path.fill()
                    color.setStroke(); path.lineWidth = 3; path.lineJoinStyle = .round; path.stroke()
                case .line where pts.count >= 2:
                    let path = NSBezierPath()
                    path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }
                    color.setStroke(); path.lineWidth = 4; path.lineCapStyle = .round; path.stroke()
                case .count where !pts.isEmpty:
                    let dot = NSBezierPath(ovalIn: CGRect(x: pts[0].x - 7, y: pts[0].y - 7, width: 14, height: 14))
                    NSColor.white.setFill(); dot.fill()
                    NSColor(hex: 0x17181A).setStroke(); dot.lineWidth = 2; dot.stroke()
                default:
                    break
                }
            }
            return true
        }
    }
}

// MARK: - The proposal itself (two letter-size pages)

struct ProposalContent {
    let company: CompanyInfo
    let logo: NSImage?
    let customer: Customer?
    let job: Job
    let options: [EstimateOption]
    let proposalNumber: String
    let date: Date
    let template: ProposalTemplate
    let map: NSImage?
}

private struct ProposalHeader: View {
    let c: ProposalContent
    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 10) {
                if let logo = c.logo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 48)
                } else {
                    LogoMark(size: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.company.name.isEmpty ? "Your company" : c.company.name).font(.display(18))
                    Text([c.company.phone, c.company.email].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 8.5))
                    if !c.company.address.isEmpty { Text(c.company.address).font(.system(size: 8.5)) }
                    if !c.company.license.isEmpty { Text("License \(c.company.license)").font(.system(size: 8.5)) }
                }
                .foregroundStyle(Palette.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("PROPOSAL").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(Palette.tertiary)
                Text("No. \(c.proposalNumber)").font(.system(size: 10, weight: .semibold))
                Text(Fmt.dayYear(c.date)).font(.system(size: 9.5)).foregroundStyle(Palette.secondary)
            }
        }
    }
}

struct ProposalPageOne: View {
    let c: ProposalContent
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProposalHeader(c: c)
            Rectangle().fill(Palette.ink).frame(height: 1.5)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PREPARED FOR").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
                    Text(c.customer?.name ?? "—").font(.system(size: 11, weight: .semibold))
                    if let contact = c.customer?.contact, !contact.isEmpty { Text(contact).font(.system(size: 9.5)) }
                    if let address = c.customer?.address, !address.isEmpty { Text(address).font(.system(size: 9.5)) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROJECT").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
                    Text(c.job.name).font(.system(size: 11, weight: .semibold))
                    if !c.job.address.isEmpty { Text(c.job.address).font(.system(size: 9.5)) }
                }
                Spacer()
            }
            if let map = c.map {
                Image(nsImage: map).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 532, height: 270).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("SCOPE OF WORK").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
                ForEach(Array(scopeLines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).").font(.system(size: 10, weight: .semibold)).frame(width: 14, alignment: .leading)
                        Text(line).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Continued on page 2").font(.system(size: 8.5)).foregroundStyle(Palette.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(Palette.ink)
        .padding(40)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(.white)
    }

    private var scopeLines: [String] {
        let text = c.options.first?.scope ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct ProposalPageTwo: View {
    let c: ProposalContent
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProposalHeader(c: c)
            Rectangle().fill(Palette.ink).frame(height: 1.5)
            Text(c.options.count > 1 ? "YOUR OPTIONS" : "PRICE").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
            VStack(spacing: 8) {
                ForEach(Array(c.options.enumerated()), id: \.element.id) { index, option in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.options.count > 1 ? "Option \(String(UnicodeScalar(65 + index)!)) · \(option.title)" : option.title)
                                .font(.system(size: 12, weight: .semibold))
                            if c.options.count > 1, index > 0, !option.scope.isEmpty {
                                Text(option.scope.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 9)).foregroundStyle(Palette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        Text(Fmt.dollars(option.breakdown.priceCents)).font(.display(18)).monospacedDigit()
                    }
                    .padding(12)
                    .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text("Prices are good until \(Fmt.dayYear(c.date.adding(days: c.template.validDays))).")
                .font(.system(size: 9.5)).foregroundStyle(Palette.secondary)
            if c.template.escalationClause && !c.template.escalationText.isEmpty {
                section("PRICE ADJUSTMENT", c.template.escalationText)
            }
            if !c.template.exclusions.isEmpty { section("NOT INCLUDED", c.template.exclusions) }
            if !c.template.terms.isEmpty { section("TERMS", c.template.terms) }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 18) {
                Text("ACCEPTANCE").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
                Text(c.options.count > 1 ? "Option chosen:  A  /  B\(c.options.count > 2 ? "  /  C" : "")" : "Signing below accepts this proposal and its terms.")
                    .font(.system(size: 9.5))
                HStack(spacing: 24) {
                    signatureLine("Accepted by")
                    signatureLine("Date")
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(40)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(.white)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
            Text(text).font(.system(size: 9.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signatureLine(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(Palette.ink).frame(height: 1).padding(.top, 22)
            Text(label).font(.system(size: 8)).foregroundStyle(Palette.secondary)
        }
    }
}

@MainActor
enum ProposalRenderer {
    enum RenderError: LocalizedError {
        case cantCreate
        var errorDescription: String? { "Couldn't create the PDF file." }
    }

    static func render(_ content: ProposalContent, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw RenderError.cantCreate }
        let pages: [AnyView] = [AnyView(ProposalPageOne(c: content)), AnyView(ProposalPageTwo(c: content))]
        for page in pages {
            let renderer = ImageRenderer(content: page.environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(width: 612, height: 792)
            renderer.render { _, draw in
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(hex: 0xE6E6E2)
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
