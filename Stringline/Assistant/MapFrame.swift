import Foundation

/// A square piece of the map, in the Web Mercator projection MapKit uses (MKMapPoint).
/// A look_at_map picture covers one frame, with a 0–1000 grid across and down. Points the model gives
/// on that grid convert to map coordinates here, and measured shapes convert back to draw on the picture.
struct MapFrame: Equatable {
    /// MapKit's world width in map points (MKMapSize.world).
    static let world = 268_435_456.0
    static let grid = 1000.0
    static let spanRange = 30.0...3000.0

    let center: Coordinate
    let spanMeters: Double

    init(center: Coordinate, spanMeters: Double) {
        self.center = center
        self.spanMeters = min(max(spanMeters.isFinite ? spanMeters : 250, Self.spanRange.lowerBound), Self.spanRange.upperBound)
    }

    // MARK: Projection

    static func mapPoint(_ c: Coordinate) -> (x: Double, y: Double) {
        let lat = min(max(c.lat, -85.05112878), 85.05112878) * .pi / 180
        let x = (c.lon + 180) / 360 * world
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * world
        return (x, y)
    }

    static func coordinate(mapX x: Double, mapY y: Double) -> Coordinate {
        let lon = x / world * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * y / world))) * 180 / .pi
        return Coordinate(lat: lat, lon: lon)
    }

    /// The frame's width (and height) in map points: `spanMeters` across at the center's latitude.
    var size: Double {
        let metersPerPoint = cos(center.lat * .pi / 180) * 2 * .pi * 6_378_137 / Self.world
        return spanMeters / metersPerPoint
    }

    /// Top-left corner in map points.
    var origin: (x: Double, y: Double) {
        let c = Self.mapPoint(center)
        return (c.x - size / 2, c.y - size / 2)
    }

    /// A point on the picture's grid (0,0 top left; 1000,1000 bottom right) as a map coordinate.
    func coordinate(gridX: Double, gridY: Double) -> Coordinate {
        let o = origin
        return Self.coordinate(mapX: o.x + gridX / Self.grid * size, mapY: o.y + gridY / Self.grid * size)
    }

    /// Where a map coordinate falls on the picture's grid.
    func gridPoint(_ c: Coordinate) -> (x: Double, y: Double) {
        let p = Self.mapPoint(c)
        let o = origin
        return ((p.x - o.x) / size * Self.grid, (p.y - o.y) / size * Self.grid)
    }

    /// Meters for one grid step (the picture is 1000 steps across).
    var metersPerGridUnit: Double { spanMeters / Self.grid }

    // MARK: Id

    /// Handed to the model with each picture and back with each drawing, so a drawing always lands
    /// where the picture showed, even in a later message.
    var id: String {
        String(format: "%.6f,%.6f,%.0f", center.lat, center.lon, spanMeters)
    }

    init?(id: String) {
        let parts = id.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let lat = parts[0], let lon = parts[1], let span = parts[2],
              (-85...85).contains(lat), (-180...180).contains(lon), Self.spanRange.contains(span) else { return nil }
        self.init(center: Coordinate(lat: lat, lon: lon), spanMeters: span)
    }
}
