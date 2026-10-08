import SwiftUI
import MapKit
import AppKit

enum MeasureTool: String, CaseIterable, Identifiable {
    case select, area, line, count, cut
    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: "Select"
        case .area: "Area"
        case .line: "Line"
        case .count: "Count"
        case .cut: "Cut out"
        }
    }
    var key: String {
        switch self {
        case .select: "V"
        case .area: "A"
        case .line: "L"
        case .count: "C"
        case .cut: "X"
        }
    }
    var icon: String {
        switch self {
        case .select: "cursorarrow"
        case .area: "pentagon"
        case .line: "line.diagonal"
        case .count: "number.circle"
        case .cut: "scissors"
        }
    }
    var hint: String {
        switch self {
        case .select: "Select: click a shape to edit it, drag its corners to adjust"
        case .area: "Area: click each corner, then press Return to close the shape"
        case .line: "Line: click along the line, then press Return to finish"
        case .count: "Count: click to drop a marker for stalls, ADA spots or arrows"
        case .cut: "Cut out: outline an island or building inside an area, then press Return"
        }
    }
}

struct FlyTo: Equatable {
    let id = UUID()
    let center: Coordinate
    let spanMeters: Double
}

// MARK: - Annotations

final class VertexAnnotation: MKPointAnnotation {
    let shapeID: UUID
    let ring: Int   // 0 = outline, 1... = holes
    let index: Int
    init(shapeID: UUID, ring: Int, index: Int, coordinate: CLLocationCoordinate2D) {
        self.shapeID = shapeID
        self.ring = ring
        self.index = index
        super.init()
        self.coordinate = coordinate
    }
}

final class DraftPointAnnotation: MKPointAnnotation {}

final class LabelAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let text: String
    let color: NSColor
    let shapeID: UUID
    init(coordinate: CLLocationCoordinate2D, text: String, color: NSColor, shapeID: UUID) {
        self.coordinate = coordinate
        self.text = text
        self.color = color
        self.shapeID = shapeID
    }
}

final class CountAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let shape: TakeoffShape
    let selected: Bool
    init(shape: TakeoffShape, selected: Bool) {
        self.coordinate = Geo.cl(shape.points.first ?? Coordinate(lat: 0, lon: 0))
        self.shape = shape
        self.selected = selected
    }
}

/// A corner handle that follows the mouse and reports where it was dropped.
/// Handles its own mouse events, since MapKit's built-in annotation dragging is unreliable on the Mac.
final class VertexView: MKAnnotationView {
    weak var mapView: MKMapView?
    var onDragging: ((Bool) -> Void)?
    var onMoved: ((VertexAnnotation) -> Void)?
    private var moved = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// A corner can be dragged straight away, even when Stringline isn't the front window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        moved = false
        onDragging?(true)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let map = mapView, let vertex = annotation as? VertexAnnotation else { return }
        let point = map.convert(event.locationInWindow, from: nil)
        vertex.coordinate = map.convert(point, toCoordinateFrom: map)
        moved = true
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        onDragging?(false)
        if moved, let vertex = annotation as? VertexAnnotation { onMoved?(vertex) }
        moved = false
    }
}

// MARK: - Images for annotations

enum MapImages {
    static func dot(_ diameter: CGFloat, fill: NSColor, stroke: NSColor, width: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter + width * 2, height: diameter + width * 2), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: width, dy: width))
            fill.setFill(); path.fill()
            stroke.setStroke(); path.lineWidth = width; path.stroke()
            return true
        }
    }

    static let vertex = dot(12, fill: .white, stroke: NSColor(hex: 0x17181A), width: 2.5)
    static let draftPoint = dot(9, fill: .white, stroke: NSColor(hex: 0xFFC21A), width: 2)

    static func pill(_ text: String, color: NSColor) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let h: CGFloat = 26
        let w = ceil(size.width) + 26
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: h / 2 - 1, yRadius: h / 2 - 1)
            NSColor(hex: 0x17181A, alpha: 0.92).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 2
            path.stroke()
            (text as NSString).draw(at: NSPoint(x: 13, y: (h - size.height) / 2), withAttributes: attrs)
            return true
        }
    }

    static func count(_ shape: TakeoffShape, selected: Bool) -> NSImage {
        let text = shape.quantity > 1 ? "\(shape.quantity)" : shortLabel(shape.countKind)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(hex: 0x17181A),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let d = max(24, ceil(size.width) + 12)
        return NSImage(size: NSSize(width: d + 4, height: 28), flipped: false) { rect in
            let body = NSRect(x: 2, y: 2, width: d, height: 24)
            let path = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
            (shape.countKind == .ada ? NSColor(hex: 0x9DC0FF) : NSColor.white).setFill()
            path.fill()
            (selected ? NSColor(hex: 0xFFC21A) : NSColor(hex: 0x17181A)).setStroke()
            path.lineWidth = selected ? 3 : 2
            path.stroke()
            (text as NSString).draw(at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2), withAttributes: attrs)
            return true
        }
    }

    static func shortLabel(_ kind: CountKind) -> String {
        switch kind {
        case .stall: "1"
        case .ada: "ADA"
        case .arrow: "→"
        case .other: "•"
        }
    }
}

// MARK: - Map view

struct MapCanvas: NSViewRepresentable {
    var takeoff: Takeoff
    var draft: [Coordinate]
    var draftIsArea: Bool
    var selectedID: UUID?
    var tool: MeasureTool
    var startCenter: Coordinate?
    var startSpan: Double
    var flyTo: FlyTo?
    /// The assistant's drawing waiting for Apply, shown dashed.
    var preview: [TakeoffShape] = []
    var onClick: (Coordinate) -> Void
    var onSelect: (UUID?) -> Void
    var onMoveVertex: (UUID, Int, Int, Coordinate) -> Void
    var onRegionChange: (Coordinate, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        map.showsZoomControls = true
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = context.coordinator
        map.addGestureRecognizer(click)
        if let center = startCenter {
            map.setRegion(MKCoordinateRegion(center: Geo.cl(center), latitudinalMeters: startSpan, longitudinalMeters: startSpan), animated: false)
        } else {
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                                             latitudinalMeters: 3_000_000, longitudinalMeters: 3_000_000), animated: false)
        }
        context.coordinator.sync(map)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: MapCanvas
        private var lastSignature: Signature?
        private var lastFlyID: UUID?
        private var esri: MKTileOverlay?
        private var dragging = false

        struct Signature: Equatable {
            let shapes: [TakeoffShape]
            let draft: [Coordinate]
            let selected: UUID?
            let tool: MeasureTool
            let preview: [TakeoffShape]
        }

        init(parent: MapCanvas) { self.parent = parent }

        func sync(_ map: MKMapView) {
            syncImagery(map)
            if let fly = parent.flyTo, fly.id != lastFlyID {
                lastFlyID = fly.id
                map.setRegion(MKCoordinateRegion(center: Geo.cl(fly.center), latitudinalMeters: fly.spanMeters, longitudinalMeters: fly.spanMeters), animated: true)
            }
            let signature = Signature(shapes: parent.takeoff.shapes, draft: parent.draft, selected: parent.selectedID, tool: parent.tool, preview: parent.preview)
            guard signature != lastSignature, !dragging else { return }
            lastSignature = signature
            rebuild(map)
        }

        private func syncImagery(_ map: MKMapView) {
            let wantsEsri = parent.takeoff.imagery == .esri
            if wantsEsri, esri == nil {
                let overlay = MKTileOverlay(urlTemplate: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}")
                overlay.canReplaceMapContent = true
                overlay.maximumZ = 19
                map.addOverlay(overlay, level: .aboveRoads)
                esri = overlay
            } else if !wantsEsri, let overlay = esri {
                map.removeOverlay(overlay)
                esri = nil
            }
        }

        private func rebuild(_ map: MKMapView) {
            map.removeOverlays(map.overlays.filter { !($0 is MKTileOverlay) })
            map.removeAnnotations(map.annotations)
            let drawing = parent.tool != .select

            for shape in parent.takeoff.shapes {
                let color = NSColor(hex: shape.workType.hex)
                switch shape.kind {
                case .area where shape.points.count >= 3:
                    let holes = shape.holes.filter { $0.count >= 3 }.map { ring -> MKPolygon in
                        let coords = ring.map(Geo.cl)
                        return MKPolygon(coordinates: coords, count: coords.count)
                    }
                    let coords = shape.points.map(Geo.cl)
                    let polygon = MKPolygon(coordinates: coords, count: coords.count, interiorPolygons: holes)
                    polygon.title = shape.id.uuidString
                    polygon.subtitle = shape.workType.rawValue
                    map.addOverlay(polygon, level: .aboveLabels)
                    if !drawing {
                        let text = "\(shape.name.isEmpty ? shape.workType.label : shape.name) · \(Fmt.number(Geo.netAreaSqFt(shape))) sq ft"
                        map.addAnnotation(LabelAnnotation(coordinate: Geo.cl(Geo.centroid(shape.points)), text: text, color: color, shapeID: shape.id))
                    }
                case .line where shape.points.count >= 2:
                    let coords = shape.points.map(Geo.cl)
                    let line = MKPolyline(coordinates: coords, count: coords.count)
                    line.title = shape.id.uuidString
                    line.subtitle = shape.workType.rawValue
                    map.addOverlay(line, level: .aboveLabels)
                    if !drawing {
                        let mid = shape.points[shape.points.count / 2]
                        let text = "\(shape.name.isEmpty ? shape.workType.label : shape.name) · \(Fmt.number(Geo.lengthFt(shape.points))) LF"
                        map.addAnnotation(LabelAnnotation(coordinate: Geo.cl(mid), text: text, color: color, shapeID: shape.id))
                    }
                case .count where !shape.points.isEmpty:
                    map.addAnnotation(CountAnnotation(shape: shape, selected: shape.id == parent.selectedID))
                default:
                    break
                }
            }

            for shape in parent.preview {
                let coords = shape.points.map(Geo.cl)
                switch shape.kind {
                case .area where coords.count >= 3:
                    let holes = shape.holes.filter { $0.count >= 3 }.map { ring -> MKPolygon in
                        let c = ring.map(Geo.cl)
                        return MKPolygon(coordinates: c, count: c.count)
                    }
                    let polygon = MKPolygon(coordinates: coords, count: coords.count, interiorPolygons: holes)
                    polygon.title = "preview"
                    map.addOverlay(polygon, level: .aboveLabels)
                    map.addAnnotation(LabelAnnotation(coordinate: Geo.cl(Geo.centroid(shape.points)),
                                                      text: "Proposed · \(Fmt.number(Geo.netAreaSqFt(shape))) sq ft", color: .white, shapeID: UUID()))
                case .line where coords.count >= 2:
                    let line = MKPolyline(coordinates: coords, count: coords.count)
                    line.title = "preview"
                    map.addOverlay(line, level: .aboveLabels)
                case .count:
                    for c in coords {
                        let point = DraftPointAnnotation()
                        point.coordinate = c
                        map.addAnnotation(point)
                    }
                default:
                    break
                }
            }

            if let id = parent.selectedID, !drawing, let shape = parent.takeoff.shapes.first(where: { $0.id == id }), shape.kind != .count {
                for (i, point) in shape.points.enumerated() {
                    map.addAnnotation(VertexAnnotation(shapeID: id, ring: 0, index: i, coordinate: Geo.cl(point)))
                }
                for (r, hole) in shape.holes.enumerated() {
                    for (i, point) in hole.enumerated() {
                        map.addAnnotation(VertexAnnotation(shapeID: id, ring: r + 1, index: i, coordinate: Geo.cl(point)))
                    }
                }
            }

            if !parent.draft.isEmpty {
                let coords = parent.draft.map(Geo.cl)
                if parent.draftIsArea, coords.count >= 3 {
                    let fill = MKPolygon(coordinates: coords, count: coords.count)
                    fill.title = "draftfill"
                    map.addOverlay(fill, level: .aboveLabels)
                }
                if coords.count >= 2 {
                    var path = coords
                    if parent.draftIsArea, coords.count >= 3 { path.append(coords[0]) }
                    let line = MKPolyline(coordinates: path, count: path.count)
                    line.title = "draft"
                    map.addOverlay(line, level: .aboveLabels)
                }
                for coord in coords {
                    let point = DraftPointAnnotation()
                    point.coordinate = coord
                    map.addAnnotation(point)
                }
            }
        }

        // MARK: Clicks

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            let coordinate = Geo.coord(map.convert(point, toCoordinateFrom: map))
            if parent.tool == .select {
                parent.onSelect(hitTest(map, point: point, coordinate: coordinate))
            } else {
                parent.onClick(coordinate)
            }
        }

        func gestureRecognizer(_ recognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard parent.tool == .select, let map = recognizer.view else { return true }
            let local = map.convert(event.locationInWindow, from: nil)
            var hit = map.hitTest(local)
            while let view = hit {
                if view is MKAnnotationView { return false }
                hit = view.superview
            }
            return true
        }

        private func hitTest(_ map: MKMapView, point: CGPoint, coordinate: Coordinate) -> UUID? {
            let shapes = parent.takeoff.shapes
            func screen(_ c: Coordinate) -> CGPoint { map.convert(Geo.cl(c), toPointTo: map) }
            for shape in shapes where shape.kind == .count {
                if let c = shape.points.first, hypot(screen(c).x - point.x, screen(c).y - point.y) < 16 { return shape.id }
            }
            for shape in shapes where shape.kind == .line {
                let pts = shape.points.map(screen)
                for (a, b) in zip(pts, pts.dropFirst()) where distance(point, a, b) < 10 { return shape.id }
            }
            let areas = shapes.filter { shape in
                shape.kind == .area && Geo.contains(shape.points, coordinate) && !shape.holes.contains { Geo.contains($0, coordinate) }
            }
            return areas.min { Geo.netAreaSqFt($0) < Geo.netAreaSqFt($1) }?.id
        }

        private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }

        // MARK: Delegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                if polygon.title == "draftfill" {
                    renderer.fillColor = NSColor.white.withAlphaComponent(0.14)
                    return renderer
                }
                if polygon.title == "preview" {
                    renderer.fillColor = NSColor.white.withAlphaComponent(0.16)
                    renderer.strokeColor = .white
                    renderer.lineWidth = 3
                    renderer.lineDashPattern = [9, 6]
                    renderer.lineJoin = .round
                    return renderer
                }
                let type = WorkType(rawValue: polygon.subtitle ?? "") ?? .millOverlay
                let selected = polygon.title == parent.selectedID?.uuidString
                let color = NSColor(hex: type.hex)
                renderer.fillColor = color.withAlphaComponent(selected ? 0.34 : 0.22)
                renderer.strokeColor = color
                renderer.lineWidth = selected ? 4 : 2.5
                renderer.lineJoin = .round
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                if line.title == "preview" {
                    renderer.strokeColor = .white
                    renderer.lineWidth = 3.5
                    renderer.lineDashPattern = [9, 6]
                    return renderer
                }
                if line.title == "draft" {
                    renderer.strokeColor = .white
                    renderer.lineWidth = 2.5
                    renderer.lineDashPattern = [7, 5]
                    return renderer
                }
                let type = WorkType(rawValue: line.subtitle ?? "") ?? .striping
                let selected = line.title == parent.selectedID?.uuidString
                renderer.strokeColor = NSColor(hex: type.hex)
                renderer.lineWidth = selected ? 6 : 4
                if type == .striping { renderer.lineDashPattern = [2, 7] }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let vertex as VertexAnnotation:
                let view = VertexView(annotation: vertex, reuseIdentifier: nil)
                view.image = MapImages.vertex
                view.canShowCallout = false
                view.displayPriority = .required
                view.mapView = mapView
                view.onDragging = { [weak self] active in self?.dragging = active }
                view.onMoved = { [weak self] vertex in
                    self?.parent.onMoveVertex(vertex.shapeID, vertex.ring, vertex.index, Geo.coord(vertex.coordinate))
                }
                return view
            case let draft as DraftPointAnnotation:
                let view = MKAnnotationView(annotation: draft, reuseIdentifier: nil)
                view.image = MapImages.draftPoint
                view.isEnabled = false
                view.displayPriority = .required
                return view
            case let label as LabelAnnotation:
                let view = MKAnnotationView(annotation: label, reuseIdentifier: nil)
                view.image = MapImages.pill(label.text, color: label.color)
                view.canShowCallout = false
                view.displayPriority = .required
                view.collisionMode = .rectangle
                return view
            case let count as CountAnnotation:
                let view = MKAnnotationView(annotation: count, reuseIdentifier: nil)
                view.image = MapImages.count(count.shape, selected: count.selected)
                view.canShowCallout = false
                view.displayPriority = .required
                return view
            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer { if let annotation = view.annotation { mapView.deselectAnnotation(annotation, animated: false) } }
            guard parent.tool == .select else { return }
            if let label = view.annotation as? LabelAnnotation {
                parent.onSelect(label.shapeID)
            } else if let count = view.annotation as? CountAnnotation {
                parent.onSelect(count.shape.id)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            parent.onRegionChange(Geo.coord(region.center), region.span.latitudeDelta * 111_000)
        }
    }
}

// MARK: - Look Around

struct LookAroundSheet: View {
    let coordinate: Coordinate
    @Environment(\.dismiss) private var dismiss
    @State private var scene: MKLookAroundScene?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Look Around").font(.ui(15, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ZStack {
                if let scene {
                    LookAroundRepresentable(scene: scene)
                } else if loading {
                    ProgressView("Looking for street-level imagery…")
                } else {
                    EmptyState(icon: "binoculars", title: "No street view here", message: "Apple doesn't have Look Around imagery for this spot yet.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 600)
        .task {
            scene = try? await MKLookAroundSceneRequest(coordinate: Geo.cl(coordinate)).scene
            loading = false
        }
    }
}

private struct LookAroundRepresentable: NSViewControllerRepresentable {
    let scene: MKLookAroundScene
    func makeNSViewController(context: Context) -> MKLookAroundViewController {
        MKLookAroundViewController(scene: scene)
    }
    func updateNSViewController(_ controller: MKLookAroundViewController, context: Context) {
        controller.scene = scene
    }
}
