import Foundation
import MapKit

// MARK: - Geometry

enum Geo {
    static let sqFtPerSqM = 10.7639
    static let ftPerM = 3.28084

    static func cl(_ c: Coordinate) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon) }
    static func coord(_ c: CLLocationCoordinate2D) -> Coordinate { Coordinate(lat: c.latitude, lon: c.longitude) }

    /// Shoelace formula on map points, scaled to real meters at this latitude. Accurate at parking-lot size.
    static func areaSqFt(_ pts: [Coordinate]) -> Double {
        guard pts.count >= 3 else { return 0 }
        let mps = pts.map { MKMapPoint(cl($0)) }
        var sum = 0.0
        for i in mps.indices {
            let a = mps[i], b = mps[(i + 1) % mps.count]
            sum += a.x * b.y - b.x * a.y
        }
        let lat = pts.map(\.lat).reduce(0, +) / Double(pts.count)
        let metersPerPoint = MKMetersPerMapPointAtLatitude(lat)
        return abs(sum) / 2 * metersPerPoint * metersPerPoint * sqFtPerSqM
    }

    static func netAreaSqFt(_ shape: TakeoffShape) -> Double {
        max(0, areaSqFt(shape.points) - shape.holes.map(areaSqFt).reduce(0, +))
    }

    static func lengthFt(_ pts: [Coordinate]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { total, pair in
            let a = CLLocation(latitude: pair.0.lat, longitude: pair.0.lon)
            let b = CLLocation(latitude: pair.1.lat, longitude: pair.1.lon)
            return total + a.distance(from: b)
        } * ftPerM
    }

    static func centroid(_ pts: [Coordinate]) -> Coordinate {
        guard !pts.isEmpty else { return Coordinate(lat: 0, lon: 0) }
        return Coordinate(lat: pts.map(\.lat).reduce(0, +) / Double(pts.count),
                          lon: pts.map(\.lon).reduce(0, +) / Double(pts.count))
    }

    static func contains(_ polygon: [Coordinate], _ p: Coordinate) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.lat > p.lat) != (b.lat > p.lat),
               p.lon < (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

// MARK: - Takeoff math

struct TakeoffSummary: Hashable {
    var areaSqFt: [WorkType: Double] = [:]
    var lineFt: [WorkType: Double] = [:]
    var counts: [CountKind: Int] = [:]
    var surfaceTons = 0.0
    var baseTons = 0.0

    func sy(_ w: WorkType) -> Double { (areaSqFt[w] ?? 0) / 9 }
    var pavedSY: Double { sy(.millOverlay) + sy(.newPaving) + sy(.fullDepthPatch) }
    /// What the price-per-SY figure divides by.
    var billableSY: Double { pavedSY > 0 ? pavedSY : sy(.sealcoat) }
    var isEmpty: Bool { areaSqFt.isEmpty && lineFt.isEmpty && counts.isEmpty }
}

struct MaterialLine: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let detail: String
    let amount: String
}

enum Estimator {
    static func summary(_ t: Takeoff, factors f: Factors) -> TakeoffSummary {
        var s = TakeoffSummary()
        for shape in t.shapes {
            switch shape.kind {
            case .area:
                let sqft = Geo.netAreaSqFt(shape)
                s.areaSqFt[shape.workType, default: 0] += sqft
                let tons = sqft / 9 * shape.depthInches * f.mixLbPerSYInch / 2000
                switch shape.workType {
                case .millOverlay, .newPaving: s.surfaceTons += tons
                case .fullDepthPatch: s.baseTons += tons
                default: break
                }
            case .line:
                s.lineFt[shape.workType, default: 0] += Geo.lengthFt(shape.points)
            case .count:
                s.counts[shape.countKind, default: 0] += shape.quantity
            }
        }
        return s
    }

    static func withWaste(_ tons: Double, _ f: Factors) -> Double {
        tons <= 0 ? 0 : (tons * (1 + f.wastePct / 100)).rounded(.up)
    }

    static func pavingDays(_ s: TakeoffSummary, _ f: Factors) -> Double {
        s.pavedSY > 0 ? max(1, (s.pavedSY / max(f.paveSYPerDay, 1)).rounded(.up)) : 0
    }

    static func materials(_ s: TakeoffSummary, _ f: Factors) -> [MaterialLine] {
        var out: [MaterialLine] = []
        if s.surfaceTons > 0 {
            out.append(MaterialLine(name: "Surface mix", detail: "\(Fmt.number(s.surfaceTons)) tn + \(Fmt.plain(f.wastePct))% waste",
                                    amount: "\(Fmt.number(withWaste(s.surfaceTons, f))) tn"))
        }
        if s.baseTons > 0 {
            out.append(MaterialLine(name: "Base & patch mix", detail: "\(Fmt.number(s.baseTons)) tn + \(Fmt.plain(f.wastePct))% waste",
                                    amount: "\(Fmt.number(withWaste(s.baseTons, f))) tn"))
        }
        let millSY = s.sy(.millOverlay)
        if millSY > 0 {
            out.append(MaterialLine(name: "Tack coat", detail: "\(Fmt.plain(f.tackGalPerSY)) gal per SY", amount: "\(Fmt.number(millSY * f.tackGalPerSY)) gal"))
            out.append(MaterialLine(name: "Milling", detail: "Area to mill", amount: "\(Fmt.number(millSY)) SY"))
        }
        if s.sy(.sealcoat) > 0 {
            out.append(MaterialLine(name: "Sealcoat", detail: "Two coats", amount: "\(Fmt.number(s.sy(.sealcoat))) SY"))
        }
        if let stripe = s.lineFt[.striping], stripe > 0 {
            out.append(MaterialLine(name: "Traffic paint", detail: "About \(Fmt.plain(f.paintLFPerGal)) LF per gal",
                                    amount: "\(Fmt.number((stripe / max(f.paintLFPerGal, 1)).rounded(.up))) gal"))
        }
        if let crack = s.lineFt[.crackSeal], crack > 0 {
            out.append(MaterialLine(name: "Crack seal", detail: "Length to seal", amount: "\(Fmt.number(crack)) LF"))
        }
        let tons = withWaste(s.surfaceTons, f) + withWaste(s.baseTons, f)
        if tons > 0 {
            out.append(MaterialLine(name: "Truck loads", detail: "\(Fmt.plain(f.truckTons)) tn tri-axles",
                                    amount: Fmt.number((tons / max(f.truckTons, 1)).rounded(.up))))
        }
        return out
    }

    static func buildItems(_ s: TakeoffSummary, takeoff: Takeoff, rates: Rates) -> [LineItem] {
        let f = rates.factors
        var items: [LineItem] = []
        func add(_ group: String, _ key: String, _ name: String, _ qty: Double, _ unit: String, measured: Bool = true) {
            guard qty > 0 else { return }
            var item = LineItem()
            item.group = group
            item.key = key
            item.name = name
            item.qty = qty
            item.unit = unit
            item.unitCents = rates.cents(key)
            item.fromTakeoff = measured
            items.append(item)
        }
        let surface = withWaste(s.surfaceTons, f)
        let base = withWaste(s.baseTons, f)
        let millSY = s.sy(.millOverlay).rounded()
        add("Materials", "surfaceMix", rates.name("surfaceMix"), surface, "ton")
        add("Materials", "baseMix", rates.name("baseMix"), base, "ton")
        add("Materials", "tack", rates.name("tack"), (millSY * f.tackGalPerSY).rounded(), "gal")
        add("Materials", "sealcoat", rates.name("sealcoat"), s.sy(.sealcoat).rounded(), "SY")
        add("Materials", "crackSeal", rates.name("crackSeal"), (s.lineFt[.crackSeal] ?? 0).rounded(), "LF")

        let days = pavingDays(s, f)
        if days > 0 {
            let name = "Paving crew, \(Fmt.plain(f.crewSize)) people × \(Fmt.plain(f.hoursPerDay)) h × \(Fmt.plain(days)) day\(days == 1 ? "" : "s")"
            add("Labor", "crewLabor", name, f.crewSize * f.hoursPerDay * days, "hr", measured: false)
        }

        let millDepth = takeoff.shapes.first { $0.workType == .millOverlay }?.depthInches ?? 2
        add("Equipment & subs", "milling", "Milling \(Fmt.plain(millDepth))\" (sub)", millSY, "SY")
        if days > 0 { add("Equipment & subs", "paverRollers", rates.name("paverRollers"), days, "day", measured: false) }
        add("Equipment & subs", "striping", rates.name("striping"), (s.lineFt[.striping] ?? 0).rounded(), "LF")
        add("Equipment & subs", "stencil", rates.name("stencil"), Double((s.counts[.ada] ?? 0) + (s.counts[.arrow] ?? 0)), "ea")

        let loads = ((surface + base) / max(f.truckTons, 1)).rounded(.up)
        add("Trucking & general", "truckLoad", "Tri-axle loads, \(Fmt.plain(f.truckTons)) tn", loads, "load")
        if !items.isEmpty { add("Trucking & general", "mobilization", rates.name("mobilization"), 1, "LS", measured: false) }
        return items
    }

    static func scope(_ s: TakeoffSummary, takeoff: Takeoff) -> String {
        var lines: [String] = []
        func depth(_ w: WorkType) -> String {
            Fmt.plain(takeoff.shapes.first { $0.workType == w }?.depthInches ?? w.defaultDepth)
        }
        func places(_ w: WorkType) -> String {
            let names = takeoff.shapes.filter { $0.workType == w && !$0.name.isEmpty }.map { $0.name.lowercased() }
            switch names.count {
            case 0: return "the marked areas"
            case 1: return "the \(names[0])"
            default: return "the " + names.dropLast().joined(separator: ", ") + " and " + names.last!
            }
        }
        let millSY = s.sy(.millOverlay)
        if millSY > 0 {
            lines.append("Mill the existing asphalt \(depth(.millOverlay))\" across \(places(.millOverlay)) (\(Fmt.number(millSY)) SY) and haul off the millings.")
        }
        if s.sy(.fullDepthPatch) > 0 {
            lines.append("Cut out and replace failed pavement full depth, \(depth(.fullDepthPatch))\" (\(Fmt.number(s.sy(.fullDepthPatch))) SY).")
        }
        if millSY > 0 {
            lines.append("Apply tack coat, then pave \(depth(.millOverlay))\" of surface mix and roll to density.")
        }
        if s.sy(.newPaving) > 0 {
            lines.append("Pave \(depth(.newPaving))\" of surface mix over the prepared base (\(Fmt.number(s.sy(.newPaving))) SY) and roll to density.")
        }
        if s.sy(.sealcoat) > 0 {
            lines.append("Clean the surface and apply two coats of sealer (\(Fmt.number(s.sy(.sealcoat))) SY).")
        }
        if let crack = s.lineFt[.crackSeal], crack > 0 {
            lines.append("Clean out and seal cracks with hot-pour sealant (about \(Fmt.number(crack)) LF).")
        }
        var stripeParts: [String] = []
        if let n = s.counts[.stall], n > 0 { stripeParts.append("\(n) stalls") }
        if let n = s.counts[.ada], n > 0 { stripeParts.append("\(n) ADA stalls") }
        if let n = s.counts[.arrow], n > 0 { stripeParts.append("\(n) arrows") }
        if !stripeParts.isEmpty {
            let list = stripeParts.count == 1 ? stripeParts[0] : stripeParts.dropLast().joined(separator: ", ") + " and " + stripeParts.last!
            lines.append("Restripe \(list) to match the current layout.")
        } else if let stripe = s.lineFt[.striping], stripe > 0 {
            lines.append("Stripe about \(Fmt.number(stripe)) LF of 4\" lines.")
        }
        return lines.joined(separator: "\n")
    }

    static func option(title: String, takeoff: Takeoff, rates: Rates) -> EstimateOption {
        let s = summary(takeoff, factors: rates.factors)
        var option = EstimateOption()
        option.title = title
        option.items = buildItems(s, takeoff: takeoff, rates: rates)
        option.overheadPct = rates.factors.overheadPct
        option.profitPct = rates.factors.profitPct
        option.scope = scope(s, takeoff: takeoff)
        return option
    }

    /// Re-runs the takeoff math. Keeps the owner's own lines and any unit prices they changed on generated lines.
    static func refresh(_ option: EstimateOption, takeoff: Takeoff, rates: Rates) -> EstimateOption {
        let s = summary(takeoff, factors: rates.factors)
        var fresh = buildItems(s, takeoff: takeoff, rates: rates)
        for i in fresh.indices {
            if let old = option.items.first(where: { $0.key == fresh[i].key && !$0.key.isEmpty }) {
                fresh[i].id = old.id
                fresh[i].unitCents = old.unitCents
            }
        }
        var updated = option
        let manual = option.items.filter { $0.key.isEmpty }
        let order = EstimateOption.groups
        updated.items = (fresh + manual).enumerated().sorted { a, b in
            let ga = order.firstIndex(of: a.element.group) ?? order.count
            let gb = order.firstIndex(of: b.element.group) ?? order.count
            return ga == gb ? a.offset < b.offset : ga < gb
        }.map(\.element)
        if updated.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.scope = scope(s, takeoff: takeoff)
        }
        return updated
    }
}
