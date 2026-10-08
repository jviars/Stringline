import Foundation

/// Looking at a job's lot from above, drawing on its map, and changing settings.
/// Like every write tool, the drawing tools only propose: nothing is saved until the owner presses Apply.
extension ToolRunner {

    // MARK: Looking

    func lookAtMap(_ a: ToolArgs, _ services: AssistantServices) async throws -> ToolOutcome {
        guard picturesAllowed else {
            throw ToolError("This ChatGPT account doesn't accept pictures from apps, so the map can't be shown. Tell the owner they can draw it in Measure, or add an OpenAI API key in Settings › AI assistant.")
        }
        let j = try resolveJob(a.string("job"))
        let t = draft.takeoff(j.id, base)
        let center: Coordinate
        if let lat = a.double("center_latitude"), let lon = a.double("center_longitude"), (-85...85).contains(lat), (-180...180).contains(lon) {
            center = Coordinate(lat: lat, lon: lon)
        } else if let c = t.center {
            center = c
        } else if let lat = j.latitude, let lon = j.longitude {
            center = Coordinate(lat: lat, lon: lon)
        } else if !j.address.isEmpty, let place = await services.findPlaces(j.address, near: home).first {
            center = place.coordinate
        } else {
            throw ToolError("\(j.name) has no map location yet. Use find_place with its address, then look_at_map with center_latitude and center_longitude.")
        }
        let frame = MapFrame(center: center, spanMeters: min(max(a.double("width_meters") ?? t.spanMeters ?? 250, 40), 1500))
        let picture = try await services.mapPicture(frame, shapes: t.shapes)
        func grid(_ c: Coordinate) -> JSONValue {
            let p = frame.gridPoint(c)
            return [.number(p.x.rounded()), .number(p.y.rounded())]
        }
        let shapes: [JSONValue] = t.shapes.prefix(60).map { shape in
            var o: [String: JSONValue] = ["id": .string(shape.id.uuidString), "name": .string(Self.label(shape)),
                                          "kind": .string(shape.kind.rawValue), "work_type": .string(shape.workType.rawValue),
                                          "points": .array(shape.points.map(grid))]
            if !shape.holes.isEmpty { o["cutouts"] = .array(shape.holes.map { .array($0.map(grid)) }) }
            switch shape.kind {
            case .area: o["area_sq_ft"] = .number(Geo.netAreaSqFt(shape).rounded())
            case .line: o["length_ft"] = .number(Geo.lengthFt(shape.points).rounded())
            case .count: o["marker"] = .string(shape.countKind.rawValue)
            }
            return .object(o)
        }
        let feet = frame.metersPerGridUnit * 3.28084
        var outcome = ToolOutcome(output: [
            "map_id": .string(frame.id), "job_id": .string(j.id.uuidString), "job": .string(j.name), "address": .string(j.address),
            "picture": .string("Satellite view, north up. Grid 0 to 1000: x across from the left edge, y down from the top edge. One grid step is \(Fmt.plain((frame.metersPerGridUnit * 100).rounded() / 100)) m (\(Fmt.plain((feet * 100).rounded() / 100)) ft). Shapes already measured are outlined in color with their names."),
            "width_meters": .number(frame.spanMeters),
            "shapes_on_map": .array(shapes),
        ], activity: "Looked at \(j.name) from above", icon: "map")
        outcome.image = picture
        if mode == .action { outcome.navigate = .job(j.id, tab: "measure") }
        return outcome
    }

    private var home: Coordinate? {
        guard let lat = base.settings.company.homeLatitude, let lon = base.settings.company.homeLongitude else { return nil }
        return Coordinate(lat: lat, lon: lon)
    }

    static func label(_ shape: TakeoffShape) -> String {
        if !shape.name.isEmpty { return shape.name }
        return shape.kind == .count ? shape.countKind.label : shape.workType.label
    }

    func resolveShape(_ t: Takeoff, _ ref: String) throws -> TakeoffShape {
        if let id = UUID(uuidString: ref), let s = t.shapes.first(where: { $0.id == id }) { return s }
        let named = t.shapes.filter { Self.label($0).caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw ToolError("More than one measured shape is called “\(ref)”. Use its id from look_at_map or get_job.") }
        throw ToolError("No measured shape “\(ref)”. Use look_at_map or get_job for ids.")
    }

    // MARK: Points

    private func frame(_ a: ToolArgs) throws -> MapFrame {
        guard let id = a.string("map_id", max: 80), let frame = MapFrame(id: id) else {
            throw ToolError("Use the map_id from look_at_map, exactly as it was given.")
        }
        return frame
    }

    /// Grid points ([x, y] on the picture) as map coordinates, plus the grid points themselves for checking.
    private func points(_ value: JSONValue?, _ frame: MapFrame, what: String) throws -> (coords: [Coordinate], grid: [(Double, Double)]) {
        guard let list = value?.array else { return ([], []) }
        guard list.count <= 400 else { throw ToolError("Too many points in \(what): 400 at most.") }
        var grid: [(Double, Double)] = []
        for item in list {
            guard let pair = item.array, pair.count == 2, let x = pair[0].double, let y = pair[1].double, x.isFinite, y.isFinite else {
                throw ToolError("Each point in \(what) must be [x, y]: two numbers on the picture's grid.")
            }
            guard (-50...1050).contains(x), (-50...1050).contains(y) else {
                throw ToolError("A point in \(what), [\(Fmt.plain(x)), \(Fmt.plain(y))], is off the picture. Look again with a wider or moved picture.")
            }
            grid.append((x, y))
        }
        // Drop repeated points (models often close a ring by repeating the first corner).
        var cleaned: [(Double, Double)] = []
        for p in grid where cleaned.last.map({ abs($0.0 - p.0) > 0.01 || abs($0.1 - p.1) > 0.01 }) ?? true { cleaned.append(p) }
        if cleaned.count > 2, let first = cleaned.first, let last = cleaned.last, abs(first.0 - last.0) < 0.01, abs(first.1 - last.1) < 0.01 { cleaned.removeLast() }
        return (cleaned.map { frame.coordinate(gridX: $0.0, gridY: $0.1) }, cleaned)
    }

    private func checkOutline(_ coords: [Coordinate], grid: [(Double, Double)], kind: ShapeKind) throws {
        switch kind {
        case .area:
            guard coords.count >= 3 else { throw ToolError("An area needs at least 3 corners.") }
            let sqft = Geo.areaSqFt(coords)
            guard sqft >= 20 else { throw ToolError("That outline is too small to be real (\(Fmt.number(sqft)) sq ft). Check the points.") }
            guard sqft <= 25_000_000 else { throw ToolError("That outline is far too big. Check the points.") }
            guard !Self.crossesItself(grid) else { throw ToolError("The outline crosses itself. List the corners in order around the edge.") }
        case .line:
            guard coords.count >= 2 else { throw ToolError("A line needs at least 2 points.") }
        case .count:
            guard !coords.isEmpty, coords.count <= 200 else { throw ToolError("Give between 1 and 200 markers.") }
        }
    }

    /// True if any two edges of the closed outline cross (edges that share a corner don't count).
    static func crossesItself(_ p: [(Double, Double)]) -> Bool {
        let n = p.count
        guard n >= 4 else { return false }
        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        for i in 0..<n {
            let a1 = p[i], a2 = p[(i + 1) % n]
            for k in stride(from: i + 2, to: n, by: 1) {
                if i == 0 && k == n - 1 { continue }
                let b1 = p[k], b2 = p[(k + 1) % n]
                let d1 = cross(b1, b2, a1), d2 = cross(b1, b2, a2), d3 = cross(a1, a2, b1), d4 = cross(a1, a2, b2)
                if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
            }
        }
        return false
    }

    private func cutouts(_ value: JSONValue?, _ frame: MapFrame, inside outline: [Coordinate]) throws -> [[Coordinate]] {
        guard let rings = value?.array else { return [] }
        guard rings.count <= 40 else { throw ToolError("40 cutouts at most.") }
        return try rings.map { ring in
            let (coords, grid) = try points(ring, frame, what: "a cutout")
            guard coords.count >= 3 else { throw ToolError("Each cutout needs at least 3 corners.") }
            guard !Self.crossesItself(grid) else { throw ToolError("A cutout's outline crosses itself.") }
            guard coords.allSatisfy({ Geo.contains(outline, $0) }) else { throw ToolError("A cutout has to be inside the area it's cut from.") }
            return coords
        }
    }

    private func size(_ shape: TakeoffShape) -> String {
        switch shape.kind {
        case .area:
            let sqft = Geo.netAreaSqFt(shape)
            return "\(Fmt.number(sqft)) sq ft (\(Fmt.number(sqft / 9)) SY)"
        case .line: return "\(Fmt.number(Geo.lengthFt(shape.points))) ft"
        case .count: return "\(shape.quantity) \(shape.countKind.label.lowercased())"
        }
    }

    // MARK: Drawing

    func drawShape(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let frame = try frame(a)
        let (coords, grid) = try points(a.value("points"), frame, what: "points")
        let name = a.string("name", max: 80) ?? ""
        switch try a.required("kind", max: 20) {
        case "area":
            let work = a.string("work_type").flatMap(WorkType.init(rawValue:)) ?? .millOverlay
            guard work.isArea else { throw ToolError("\(work.label) is drawn as a line. Use kind line, or an area work type.") }
            try checkOutline(coords, grid: grid, kind: .area)
            var shape = TakeoffShape()
            shape.kind = .area
            shape.workType = work
            shape.name = name
            shape.points = coords
            shape.holes = try cutouts(a.value("cutouts"), frame, inside: coords)
            if work.hasDepth {
                let depth = a.double("depth_inches") ?? work.defaultDepth
                guard depth > 0, depth <= 24 else { throw ToolError("Depth must be between 0 and 24 inches.") }
                shape.depthInches = depth
            }
            let holes = shape.holes.isEmpty ? "" : " · \(shape.holes.count) cut out"
            return try propose([.putShape(job: j.id, shape)], title: "Draw \(name.isEmpty ? work.label.lowercased() : name): \(size(shape))",
                               detail: "\(work.label) on \(j.name) · \(coords.count) corners traced from the satellite picture\(holes) · Check the edges once it's applied; you can drag any corner",
                               extra: ["shape_id": .string(shape.id.uuidString), "area_sq_ft": .number(Geo.netAreaSqFt(shape).rounded())])
        case "line":
            let work = a.string("work_type").flatMap(WorkType.init(rawValue:)) ?? .striping
            guard !work.isArea else { throw ToolError("\(work.label) is drawn as an area. Use kind area.") }
            try checkOutline(coords, grid: grid, kind: .line)
            var shape = TakeoffShape()
            shape.kind = .line
            shape.workType = work
            shape.name = name
            shape.points = coords
            shape.depthInches = 0
            return try propose([.putShape(job: j.id, shape)], title: "Draw \(name.isEmpty ? work.label.lowercased() : name): \(size(shape))",
                               detail: "\(work.label) on \(j.name) · \(coords.count) points traced from the satellite picture",
                               extra: ["shape_id": .string(shape.id.uuidString), "length_ft": .number(Geo.lengthFt(coords).rounded())])
        case "markers":
            try checkOutline(coords, grid: grid, kind: .count)
            let kind = a.string("marker_kind").flatMap(CountKind.init(rawValue:)) ?? .stall
            let shapes: [TakeoffShape] = coords.map { c in
                var shape = TakeoffShape()
                shape.kind = .count
                shape.countKind = kind
                shape.workType = .striping
                shape.points = [c]
                shape.quantity = 1
                shape.name = name.isEmpty ? kind.label : name
                return shape
            }
            return try propose(shapes.map { .putShape(job: j.id, $0) }, title: "Mark \(coords.count) \(kind.label.lowercased()) on \(j.name)",
                               detail: "Counted from the satellite picture · \(coords.count) markers",
                               extra: ["markers": .number(Double(coords.count))])
        case let other:
            throw ToolError("kind must be area, line or markers, not “\(other)”.")
        }
    }

    func reshapeArea(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let t = draft.takeoff(j.id, base)
        var shape = try resolveShape(t, a.required("area", max: 120))
        let before = size(shape)
        guard shape.kind != .count else { throw ToolError("Markers can't be reshaped. Use delete_shape and draw_shape with markers.") }
        let frame = try frame(a)
        var parts: [String] = []
        if a.value("points") != nil {
            let (coords, grid) = try points(a.value("points"), frame, what: "points")
            try checkOutline(coords, grid: grid, kind: shape.kind)
            shape.points = coords
            // Cutouts that no longer fit inside the new outline are dropped rather than left dangling.
            let kept = shape.holes.filter { ring in ring.allSatisfy { Geo.contains(coords, $0) } }
            if kept.count < shape.holes.count { parts.append("\(shape.holes.count - kept.count) cutout\(shape.holes.count - kept.count == 1 ? "" : "s") outside the new outline removed") }
            shape.holes = kept
            parts.insert("New outline, \(coords.count) \(shape.kind == .area ? "corners" : "points")", at: 0)
        }
        if a.value("cutouts") != nil {
            guard shape.kind == .area else { throw ToolError("Only areas have cutouts.") }
            shape.holes = try cutouts(a.value("cutouts"), frame, inside: shape.points)
            parts.append(shape.holes.isEmpty ? "No cutouts" : "\(shape.holes.count) cutout\(shape.holes.count == 1 ? "" : "s")")
        }
        guard !parts.isEmpty else { throw ToolError("Give new points, new cutouts, or both.") }
        return try propose([.putShape(job: j.id, shape)], title: "Redraw \(Self.label(shape)): \(before) → \(size(shape))",
                           detail: parts.joined(separator: " · ") + " · on \(j.name)",
                           extra: ["shape_id": .string(shape.id.uuidString)])
    }

    func deleteShape(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let shape = try resolveShape(draft.takeoff(j.id, base), a.required("area", max: 120))
        return try propose([.removeShape(job: j.id, shape: shape.id)], title: "Remove \(Self.label(shape)) from the map",
                           detail: "\(size(shape)) on \(j.name) · It stays in History if you want it back")
    }

    // MARK: Settings

    func updateSettings(_ a: ToolArgs) throws -> ToolOutcome {
        let s = draft.currentSettings(base)
        var p = SettingsPatch()
        var parts: [String] = []
        func text(_ key: String, _ label: String, _ current: String, max: Int = 200, set: (String) -> Void) {
            guard let v = a.string(key, max: max), v != current else { return }
            set(v)
            parts.append("\(label) → \(v.count > 60 ? String(v.prefix(57)) + "…" : v)")
        }
        func number(_ key: String, _ label: String, _ range: ClosedRange<Double>, _ current: Double, unit: String = "") throws -> Double? {
            guard let v = a.double(key) else { return nil }
            guard range.contains(v) else { throw ToolError("\(label) must be between \(Fmt.plain(range.lowerBound)) and \(Fmt.plain(range.upperBound))\(unit).") }
            guard v != current else { return nil }
            parts.append("\(label) \(Fmt.plain(current))\(unit) → \(Fmt.plain(v))\(unit)")
            return v
        }
        text("company_name", "Company name", s.company.name) { p.companyName = $0 }
        text("phone", "Phone", s.company.phone) { p.phone = $0 }
        text("email", "Email", s.company.email) { p.email = $0 }
        text("address", "Address", s.company.address) { p.address = $0 }
        text("license", "License", s.company.license) { p.license = $0 }
        text("website", "Website", s.company.website) { p.website = $0 }
        text("home_base", "Home base", s.company.homeBase) { p.homeBase = $0 }
        if let lat = a.double("home_latitude"), let lon = a.double("home_longitude") {
            guard (-85...85).contains(lat), (-180...180).contains(lon) else { throw ToolError("That home base location isn't on the map.") }
            p.homeLatitude = lat
            p.homeLongitude = lon
            parts.append("Home base moved on the map")
        }
        p.pavingMinF = try number("paving_min_f", "Paving minimum", 20...100, s.weather.pavingMinF, unit: "°F")
        p.sealcoatMinF = try number("sealcoat_min_f", "Sealcoat minimum", 20...100, s.weather.sealcoatMinF, unit: "°F")
        p.sealcoatDryHours = try number("sealcoat_dry_hours", "Sealcoat dry time", 1...72, Double(s.weather.sealcoatHours), unit: " h").map { Int($0.rounded()) }
        p.rainChanceMax = try number("rain_chance_max", "Rain limit", 0...100, Double(s.weather.rainChanceMax), unit: "%").map { Int($0.rounded()) }
        p.proposalValidDays = try number("proposal_valid_days", "Proposal good for", 1...365, Double(s.proposal.validDays), unit: " days").map { Int($0.rounded()) }
        p.sealcoatCycleYears = try number("sealcoat_cycle_years", "Sealcoat cycle", 1...10, Double(s.sealcoatCycleYears), unit: " years").map { Int($0.rounded()) }
        text("exclusions", "Exclusions", s.proposal.exclusions, max: 2000) { p.exclusions = $0 }
        text("terms", "Terms", s.proposal.terms, max: 2000) { p.terms = $0 }
        if let v = a.bool("escalation_clause"), v != s.proposal.escalationClause {
            p.escalationClause = v
            parts.append(v ? "Escalation clause on" : "Escalation clause off")
        }
        if let v = a.bool("backup_nightly"), v != s.backupNightly {
            p.backupNightly = v
            parts.append(v ? "Nightly backups on" : "Nightly backups off")
        }
        if let c = a.value("crew"), c.object != nil {
            let crewArgs = ToolArgs(json: c)
            var crew: Crew
            if let ref = crewArgs.string("id") {
                guard let existing = try resolveCrew(ref) else { throw ToolError("No crew matches “\(ref)”.") }
                crew = existing
            } else {
                guard crewArgs.string("name") != nil else { throw ToolError("A new crew needs a name.") }
                crew = Crew()
            }
            if let v = crewArgs.string("name", max: 60) { crew.name = v }
            if let v = crewArgs.string("kind", max: 60) { crew.kind = v }
            if let v = crewArgs.int("people") {
                guard (1...60).contains(v) else { throw ToolError("A crew has between 1 and 60 people.") }
                crew.people = v
            }
            if let v = crewArgs.string("equipment", max: 200) { crew.equipment = v }
            if s.crews.first(where: { $0.id == crew.id }) != crew {
                p.crew = crew
                parts.append(s.crews.contains { $0.id == crew.id } ? "Crew \(crew.name) updated" : "New crew: \(crew.name)")
            }
        }
        guard !p.isEmpty else { throw ToolError("Nothing to change in settings.") }
        return try propose([.updateSettings(p)], title: parts.count == 1 ? "Settings: \(parts[0])" : "Settings: \(parts.count) changes",
                           detail: parts.joined(separator: " · "))
    }
}
