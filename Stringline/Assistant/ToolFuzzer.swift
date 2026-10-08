#if DEBUG || STRINGLINE_TESTS
import Foundation

/// Small seeded random numbers, so a failing torture run can be repeated exactly.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random tool calls for torture tests: mostly sensible, some garbage.
@MainActor
struct ToolFuzzer {
    var rng: SeededRandom
    let base: AssistantDataSource

    init(seed: UInt64, base: AssistantDataSource) {
        rng = SeededRandom(seed: seed)
        self.base = base
    }

    static let tools = ["search", "get_job", "get_estimate", "list_jobs", "get_schedule", "get_weather", "get_customer", "get_rates",
                        "get_invoices", "compare_past_jobs", "point_at", "search_help", "get_help_article", "show_me", "open_screen",
                        "open_in_maps", "update_job", "add_daily_log", "update_customer", "draft_email", "draft_text",
                        "add_estimate_line", "update_estimate_line", "remove_estimate_line", "set_markup", "set_scope", "add_estimate_option",
                        "update_measured_area", "schedule_job", "remove_schedule_days", "add_to_calendar", "create_invoice", "mark_invoice_paid",
                        "update_rate", "create_lead", "create_customer", "look_at_map", "draw_shape", "reshape_area", "delete_shape", "update_settings"]

    mutating func pick<T>(_ list: [T]) -> T { list[Int.random(in: 0..<list.count, using: &rng)] }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }

    mutating func garbage() -> JSONValue {
        switch Int.random(in: 0..<9, using: &rng) {
        case 0: return .null
        case 1: return .number(Double.random(in: -1e9...1e9, using: &rng))
        case 2: return .string(String(repeating: "Ω🛣️", count: Int.random(in: 0...3000, using: &rng)))
        case 3: return .bool(chance(0.5))
        case 4: return .array([.string("x"), .null, .number(-1)])
        case 5: return ["nested": ["deep": .null]]
        case 6: return .string("2026-13-45")
        case 7: return .string("'; DROP TABLE jobs; --")
        default: return .string(UUID().uuidString)
        }
    }

    mutating func jobRef() -> JSONValue {
        let jobs = base.jobs
        if jobs.isEmpty || chance(0.12) { return garbage() }
        let j = pick(jobs)
        return .string(pick([j.id.uuidString, j.number, j.name]))
    }

    mutating func date() -> JSONValue {
        if chance(0.1) { return garbage() }
        let day = Date().startOfDay.adding(days: Int.random(in: -20...40, using: &rng))
        return ToolArgs.iso(day)
    }

    mutating func lineRef(_ jobRefValue: JSONValue) -> JSONValue {
        guard let ref = jobRefValue.string, let job = base.jobs.first(where: { $0.id.uuidString == ref || $0.number == ref || $0.name == ref }),
              let items = base.estimates[job.id]?.selected?.items, !items.isEmpty, !chance(0.15) else { return garbage() }
        return .string(pick(items).id.uuidString)
    }

    /// A map id for the job's lot, or something broken.
    mutating func mapID(_ jobRefValue: JSONValue) -> JSONValue {
        guard let ref = jobRefValue.string, let job = base.jobs.first(where: { $0.id.uuidString == ref || $0.number == ref || $0.name == ref }),
              !chance(0.1) else { return garbage() }
        let center = base.takeoffs[job.id]?.center ?? job.latitude.flatMap { lat in job.longitude.map { Coordinate(lat: lat, lon: $0) } }
        guard let center else { return .string("39.961200,-82.998800,250") }
        return .string(MapFrame(center: center, spanMeters: pick([60.0, 250, 800])).id)
    }

    /// Corners going around a rough circle on the picture's grid, sometimes shuffled (crossing) or off the picture.
    mutating func gridPoints() -> JSONValue {
        if chance(0.05) { return garbage() }
        let count = Int.random(in: 1...14, using: &rng)
        let cx = Double.random(in: 150...850, using: &rng), cy = Double.random(in: 150...850, using: &rng)
        let radius = Double.random(in: 5...(chance(0.1) ? 900 : 300), using: &rng)
        var points: [JSONValue] = (0..<count).map { i in
            let angle = Double(i) / Double(count) * 2 * .pi
            return [.number((cx + cos(angle) * radius).rounded()), .number((cy + sin(angle) * radius).rounded())]
        }
        if chance(0.1) { points.shuffle(using: &rng) }
        if chance(0.05) { points.append([.string("x"), .null]) }
        return .array(points)
    }

    mutating func shapeRef(_ jobRefValue: JSONValue) -> JSONValue {
        guard let ref = jobRefValue.string, let job = base.jobs.first(where: { $0.id.uuidString == ref || $0.number == ref || $0.name == ref }),
              let shapes = base.takeoffs[job.id]?.shapes, !shapes.isEmpty, !chance(0.15) else { return garbage() }
        return .string(pick(shapes).id.uuidString)
    }

    /// One call: (name, arguments text).
    mutating func call() -> (String, String) {
        if chance(0.04) { return ("no_such_tool_\(Int.random(in: 0...99, using: &rng))", "{}") }
        if chance(0.04) { return (pick(Self.tools), pick(["{not json", "", "[]", "null", "{\"job\": }"])) }
        let name = pick(Self.tools)
        let job = jobRef()
        var a: [String: JSONValue] = [:]
        switch name {
        case "search": a = ["query": chance(0.8) ? .string(pick(["Maple", "Ridge", "2026", "zzz", "Hillcrest"])) : garbage()]
        case "get_job", "compare_past_jobs", "open_in_maps": a = ["job": job, "directions": .bool(chance(0.5))]
        case "get_estimate": a = ["job": job, "option": chance(0.7) ? .null : .string(pick(["A", "B", "Z", "Option A"]))]
        case "list_jobs": a = ["stage": chance(0.6) ? .string(pick(Stage.allCases).rawValue) : garbage()]
        case "get_schedule", "add_to_calendar": a = ["start_date": date(), "days": .number(Double(Int.random(in: -3...60, using: &rng))), "job": chance(0.5) ? .null : job]
        case "get_weather": a = ["start_date": date(), "days": .number(Double(Int.random(in: 0...20, using: &rng))), "job": chance(0.5) ? .null : job]
        case "get_customer": a = ["customer": chance(0.7) ? .string(base.customers.first?.name ?? "x") : garbage()]
        case "point_at": a = ["ids": .array([.string(UUID().uuidString), garbage()])]
        case "search_help": a = ["question": .string(pick(["how do I add a line", "where is the schedule", "measure a lot", "??", "invoice paid"]))]
        case "get_help_article": a = ["id": .string(pick(KnowledgeBase.articles.map(\.id) + ["nope"]))]
        case "show_me": a = ["spot": .string(pick(KnowledgeBase.spots.map(\.id) + ["nope"])), "job": chance(0.5) ? .null : job]
        case "open_screen": a = ["screen": .string(pick(["today", "pipeline", "job", "schedule", "settings", "bogus"])), "job": job,
                                 "tab": .string(pick(["estimate", "measure", "logs", "nope"])), "week_of": date()]
        case "update_job": a = ["job": job, "stage": chance(0.5) ? .string(pick(Stage.allCases).rawValue) : .null,
                                "add_note": chance(0.5) ? .string("Torture note \(Int.random(in: 0...999, using: &rng))") : .null,
                                "bid_due": chance(0.3) ? date() : .null, "plant_order": chance(0.2) ? garbage() : .null]
        case "add_daily_log": a = ["job": job, "date": date(), "crew": .string(pick(["Crew A", "Crew B", "Nobody"])),
                                   "tons": .number(Double.random(in: -50...900, using: &rng)), "hours": .number(Double.random(in: 0...200, using: &rng)), "notes": .string("log")]
        case "update_customer": a = ["customer": .string(base.customers.first?.name ?? "x"), "add_note": .string("note"), "phone": chance(0.3) ? garbage() : .null]
        case "draft_email": a = ["customer": .null, "job": job, "subject": .string("Hello"), "body": chance(0.9) ? .string("Body") : garbage()]
        case "draft_text": a = ["customer": .null, "job": job, "body": .string("Text")]
        case "add_estimate_line": a = ["job": job, "option": .null, "rate_id": chance(0.7) ? .string(pick(base.rates.prices.map(\.id) + ["bogus"])) : .null,
                                       "group": .null, "name": .string("Fuzz line"), "qty": chance(0.85) ? .number(Double(Int.random(in: 1...5000, using: &rng))) : garbage(),
                                       "unit": .null, "unit_cost": chance(0.5) ? .number(Double.random(in: 0...50, using: &rng)) : .null]
        case "update_estimate_line": a = ["job": job, "option": .null, "line": lineRef(job), "qty": .number(Double(Int.random(in: 0...9000, using: &rng))),
                                          "unit_cost": chance(0.5) ? .number(Double.random(in: 0...99, using: &rng)) : .null, "name": .null, "unit": .null]
        case "remove_estimate_line": a = ["job": job, "option": .null, "line": lineRef(job)]
        case "set_markup": a = ["job": job, "option": .null, "profit_pct": .number(Double(Int.random(in: -20...150, using: &rng))), "overhead_pct": chance(0.5) ? .number(12) : .null]
        case "set_scope": a = ["job": job, "option": .null, "scope": chance(0.9) ? .string("1. Mill\n2. Pave") : garbage()]
        case "add_estimate_option": a = ["job": job, "title": .string("Fuzz option"), "start_from": .string(pick(["blank", "copy_of_selected", "measurements", "nope"]))]
        case "update_measured_area": a = ["job": job, "area": .string(UUID().uuidString), "depth_inches": .number(3), "name": .null, "work_type": .null]
        case "schedule_job": a = ["job": job, "dates": .array([date(), date()]), "crew": .string(pick(["Crew A", "Crew B", "Nope"])), "start_time": .null, "note": .null]
        case "remove_schedule_days": a = ["job": job, "dates": .array([date()])]
        case "create_invoice": a = ["job": job, "amount": chance(0.5) ? .null : .number(Double.random(in: -10...200_000, using: &rng)), "deposit": .null, "due_days": .null]
        case "mark_invoice_paid": a = ["job": job, "paid_on": .null]
        case "update_rate": a = ["rate_id": .string(pick(base.rates.prices.map(\.id))), "unit_cost": .number(Double.random(in: 0...90, using: &rng))]
        case "create_lead": a = ["name": .string("Fuzz Lead \(Int.random(in: 0...999, using: &rng))"), "customer": .null, "new_customer_name": chance(0.5) ? .string("Fuzz Co") : .null,
                                 "services": .array([.string("sealcoat"), .string("bogus")]), "latitude": .number(40), "longitude": .number(-83)]
        case "create_customer": a = ["name": .string("Fuzz Customer"), "phone": .string("555"), "email": .null]
        case "look_at_map": a = ["job": job, "width_meters": chance(0.7) ? .null : .number(Double.random(in: -100...5000, using: &rng)),
                                 "center_latitude": .null, "center_longitude": .null]
        case "draw_shape": a = ["job": job, "map_id": mapID(job), "kind": .string(pick(["area", "area", "line", "markers", "blob"])),
                                "work_type": chance(0.6) ? .string(pick(WorkType.allCases).rawValue) : .null,
                                "marker_kind": chance(0.5) ? .string(pick(CountKind.allCases).rawValue) : .null,
                                "name": chance(0.5) ? .string("Fuzz area") : .null,
                                "depth_inches": chance(0.7) ? .null : .number(Double.random(in: -5...40, using: &rng)),
                                "points": gridPoints(), "cutouts": chance(0.7) ? .null : .array([gridPoints()])]
        case "reshape_area": a = ["job": job, "area": shapeRef(job), "map_id": mapID(job),
                                  "points": chance(0.8) ? gridPoints() : .null, "cutouts": chance(0.7) ? .null : .array([])]
        case "delete_shape": a = ["job": job, "area": shapeRef(job)]
        case "update_settings": a = ["company_name": chance(0.5) ? .string("Fuzz Paving") : .null,
                                     "paving_min_f": chance(0.5) ? .number(Double.random(in: 0...120, using: &rng)) : .null,
                                     "escalation_clause": .bool(chance(0.5)),
                                     "crew": chance(0.3) ? ["id": .null, "name": "Fuzz Crew", "kind": "Paving", "people": 3, "equipment": .null] : .null]
        default: break
        }
        if chance(0.05) { a[pick(Array(a.keys) + ["extra"])] = garbage() }
        return (name, JSONValue.object(a).compactString)
    }
}
#endif
