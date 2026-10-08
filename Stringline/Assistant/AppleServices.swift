import Foundation
import AppKit
import MapKit
import AVFoundation
import UserNotifications
import UniformTypeIdentifiers

/// Opens jobs in Apple Maps.
@MainActor
enum MapsLink {
    static func canOpen(_ job: Job) -> Bool {
        job.latitude != nil || !job.address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func open(_ job: Job, directions: Bool) {
        let coordinate = job.latitude.flatMap { lat in job.longitude.map { Coordinate(lat: lat, lon: $0) } }
        open(name: job.name, address: job.address, coordinate: coordinate, directions: directions)
    }

    static func open(name: String, address: String, coordinate: Coordinate?, directions: Bool) {
        let options: [String: Any] = directions ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving] : [:]
        if let coordinate {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: Geo.cl(coordinate)))
            item.name = name
            item.openInMaps(launchOptions: options)
            return
        }
        var components = URLComponents(string: "maps://")!
        components.queryItems = [URLQueryItem(name: directions ? "daddr" : "q", value: address.isEmpty ? name : address)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

/// The parts of the assistant that ask Apple's services: drive times and place search, through MapKit.
@MainActor
final class AppleServices: AssistantServices {
    func driveTime(from: Coordinate, to: Coordinate) async throws -> DriveInfo {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: Geo.cl(from)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: Geo.cl(to)))
        request.transportType = .automobile
        let eta = try await MKDirections(request: request).calculateETA()
        return DriveInfo(minutes: eta.expectedTravelTime / 60, miles: eta.distance / 1609.344)
    }

    func findPlaces(_ query: String, near: Coordinate?) async -> [PlaceFound] {
        await Places.search(query, near: near).map { PlaceFound(name: $0.name, address: $0.detail, coordinate: $0.coordinate) }
    }

    func mapPicture(_ frame: MapFrame, shapes: [TakeoffShape]) async throws -> String {
        let options = MKMapSnapshotter.Options()
        let origin = frame.origin
        options.mapRect = MKMapRect(x: origin.x, y: origin.y, width: frame.size, height: frame.size)
        options.size = CGSize(width: MapPicture.side, height: MapPicture.side)
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        let snapshot = try await MKMapSnapshotter(options: options).start()
        return try MapPicture.dataURL(snapshot.image, frame: frame, shapes: shapes)
    }
}

/// The picture look_at_map hands the model: the satellite view with a labeled 0–1000 grid,
/// and the shapes already measured drawn in their work colors.
@MainActor
enum MapPicture {
    static let side: CGFloat = 1024

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "Apple Maps couldn't make a picture of the lot." }
    }

    static func dataURL(_ image: NSImage, frame: MapFrame, shapes: [TakeoffShape]) throws -> String {
        guard let data = draw(image, frame: frame, shapes: shapes) else { throw Failure() }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    static func draw(_ image: NSImage, frame: MapFrame, shapes: [TakeoffShape]) -> Data? {
        let px = Int(side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // Flipped, so y grows downward like the grid.
        let context = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
        context.cgContext.translateBy(x: 0, y: side)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let all = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor.black.setFill()
        all.fill()
        image.draw(in: all, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        func point(_ c: Coordinate) -> NSPoint {
            let g = frame.gridPoint(c)
            return NSPoint(x: g.x / MapFrame.grid * side, y: g.y / MapFrame.grid * side)
        }

        // Shapes already measured.
        for shape in shapes {
            let color = NSColor(hex: shape.workType.hex)
            switch shape.kind {
            case .area where shape.points.count >= 3:
                let path = NSBezierPath()
                path.windingRule = .evenOdd
                for ring in [shape.points] + shape.holes where ring.count >= 3 {
                    path.move(to: point(ring[0]))
                    for c in ring.dropFirst() { path.line(to: point(c)) }
                    path.close()
                }
                color.withAlphaComponent(0.2).setFill()
                path.fill()
                color.setStroke()
                path.lineWidth = 3
                path.stroke()
                label(TakeoffShapeLabel.text(shape), at: point(Geo.centroid(shape.points)), color: color)
            case .line where shape.points.count >= 2:
                let path = NSBezierPath()
                path.move(to: point(shape.points[0]))
                for c in shape.points.dropFirst() { path.line(to: point(c)) }
                color.setStroke()
                path.lineWidth = 4
                path.stroke()
                label(TakeoffShapeLabel.text(shape), at: point(shape.points[shape.points.count / 2]), color: color)
            case .count:
                for c in shape.points {
                    let p = point(c)
                    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                    color.setFill()
                    dot.fill()
                }
            default:
                break
            }
        }

        // The grid: a line every 100, with its number at the top and left edges.
        for i in 1..<10 {
            let at = CGFloat(i) / 10 * side
            for (width, shade) in [(CGFloat(3), NSColor.black.withAlphaComponent(0.35)), (CGFloat(1), NSColor.white.withAlphaComponent(0.7))] {
                shade.setStroke()
                let v = NSBezierPath()
                v.move(to: NSPoint(x: at, y: 0))
                v.line(to: NSPoint(x: at, y: side))
                v.lineWidth = width
                v.stroke()
                let h = NSBezierPath()
                h.move(to: NSPoint(x: 0, y: at))
                h.line(to: NSPoint(x: side, y: at))
                h.lineWidth = width
                h.stroke()
            }
            let number = "\(i * 100)"
            tag(number, at: NSPoint(x: at + 3, y: 3))
            tag(number, at: NSPoint(x: 3, y: at + 3))
        }
        context.flushGraphics()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private static func tag(_ text: String, at point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x - 2, y: point.y - 1, width: size.width + 4, height: size.height + 2), xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    private static func label(_ text: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4), xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// What a measured shape is called on the map picture.
enum TakeoffShapeLabel {
    static func text(_ shape: TakeoffShape) -> String {
        if !shape.name.isEmpty { return shape.name }
        return shape.kind == .count ? shape.countKind.label : shape.workType.label
    }
}

/// Opens a Messages draft. Stringline never sends a text itself.
@MainActor
enum MessagesDraft {
    static func compose(to phone: String?, body: String) {
        if let service = NSSharingService(named: .composeMessage) {
            if let phone, !phone.isEmpty { service.recipients = [phone] }
            if service.canPerform(withItems: [body]) {
                service.perform(withItems: [body])
                return
            }
        }
        let digits = (phone ?? "").filter { $0.isNumber || $0 == "+" }
        var components = URLComponents(string: "sms:\(digits)")!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

/// Reads replies out loud with the system voice.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()
    var onChange: ((UUID?) -> Void)?
    private(set) var speakingID: UUID?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String, id: UUID) {
        if speakingID == id {
            stop()
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
        synthesizer.speak(AVSpeechUtterance(string: plain))
        speakingID = id
        onChange?(id)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
        onChange?(nil)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingID = nil
            self.onChange?(nil)
        }
    }
}

/// A notification when the assistant finishes while Stringline is in the background.
@MainActor
enum Notifier {
    static func finished(_ text: String) {
        guard !NSApp.isActive else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Stringline assistant"
            content.body = text
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// macOS Dictation in whatever text field has focus.
@MainActor
enum Dictation {
    static func start() {
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    }
}

/// Turns files people drop or pick into something the assistant can look at.
enum AttachmentMaker {
    static let maxPDFBytes = 10 * 1024 * 1024
    static let maxImageSide: CGFloat = 1600

    enum Problem: Error, LocalizedError {
        case unsupported(String), tooBig(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "\(name) isn't a picture or a PDF."
            case .tooBig(let name): "\(name) is bigger than 10 MB."
            case .unreadable(let name): "\(name) couldn't be read."
            }
        }
    }

    static func make(from url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            guard let data = try? Data(contentsOf: url) else { throw Problem.unreadable(name) }
            guard data.count <= maxPDFBytes else { throw Problem.tooBig(name) }
            return Attachment(name: name, kind: .pdf, dataURL: "data:application/pdf;base64,\(data.base64EncodedString())", preview: nil)
        }
        guard type?.conforms(to: .image) == true else { throw Problem.unsupported(name) }
        guard let image = NSImage(contentsOf: url) else { throw Problem.unreadable(name) }
        return try make(image: image, name: name)
    }

    static func make(image: NSImage, name: String) throws -> Attachment {
        guard let full = jpeg(image, maxSide: maxImageSide, quality: 0.8) else { throw Problem.unreadable(name) }
        let thumb = jpeg(image, maxSide: 160, quality: 0.7)
        return Attachment(name: name, kind: .image, dataURL: "data:image/jpeg;base64,\(full.base64EncodedString())", preview: thumb)
    }

    static func jpeg(_ image: NSImage, maxSide: CGFloat, quality: Double) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
