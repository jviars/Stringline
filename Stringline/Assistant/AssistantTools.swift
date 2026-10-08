import Foundation

enum AssistantMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case chat, action
    var id: String { rawValue }
    var label: String { self == .chat ? "Chat" : "Action" }
}

/// Parts of the app Action mode may change. Each can be turned off in Settings › AI assistant.
enum ToolArea: String, Codable, CaseIterable, Identifiable, Hashable {
    case estimates, jobs, schedule, customers, money, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .estimates: "Estimates, and drawing on the map"
        case .jobs: "Leads, job details, stages and daily logs"
        case .schedule: "The schedule and crew days"
        case .customers: "Customers and Mail drafts"
        case .money: "Invoices and your rates"
        case .settings: "Settings: company, weather rules, proposal wording, crews"
        }
    }

    /// The areas before settings could be changed, for reading older preferences.
    static let original: Set<ToolArea> = [.estimates, .jobs, .schedule, .customers, .money]
}

/// A screen the assistant can open. Job tabs use JobTab's raw values.
enum Destination: Hashable {
    case today, pipeline, measure, jobs, schedule(week: Date?), customers(UUID?), invoices, settings, learn
    case settingsSection(String)
    case job(UUID, tab: String)
}

/// Something outside Stringline the assistant can open.
enum ExternalAction: Hashable {
    case maps(name: String, address: String, lat: Double?, lon: Double?, directions: Bool)
}

/// A button the assistant offers instead of acting: open a screen, show a spot, or open Maps.
struct Suggestion: Hashable {
    var destination: Destination?
    var label: String
    var spot: String? = nil
    var external: ExternalAction? = nil
}

struct DriveInfo: Hashable {
    let minutes: Double
    let miles: Double
}

struct PlaceFound: Hashable {
    let name: String
    let address: String
    let coordinate: Coordinate
}

/// Apple services the assistant can ask: MapKit in the app, stand-ins in tests.
@MainActor
protocol AssistantServices: AnyObject {
    func driveTime(from: Coordinate, to: Coordinate) async throws -> DriveInfo
    func findPlaces(_ query: String, near: Coordinate?) async -> [PlaceFound]
    /// A satellite picture of `frame` with its grid and `shapes` drawn on, as a JPEG data URL.
    func mapPicture(_ frame: MapFrame, shapes: [TakeoffShape]) async throws -> String
}

/// Where the person is, so "show me" knows what's already on screen.
struct RunnerContext: Hashable {
    var screen = "today"
    var jobID: UUID?
    var jobTab: String?
    var panelOpen = true
}

struct ToolSpec {
    enum Kind: Equatable { case read, navigate, write(ToolArea) }
    let name: String
    let description: String
    let parameters: JSONValue
    let kind: Kind

    func json(strict: Bool) -> JSONValue {
        ["type": "function", "name": .string(name), "description": .string(description), "parameters": parameters, "strict": .bool(strict)]
    }

    /// The group a tool is sent in. ChatGPT plan requests only take function tools grouped like this.
    var namespace: String { Self.groups.first { $0.tools.contains(name) }?.name ?? "app" }

    static let groups: [(name: String, description: String, tools: Set<String>)] = [
        ("lookup", "Read the owner's jobs, customers, estimates, schedule, weather, rates and invoices.",
         ["search", "get_job", "get_estimate", "list_jobs", "get_schedule", "get_weather", "get_customer", "get_rates", "get_invoices", "compare_past_jobs"]),
        ("help", "Stringline's built-in help, and moving or pointing around the app's screens.",
         ["search_help", "get_help_article", "show_me", "point_at", "open_screen"]),
        ("maps", "Apple Maps, and looking at a job's lot from above.", ["open_in_maps", "drive_time", "find_place", "look_at_map"]),
        ("jobs", "Leads, job details, stages and daily logs.", ["create_lead", "update_job", "add_daily_log"]),
        ("customers", "Customers, and email or text drafts the owner sends.", ["create_customer", "update_customer", "draft_email", "draft_text"]),
        ("estimates", "Estimate lines, options, markup and scope of work.",
         ["add_estimate_line", "update_estimate_line", "remove_estimate_line", "set_markup", "set_scope", "add_estimate_option"]),
        ("measure", "Drawing and changing measured areas, lines and markers on a job's map.",
         ["update_measured_area", "draw_shape", "reshape_area", "delete_shape"]),
        ("schedule", "The crew schedule and Apple Calendar.", ["schedule_job", "remove_schedule_days", "add_to_calendar"]),
        ("money", "Invoices and the price list.", ["create_invoice", "mark_invoice_paid", "update_rate"]),
        ("settings", "Company details, proposal wording, weather rules and backups.", ["update_settings"]),
    ]
}

/// How function tools are sent. ChatGPT plan requests want them in namespaces (or an additional_tools input item);
/// API-key requests take the plain list. Stringline moves on to the next form if one is refused.
enum ToolFormat: String, CaseIterable {
    case namespaces, additionalTools, flat

    static func tools(_ specs: [ToolSpec], format: ToolFormat, strict: Bool) -> [JSONValue] {
        switch format {
        case .flat:
            return specs.map { $0.json(strict: strict) }
        case .namespaces, .additionalTools:
            var order: [String] = []
            var grouped: [String: [JSONValue]] = [:]
            for spec in specs {
                if grouped[spec.namespace] == nil { order.append(spec.namespace) }
                grouped[spec.namespace, default: []].append(spec.json(strict: strict))
            }
            return order.map { name in
                let description = ToolSpec.groups.first { $0.name == name }?.description ?? "Stringline."
                return ["type": "namespace", "name": .string(name), "description": .string(description), "tools": .array(grouped[name] ?? [])]
            }
        }
    }
}

struct ToolOutcome {
    var output: JSONValue
    var activity: String
    var icon = "magnifyingglass"
    var navigate: Destination?
    var suggestion: Suggestion?
    var highlight: [UUID] = []
    var spotlight: String?
    var external: ExternalAction?
    /// A picture for the model to look at (data URL), sent with the tool's result.
    var image: String?
    var isError = false

    /// `message` goes back to the model; `shown` is what the person sees in the panel, when it should read differently.
    static func failure(_ message: String, shown: String? = nil) -> ToolOutcome {
        ToolOutcome(output: ["error": .string(message)], activity: shown ?? message, icon: "exclamationmark.triangle", isError: true)
    }
}

struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Schemas

enum Schema {
    static func object(_ properties: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var props: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for (key, value) in properties {
            props[key] = value
            required.append(.string(key))
        }
        return ["type": "object", "properties": .object(props), "required": .array(required), "additionalProperties": false]
    }
    static let empty: JSONValue = ["type": "object", "properties": [:], "required": [], "additionalProperties": false]
    static func string(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
    static func optString(_ d: String) -> JSONValue { ["type": ["string", "null"], "description": .string(d)] }
    static func number(_ d: String) -> JSONValue { ["type": "number", "description": .string(d)] }
    static func optNumber(_ d: String) -> JSONValue { ["type": ["number", "null"], "description": .string(d)] }
    static func integer(_ d: String) -> JSONValue { ["type": "integer", "description": .string(d)] }
    static func optInteger(_ d: String) -> JSONValue { ["type": ["integer", "null"], "description": .string(d)] }
    static func optBool(_ d: String) -> JSONValue { ["type": ["boolean", "null"], "description": .string(d)] }
    static func choice(_ values: [String], _ d: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(d)]
    }
    static func optChoice(_ values: [String], _ d: String) -> JSONValue {
        ["type": ["string", "null"], "enum": .array(values.map { .string($0) } + [.null]), "description": .string(d)]
    }
    static func list(_ item: JSONValue, _ d: String) -> JSONValue { ["type": "array", "items": item, "description": .string(d)] }
    static func optList(_ item: JSONValue, _ d: String) -> JSONValue { ["type": ["array", "null"], "items": item, "description": .string(d)] }
    static let date = "A date as YYYY-MM-DD."
}

// MARK: - Arguments

struct ToolArgs {
    let json: JSONValue

    private func raw(_ key: String) -> JSONValue? {
        guard let v = json[key], v != .null else { return nil }
        return v
    }

    /// One line of text, trimmed and capped. Empty counts as missing.
    func string(_ key: String, max: Int = 300) -> String? {
        guard let s = raw(key)?.string ?? raw(key)?.double.map({ Fmt.plain($0) }) else { return nil }
        let t = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        return t.isEmpty ? nil : t
    }

    func text(_ key: String, max: Int = 4000) -> String? { string(key, max: max) }

    func required(_ key: String, max: Int = 300) throws -> String {
        guard let s = string(key, max: max) else { throw ToolError("“\(key)” is required.") }
        return s
    }

    func double(_ key: String) -> Double? {
        guard let v = raw(key) else { return nil }
        let d = v.double ?? v.string.flatMap { Double($0.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")) }
        return d.flatMap { $0.isFinite ? $0 : nil }
    }

    func int(_ key: String) -> Int? { double(key).map { Int($0.rounded()) } }
    func bool(_ key: String) -> Bool? { raw(key)?.bool }
    /// The raw value, or nil when it's missing or null.
    func value(_ key: String) -> JSONValue? { raw(key) }
    func strings(_ key: String) -> [String]? { raw(key)?.array?.compactMap { $0.string } }

    func date(_ key: String, today: Date) throws -> Date? {
        guard let s = string(key, max: 40) else { return nil }
        return try ToolArgs.parseDate(s, today: today)
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        return f
    }()

    static func parseDate(_ s: String, today: Date) throws -> Date {
        guard let d = dayFormat.date(from: String(s.prefix(10))) else { throw ToolError("“\(s)” isn't a date. Use YYYY-MM-DD.") }
        let day = d.startOfDay
        guard abs(Calendar.current.daysBetween(today, day)) <= 366 * 3 else { throw ToolError("\(s) is too far from today.") }
        return day
    }

    static func iso(_ d: Date?) -> JSONValue { d.map { .string(dayFormat.string(from: $0)) } ?? .null }
}

// MARK: - Runner

/// Runs the assistant's tool calls. Reads come from the real data plus anything already proposed;
/// writes are only proposed here and never touch the real data.
@MainActor
final class ToolRunner {
    let base: AssistantDataSource
    let mode: AssistantMode
    let areas: Set<ToolArea>
    let shareContact: Bool
    let today: Date
    let services: AssistantServices?
    var context: RunnerContext
    /// False once ChatGPT has refused a picture from Stringline, so look_at_map says so instead of trying again.
    var picturesAllowed = true
    private(set) var draft: DraftState
    private(set) var proposed: [ProposedChange] = []

    static let asyncTools: Set<String> = ["drive_time", "find_place", "look_at_map"]

    init(base: AssistantDataSource, mode: AssistantMode, areas: Set<ToolArea>, shareContact: Bool,
         today: Date = Date().startOfDay, pending: [ChangeOp] = [], services: AssistantServices? = nil,
         context: RunnerContext = RunnerContext()) {
        self.base = base
        self.mode = mode
        self.areas = areas
        self.shareContact = shareContact
        self.today = today.startOfDay
        self.services = services
        self.context = context
        draft = DraftState.replay(pending, base: base).state
    }

    // MARK: Specs

    static func specs(mode: AssistantMode, areas: Set<ToolArea>) -> [ToolSpec] {
        allSpecs(mode: mode).filter { spec in
            if case .write(let area) = spec.kind { return mode == .action && areas.contains(area) }
            return true
        }
    }

    static func allSpecs(mode: AssistantMode) -> [ToolSpec] {
        let jobRef = Schema.string("A job id, job number or exact job name.")
        let optJobRef = Schema.optString("A job id, job number or exact job name, or null.")
        let optionRef = Schema.optString("Estimate option id or letter (A, B…). null means the selected option.")
        let stages = Stage.allCases.map(\.rawValue)
        let services = Service.allCases.map(\.rawValue)
        let tabs = ["overview", "measure", "estimate", "schedule", "logs", "photos", "invoice"]
        let groups = EstimateOption.groups
        let point: JSONValue = ["type": "array", "items": ["type": "number"], "description": "[x, y] on the picture's 0–1000 grid."]
        let ring: JSONValue = ["type": "array", "items": point, "description": "The corners of one cutout, in order."]
        return [
            ToolSpec(name: "search", description: "Find jobs and customers by name, address, job number or contact person.",
                     parameters: Schema.object(["query": Schema.string("What to look for.")]), kind: .read),
            ToolSpec(name: "get_job", description: "One job in full: customer, stage, dates, notes, schedule, 811 ticket, measured areas (with ids), estimate options, invoice and recent daily logs.",
                     parameters: Schema.object(["job": jobRef]), kind: .read),
            ToolSpec(name: "get_estimate", description: "An estimate option's line items (with ids), markup, cost, bid price, price per SY and scope of work.",
                     parameters: Schema.object(["job": jobRef, "option": optionRef]), kind: .read),
            ToolSpec(name: "list_jobs", description: "Jobs in the pipeline with stage, customer, price and bid due date. Optionally one stage only.",
                     parameters: Schema.object(["stage": Schema.optChoice(stages, "Only this stage, or null for all.")]), kind: .read),
            ToolSpec(name: "get_schedule", description: "Crew days for a range of dates, with each day's go/no-go weather call.",
                     parameters: Schema.object(["start_date": Schema.string(Schema.date), "days": Schema.integer("How many days, 1 to 21.")]), kind: .read),
            ToolSpec(name: "get_weather", description: "Forecast (about 14 days ahead) judged by the owner's weather rules. With a job, uses that job's rule (paving or sealcoat).",
                     parameters: Schema.object(["start_date": Schema.string(Schema.date), "days": Schema.integer("1 to 14."), "job": optJobRef]), kind: .read),
            ToolSpec(name: "get_customer", description: "One customer and their jobs.",
                     parameters: Schema.object(["customer": Schema.string("A customer id or exact name.")]), kind: .read),
            ToolSpec(name: "get_rates", description: "The owner's price list (with rate ids), quantity factors and default markup.",
                     parameters: Schema.empty, kind: .read),
            ToolSpec(name: "get_invoices", description: "Every invoice with amount, balance, due date and days late.",
                     parameters: Schema.empty, kind: .read),
            ToolSpec(name: "compare_past_jobs", description: "Compare a job's price per SY with the owner's recent won jobs of the same kind.",
                     parameters: Schema.object(["job": jobRef]), kind: .read),
            ToolSpec(name: "point_at", description: "Highlight estimate lines, schedule days or jobs on the owner's screen so they can see what you mean.",
                     parameters: Schema.object(["ids": Schema.list(["type": "string"], "Line, schedule day or job ids.")]), kind: .read),
            ToolSpec(name: "search_help", description: "Search Stringline's built-in help for how to do something or where something is. Use it for every how-to or where-is question before answering, and answer from what it returns.",
                     parameters: Schema.object(["question": Schema.string("The owner's question in their words.")]), kind: .read),
            ToolSpec(name: "get_help_article", description: "Read one help article in full by its id.",
                     parameters: Schema.object(["id": Schema.string("Article id from search_help.")]), kind: .read),
            ToolSpec(name: "show_me",
                     description: mode == .chat
                        ? "Point at a place in Stringline with a pulsing ring. If it's on the screen they have open, it shows right away; otherwise they get a Show me button."
                        : "Point at a place in Stringline with a pulsing ring, opening the right screen first if needed.",
                     parameters: Schema.object([
                        "spot": Schema.choice(KnowledgeBase.spots.map(\.id), "Which place, from a help article's show_me_spots."),
                        "job": optJobRef,
                     ]), kind: .navigate),
            ToolSpec(name: "open_in_maps",
                     description: mode == .chat ? "Offer a button that opens a job in Apple Maps, optionally with driving directions." : "Open a job in Apple Maps, optionally with driving directions.",
                     parameters: Schema.object(["job": jobRef, "directions": ["type": "boolean", "description": "true for driving directions."]]), kind: .navigate),
            ToolSpec(name: "drive_time", description: "Driving time and distance from the owner's home base to a job, from Apple Maps.",
                     parameters: Schema.object(["job": jobRef]), kind: .read),
            ToolSpec(name: "find_place", description: "Look up an address or business with Apple Maps. Returns names, addresses and map coordinates.",
                     parameters: Schema.object(["query": Schema.string("An address, business name or intersection.")]), kind: .read),
            ToolSpec(name: "open_screen",
                     description: mode == .chat
                        ? "Offer the owner a button that opens a screen. It doesn't move them; they click it if they want."
                        : "Take the owner to a screen. Use it before changing something they can't see, so they watch it happen.",
                     parameters: Schema.object([
                        "screen": Schema.choice(["today", "pipeline", "measure", "jobs", "schedule", "customers", "invoices", "settings", "job"], "Which screen."),
                        "job": optJobRef,
                        "tab": Schema.optChoice(tabs, "For screen job: which tab."),
                        "week_of": Schema.optString("For screen schedule: any date in the week, YYYY-MM-DD."),
                     ]), kind: .navigate),

            ToolSpec(name: "create_lead", description: "Add a new job as a lead, for an existing customer or a new one.",
                     parameters: Schema.object([
                        "name": Schema.string("Job name, usually the property, e.g. Maple Ridge Plaza."),
                        "customer": Schema.optString("Existing customer id or exact name, or null."),
                        "new_customer_name": Schema.optString("Name for a new customer when there isn't one yet, or null."),
                        "contact": Schema.optString("New customer's contact person, or null."),
                        "address": Schema.optString("Job address, or null."),
                        "job_type": Schema.optChoice(CustomerType.allCases.map(\.rawValue), "commercial, residential, hoa or publicBid."),
                        "services": Schema.optList(Schema.choice(services, "A service."), "Services, or null."),
                        "source": Schema.optString("How the lead came in, or null."),
                        "notes": Schema.optString("Notes, or null."),
                        "bid_due": Schema.optString("Bid due date YYYY-MM-DD, or null."),
                        "latitude": Schema.optNumber("Map latitude from find_place, so Measure opens on the lot."),
                        "longitude": Schema.optNumber("Map longitude from find_place."),
                     ]), kind: .write(.jobs)),
            ToolSpec(name: "update_job", description: "Change a job's details, stage, dates, notes, plant order or 811 ticket. Leave anything that shouldn't change as null.",
                     parameters: Schema.object([
                        "job": jobRef,
                        "name": Schema.optString("New name."),
                        "address": Schema.optString("New address."),
                        "stage": Schema.optChoice(stages, "New pipeline stage."),
                        "services": Schema.optList(Schema.choice(services, "A service."), "Replace the services list."),
                        "bid_due": Schema.optString("YYYY-MM-DD."),
                        "site_visit": Schema.optString("YYYY-MM-DD."),
                        "add_note": Schema.optString("Text added to the end of the job's notes."),
                        "plant_order": Schema.optString("The plant order note."),
                        "ticket_number": Schema.optString("811 ticket number."),
                        "ticket_good_until": Schema.optString("811 ticket expiry, YYYY-MM-DD."),
                        "ticket_not_needed": Schema.optBool("true when the job needs no 811 ticket."),
                        "completed_on": Schema.optString("Date the work was finished, YYYY-MM-DD."),
                        "lost_reason": Schema.optString("Why the bid was lost."),
                     ]), kind: .write(.jobs)),
            ToolSpec(name: "add_daily_log", description: "Add a daily log to a job: tons placed, crew hours and notes.",
                     parameters: Schema.object([
                        "job": jobRef, "date": Schema.string(Schema.date),
                        "crew": Schema.optString("Crew id or name, or null."),
                        "tons": Schema.optNumber("Tons placed."), "hours": Schema.optNumber("Crew hours."),
                        "notes": Schema.optString("Notes."),
                     ]), kind: .write(.jobs)),
            ToolSpec(name: "create_customer", description: "Add a customer.",
                     parameters: Schema.object([
                        "name": Schema.string("Company or person."), "contact": Schema.optString("Contact person."),
                        "phone": Schema.optString("Phone."), "email": Schema.optString("Email."), "address": Schema.optString("Address."),
                        "type": Schema.optChoice(CustomerType.allCases.map(\.rawValue), "Customer type."),
                     ]), kind: .write(.customers)),
            ToolSpec(name: "update_customer", description: "Change a customer's details or add a note. Leave anything that shouldn't change as null.",
                     parameters: Schema.object([
                        "customer": Schema.string("Customer id or exact name."),
                        "name": Schema.optString("New name."), "contact": Schema.optString("Contact person."),
                        "phone": Schema.optString("Phone."), "email": Schema.optString("Email."), "address": Schema.optString("Address."),
                        "add_note": Schema.optString("Text added to the customer's notes."),
                     ]), kind: .write(.customers)),
            ToolSpec(name: "draft_email", description: "Prepare an email to a customer. Stringline opens it as a Mail draft only if the owner ticks it and applies; the owner sends it themselves.",
                     parameters: Schema.object([
                        "customer": Schema.optString("Customer id or exact name. null to use the job's customer."),
                        "job": optJobRef,
                        "subject": Schema.string("Subject line."),
                        "body": Schema.string("The email, signed with the company name."),
                     ]), kind: .write(.customers)),
            ToolSpec(name: "add_estimate_line", description: "Add a line to an estimate option. Prefer a rate_id from get_rates; then name, unit and unit_cost come from the price list unless given.",
                     parameters: Schema.object([
                        "job": jobRef, "option": optionRef,
                        "rate_id": Schema.optString("A rate id from get_rates, or null."),
                        "group": Schema.optChoice(groups, "Which group. null picks one from the rate."),
                        "name": Schema.optString("Line name."),
                        "qty": Schema.number("Quantity."),
                        "unit": Schema.optString("Unit, e.g. ton, SY, LF, hr, day, LS."),
                        "unit_cost": Schema.optNumber("Dollars per unit."),
                     ]), kind: .write(.estimates)),
            ToolSpec(name: "update_estimate_line", description: "Change an estimate line's name, quantity, unit or unit cost. Leave anything that shouldn't change as null.",
                     parameters: Schema.object([
                        "job": jobRef, "option": optionRef,
                        "line": Schema.string("Line id (or exact line name)."),
                        "name": Schema.optString("New name."), "qty": Schema.optNumber("New quantity."),
                        "unit": Schema.optString("New unit."), "unit_cost": Schema.optNumber("New dollars per unit."),
                     ]), kind: .write(.estimates)),
            ToolSpec(name: "remove_estimate_line", description: "Remove a line from an estimate option.",
                     parameters: Schema.object(["job": jobRef, "option": optionRef, "line": Schema.string("Line id (or exact line name).")]),
                     kind: .write(.estimates)),
            ToolSpec(name: "set_markup", description: "Set an estimate option's profit and/or overhead percent. Profit is on cost plus overhead.",
                     parameters: Schema.object([
                        "job": jobRef, "option": optionRef,
                        "profit_pct": Schema.optNumber("Profit percent, 0 to 100."), "overhead_pct": Schema.optNumber("Overhead percent, 0 to 100."),
                     ]), kind: .write(.estimates)),
            ToolSpec(name: "set_scope", description: "Replace an estimate option's scope of work. One step per line; this is what the customer reads.",
                     parameters: Schema.object(["job": jobRef, "option": optionRef, "scope": Schema.string("The full scope of work.")]),
                     kind: .write(.estimates)),
            ToolSpec(name: "add_estimate_option", description: "Add an estimate option and select it: built from the measurements, a copy of the selected option, or blank.",
                     parameters: Schema.object([
                        "job": jobRef, "title": Schema.string("Option title, e.g. Mill & overlay."),
                        "start_from": Schema.choice(["measurements", "copy_of_selected", "blank"], "What to start from."),
                     ]), kind: .write(.estimates)),
            ToolSpec(name: "update_measured_area", description: "Rename a measured area or change its depth or work type. The estimate's measured lines follow when the owner presses Update from measurements.",
                     parameters: Schema.object([
                        "job": jobRef, "area": Schema.string("Measured area id (from get_job) or exact name."),
                        "name": Schema.optString("New name."), "depth_inches": Schema.optNumber("New depth in inches."),
                        "work_type": Schema.optChoice(WorkType.allCases.map(\.rawValue), "New work type."),
                     ]), kind: .write(.estimates)),
            ToolSpec(name: "look_at_map", description: "See a job's lot from above: a satellite picture of the job's map, north up, with a 0–1000 grid across and down and the shapes already measured drawn on it (their corners are listed in grid numbers). Use it before drawing or fixing anything on the map, and pass its map_id to draw_shape or reshape_area.",
                     parameters: Schema.object([
                        "job": jobRef,
                        "width_meters": Schema.optNumber("How wide the picture is, 40 to 1500 meters. null keeps the job's map view (or about 250 m). Smaller shows more detail."),
                        "center_latitude": Schema.optNumber("Center the picture here instead (from find_place, or to move over), or null."),
                        "center_longitude": Schema.optNumber("Goes with center_latitude, or null."),
                     ]), kind: .read),
            ToolSpec(name: "draw_shape", description: "Draw on a job's map from a look_at_map picture: an area (mill and overlay, new paving, patches, sealcoat), a line (striping, crack seal, curb) or markers (stalls, ADA spaces, arrows). Points are [x, y] grid numbers on that picture. Trace the pavement's edge corner by corner, and leave out buildings and grass islands as cutouts.",
                     parameters: Schema.object([
                        "job": jobRef,
                        "map_id": Schema.string("map_id of the look_at_map picture the points are on."),
                        "kind": Schema.choice(["area", "line", "markers"], "What to draw."),
                        "work_type": Schema.optChoice(WorkType.allCases.map(\.rawValue), "Area: millOverlay, newPaving, fullDepthPatch or sealcoat. Line: striping, crackSeal or curb. null for markers or the usual."),
                        "marker_kind": Schema.optChoice(CountKind.allCases.map(\.rawValue), "For markers: stall, ada, arrow or other."),
                        "name": Schema.optString("A short name, e.g. Main lot, or null."),
                        "depth_inches": Schema.optNumber("Depth for mill and overlay, new paving or patches; null for the usual."),
                        "points": Schema.list(point, "Corners in order around the outline (area), along the line (line), or one per marker."),
                        "cutouts": Schema.optList(ring, "For an area: islands or buildings to leave out, or null."),
                     ]), kind: .write(.estimates)),
            ToolSpec(name: "reshape_area", description: "Fix a measured area or line that's already on the map: a new outline and/or new cutouts, in grid numbers on a look_at_map picture.",
                     parameters: Schema.object([
                        "job": jobRef,
                        "area": Schema.string("Measured shape id (from look_at_map or get_job) or exact name."),
                        "map_id": Schema.string("map_id of the look_at_map picture the points are on."),
                        "points": Schema.optList(point, "The whole new outline (or line), corners in order, or null to keep it."),
                        "cutouts": Schema.optList(ring, "Replace the cutouts ([] removes them), or null to keep them."),
                     ]), kind: .write(.estimates)),
            ToolSpec(name: "delete_shape", description: "Remove a measured area, line or marker from a job's map.",
                     parameters: Schema.object(["job": jobRef, "area": Schema.string("Measured shape id or exact name.")]),
                     kind: .write(.estimates)),
            ToolSpec(name: "schedule_job", description: "Put a job on the schedule for one or more days with a crew. Check get_weather first. Only won jobs go on the schedule, so this also marks it Won.",
                     parameters: Schema.object([
                        "job": jobRef,
                        "dates": Schema.list(Schema.string(Schema.date), "Each work day."),
                        "crew": Schema.optString("Crew id or name. null picks the usual crew for the work."),
                        "start_time": Schema.optString("Start time like 7:00 AM, or null."),
                        "note": Schema.optString("Note for these days, e.g. Mill day."),
                     ]), kind: .write(.schedule)),
            ToolSpec(name: "remove_schedule_days", description: "Take days off the schedule for a job.",
                     parameters: Schema.object(["job": jobRef, "dates": Schema.list(Schema.string(Schema.date), "Days to remove.")]),
                     kind: .write(.schedule)),
            ToolSpec(name: "add_to_calendar", description: "Hand scheduled crew days to Apple Calendar. The owner must tick this; Calendar then asks which calendar to add them to.",
                     parameters: Schema.object([
                        "start_date": Schema.string(Schema.date), "days": Schema.integer("How many days from the start, 1 to 31."),
                        "job": optJobRef,
                     ]), kind: .write(.schedule)),
            ToolSpec(name: "draft_text", description: "Prepare a text message to a customer's phone on file. It opens in Messages only if the owner ticks it and applies; the owner sends it.",
                     parameters: Schema.object([
                        "customer": Schema.optString("Customer id or exact name. null to use the job's customer."),
                        "job": optJobRef,
                        "body": Schema.string("The text. Short and friendly, signed with the company name."),
                     ]), kind: .write(.customers)),
            ToolSpec(name: "create_invoice", description: "Create the job's invoice. Amount defaults to the selected estimate's price.",
                     parameters: Schema.object([
                        "job": jobRef, "amount": Schema.optNumber("Dollars, or null for the bid price."),
                        "deposit": Schema.optNumber("Deposit already paid, dollars."), "due_days": Schema.optInteger("Days until due, default 30."),
                     ]), kind: .write(.money)),
            ToolSpec(name: "mark_invoice_paid", description: "Mark a job's invoice paid. The owner must tick this before it applies.",
                     parameters: Schema.object(["job": jobRef, "paid_on": Schema.optString("YYYY-MM-DD, null for today.")]),
                     kind: .write(.money)),
            ToolSpec(name: "update_rate", description: "Change a unit price in the owner's price list. The owner must tick this before it applies. Existing estimates keep their prices.",
                     parameters: Schema.object(["rate_id": Schema.string("Rate id from get_rates."), "unit_cost": Schema.number("New dollars per unit.")]),
                     kind: .write(.money)),
            ToolSpec(name: "update_settings", description: "Change Stringline's settings: company details, home base, weather rules, proposal wording, nightly backups, or add or change a crew. Leave anything that shouldn't change as null. The owner must tick it before it applies.",
                     parameters: Schema.object([
                        "company_name": Schema.optString("Company name."), "phone": Schema.optString("Phone."), "email": Schema.optString("Email."),
                        "address": Schema.optString("Mailing address."), "license": Schema.optString("License number."), "website": Schema.optString("Website."),
                        "home_base": Schema.optString("Home base (the yard), as a place name."),
                        "home_latitude": Schema.optNumber("Home base latitude, e.g. from find_place."), "home_longitude": Schema.optNumber("Home base longitude."),
                        "paving_min_f": Schema.optNumber("Lowest temperature for paving, °F."), "sealcoat_min_f": Schema.optNumber("Lowest temperature for sealcoat, °F."),
                        "sealcoat_dry_hours": Schema.optInteger("Hours sealcoat needs to stay dry."), "rain_chance_max": Schema.optInteger("Highest rain chance that's still a go, percent."),
                        "proposal_valid_days": Schema.optInteger("Days a proposal's prices are good."),
                        "exclusions": Schema.optString("Proposal exclusions."), "terms": Schema.optString("Proposal payment terms."),
                        "escalation_clause": Schema.optBool("Include the asphalt price escalation clause."),
                        "backup_nightly": Schema.optBool("Make a backup every night."),
                        "sealcoat_cycle_years": Schema.optInteger("Years between sealcoats, for reminders."),
                        "crew": ["type": ["object", "null"], "description": "A crew to add or change, or null.", "properties": [
                            "id": Schema.optString("An existing crew's id or name to change it; null adds a new crew."),
                            "name": Schema.optString("Crew name."), "kind": Schema.optString("What the crew does, e.g. Paving."),
                            "people": Schema.optInteger("How many people."), "equipment": Schema.optString("Equipment."),
                        ], "required": ["id", "name", "kind", "people", "equipment"], "additionalProperties": false],
                     ]), kind: .write(.settings)),
        ]
    }

    // MARK: Running

    func run(name: String, arguments: String) -> ToolOutcome {
        guard let spec = Self.allSpecs(mode: mode).first(where: { $0.name == name }) else {
            return .failure("There's no tool called \(name).")
        }
        if case .write(let area) = spec.kind {
            guard mode == .action else {
                return .failure("Chat mode can't change anything. Tell the owner they can switch to Action mode to make this change.",
                                shown: "Chat mode can't make changes")
            }
            guard areas.contains(area) else {
                return .failure("The owner has turned off changes to \(area.label.lowercased()) in Settings › AI assistant.",
                                shown: "Changes to \(area.label.lowercased()) are turned off in Settings")
            }
        }
        let args: ToolArgs
        do {
            args = ToolArgs(json: try JSONValue.parse(arguments.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : arguments))
        } catch {
            return .failure("The tool arguments weren't valid JSON.")
        }
        do {
            return try dispatch(name, args)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Runs any tool, including the ones that ask Apple's services and have to wait.
    func runAsync(name: String, arguments: String) async -> ToolOutcome {
        guard Self.asyncTools.contains(name) else { return run(name: name, arguments: arguments) }
        guard let services else { return .failure("Apple Maps lookups aren't available right now.") }
        let a = ToolArgs(json: (try? JSONValue.parse(arguments.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : arguments)) ?? [:])
        do {
            switch name {
            case "drive_time": return try await driveTime(a, services)
            case "look_at_map": return try await lookAtMap(a, services)
            default: return try await findPlace(a, services)
            }
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? "Apple Maps couldn't work that out: \(error.localizedDescription)")
        }
    }

    private func dispatch(_ name: String, _ a: ToolArgs) throws -> ToolOutcome {
        switch name {
        case "search": return try search(a)
        case "get_job": return try getJob(a)
        case "get_estimate": return try getEstimate(a)
        case "list_jobs": return listJobs(a)
        case "get_schedule": return try getSchedule(a)
        case "get_weather": return try getWeather(a)
        case "get_customer": return try getCustomer(a)
        case "get_rates": return getRates()
        case "get_invoices": return getInvoices()
        case "compare_past_jobs": return try comparePastJobs(a)
        case "point_at": return pointAt(a)
        case "search_help": return try searchHelp(a)
        case "get_help_article": return try getHelpArticle(a)
        case "show_me": return try showMe(a)
        case "open_in_maps": return try openInMaps(a)
        case "add_to_calendar": return try addToCalendar(a)
        case "draft_text": return try draftText(a)
        case "open_screen": return try openScreen(a)
        case "create_lead": return try createLead(a)
        case "update_job": return try updateJob(a)
        case "add_daily_log": return try addDailyLog(a)
        case "create_customer": return try createCustomer(a)
        case "update_customer": return try updateCustomer(a)
        case "draft_email": return try draftEmail(a)
        case "add_estimate_line": return try addLine(a)
        case "update_estimate_line": return try updateLine(a)
        case "remove_estimate_line": return try removeLine(a)
        case "set_markup": return try setMarkup(a)
        case "set_scope": return try setScope(a)
        case "add_estimate_option": return try addOption(a)
        case "update_measured_area": return try updateArea(a)
        case "draw_shape": return try drawShape(a)
        case "reshape_area": return try reshapeArea(a)
        case "delete_shape": return try deleteShape(a)
        case "update_settings": return try updateSettings(a)
        case "schedule_job": return try scheduleJob(a)
        case "remove_schedule_days": return try removeDays(a)
        case "create_invoice": return try createInvoice(a)
        case "mark_invoice_paid": return try markPaid(a)
        case "update_rate": return try updateRate(a)
        case _ where Self.asyncTools.contains(name): throw ToolError("\(name) needs Apple Maps; try again.")
        default: throw ToolError("There's no tool called \(name).")
        }
    }

    /// Hands over the changes proposed since the last call. The draft keeps them, so later tools see them.
    func takeProposed() -> [ProposedChange] {
        defer { proposed = [] }
        return proposed
    }

    // MARK: Lookups

    var allJobs: [Job] { draft.allJobs(base) }
    var allCustomers: [Customer] { draft.allCustomers(base) }

    func customerName(_ job: Job) -> String {
        job.customerID.flatMap { draft.customer($0, base) }?.name ?? "No customer"
    }

    func resolveJob(_ ref: String?) throws -> Job {
        guard let ref, !ref.isEmpty else { throw ToolError("Say which job.") }
        let jobs = allJobs
        if let id = UUID(uuidString: ref), let j = jobs.first(where: { $0.id == id }) { return j }
        if let j = jobs.first(where: { $0.number.caseInsensitiveCompare(ref) == .orderedSame }) { return j }
        let named = jobs.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return named[0] }
        let partial = jobs.filter { $0.name.localizedCaseInsensitiveContains(ref) }
        if partial.count == 1 { return partial[0] }
        if named.count + partial.count > 1 { throw ToolError("More than one job matches “\(ref)”. Use search, then the job id.") }
        throw ToolError("No job matches “\(ref)”. Use search to find it.")
    }

    func resolveCustomer(_ ref: String?) throws -> Customer {
        guard let ref, !ref.isEmpty else { throw ToolError("Say which customer.") }
        let customers = allCustomers
        if let id = UUID(uuidString: ref), let c = customers.first(where: { $0.id == id }) { return c }
        let named = customers.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame || $0.contact.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return named[0] }
        let partial = customers.filter { $0.name.localizedCaseInsensitiveContains(ref) }
        if partial.count == 1 { return partial[0] }
        throw ToolError(named.count + partial.count > 1 ? "More than one customer matches “\(ref)”." : "No customer matches “\(ref)”.")
    }

    func resolveCrew(_ ref: String?) throws -> Crew? {
        guard let ref, !ref.isEmpty else { return nil }
        let crews = base.settings.crews
        if let id = UUID(uuidString: ref), let c = crews.first(where: { $0.id == id }) { return c }
        if let c = crews.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return c }
        if let c = crews.first(where: { $0.name.localizedCaseInsensitiveContains(ref) || $0.kind.localizedCaseInsensitiveContains(ref) }) { return c }
        throw ToolError("No crew matches “\(ref)”. Crews: \(crews.map(\.name).joined(separator: ", ")).")
    }

    /// The option an argument names, or the selected one.
    func resolveOption(_ job: Job, _ ref: String?) throws -> (estimate: Estimate, index: Int) {
        let e = draft.estimate(job.id, base)
        guard !e.options.isEmpty else {
            throw ToolError("\(job.name) has no estimate yet. Use add_estimate_option first.")
        }
        guard let ref, !ref.isEmpty else {
            let i = e.options.firstIndex { $0.id == e.selectedOptionID } ?? 0
            return (e, i)
        }
        if let id = UUID(uuidString: ref), let i = e.options.firstIndex(where: { $0.id == id }) { return (e, i) }
        let letter = ref.uppercased().replacingOccurrences(of: "OPTION ", with: "")
        if letter.count == 1, let scalar = letter.unicodeScalars.first, scalar.value >= 65 {
            let i = Int(scalar.value) - 65
            if e.options.indices.contains(i) { return (e, i) }
        }
        if let i = e.options.firstIndex(where: { $0.title.caseInsensitiveCompare(ref) == .orderedSame }) { return (e, i) }
        throw ToolError("\(job.name) has no option “\(ref)”.")
    }

    func resolveLine(_ option: EstimateOption, _ ref: String) throws -> LineItem {
        if let id = UUID(uuidString: ref), let l = option.items.first(where: { $0.id == id }) { return l }
        let named = option.items.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return named[0] }
        let partial = option.items.filter { $0.name.localizedCaseInsensitiveContains(ref) }
        if partial.count == 1 { return partial[0] }
        throw ToolError("No single line matches “\(ref)”. Use get_estimate for line ids.")
    }

    static func letter(_ index: Int) -> String { String(UnicodeScalar(65 + min(index, 25))!) }

    // MARK: JSON views

    func jobBrief(_ j: Job) -> JSONValue {
        let price = draft.estimate(j.id, base).selected.flatMap { $0.items.isEmpty ? nil : $0.breakdown.priceCents }
        return ["id": .string(j.id.uuidString), "number": .string(j.number), "name": .string(j.name),
                "customer": .string(customerName(j)), "stage": .string(j.stage.rawValue), "address": .string(j.address),
                "price": price.map { .money($0) } ?? .null, "bid_due": ToolArgs.iso(j.bidDue),
                "sample": .bool(j.isSample), "not_saved_yet": .bool(draft.newJobs.contains(j.id))]
    }

    func customerJSON(_ c: Customer, full: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(c.id.uuidString), "name": .string(c.name), "contact": .string(c.contact), "type": .string(c.type.rawValue)]
        if shareContact {
            o["phone"] = .string(c.phone)
            o["email"] = .string(c.email)
        } else {
            o["has_email"] = .bool(!c.email.isEmpty)
            o["contact_details"] = "hidden by the owner's privacy setting"
        }
        if full {
            o["address"] = .string(c.address)
            o["notes"] = .string(String(c.notes.prefix(2000)))
            o["jobs"] = .array(allJobs.filter { $0.customerID == c.id }.map(jobBrief))
        }
        return .object(o)
    }

    func perSY(_ job: Job, _ option: EstimateOption) -> Double? {
        let sy = Estimator.summary(draft.takeoff(job.id, base), factors: draft.currentRates(base).factors).billableSY
        return sy > 0 ? (Double(option.breakdown.priceCents) / 100 / sy * 100).rounded() / 100 : nil
    }

    func totalsJSON(_ job: Job, _ option: EstimateOption) -> JSONValue {
        let b = option.breakdown
        return ["cost": .money(b.costCents), "overhead": .money(b.overheadCents), "profit": .money(b.profitCents),
                "price": .money(b.priceCents), "margin_pct": .number((b.marginPct * 10).rounded() / 10),
                "per_sy": .from(perSY(job, option))]
    }

    func optionJSON(_ job: Job, _ e: Estimate, _ i: Int, lines: Bool) -> JSONValue {
        let o = e.options[i]
        var out: [String: JSONValue] = [
            "id": .string(o.id.uuidString), "letter": .string(Self.letter(i)), "title": .string(o.title),
            "selected": .bool((e.selectedOptionID ?? e.options.first?.id) == o.id),
            "overhead_pct": .number(o.overheadPct), "profit_pct": .number(o.profitPct), "totals": totalsJSON(job, o),
        ]
        if lines {
            out["lines"] = .array(o.items.map { item in
                ["id": .string(item.id.uuidString), "group": .string(item.group), "name": .string(item.name),
                 "qty": .number(item.qty), "unit": .string(item.unit), "unit_cost": .money(item.unitCents),
                 "total": .money(item.totalCents), "from_measurements": .bool(item.fromTakeoff)]
            })
            out["scope"] = .string(o.scope)
        }
        return .object(out)
    }

    func takeoffJSON(_ t: Takeoff) -> JSONValue {
        let s = Estimator.summary(t, factors: draft.currentRates(base).factors)
        var areas: [String: JSONValue] = [:]
        for (w, sqft) in s.areaSqFt { areas[w.rawValue] = .number((sqft / 9).rounded()) }
        var lines: [String: JSONValue] = [:]
        for (w, ft) in s.lineFt { lines[w.rawValue] = .number(ft.rounded()) }
        var counts: [String: JSONValue] = [:]
        for (k, n) in s.counts { counts[k.rawValue] = .number(Double(n)) }
        let shapes: [JSONValue] = t.shapes.map { shape in
            var o: [String: JSONValue] = ["id": .string(shape.id.uuidString), "name": .string(shape.name),
                                          "kind": .string(shape.kind.rawValue), "work_type": .string(shape.workType.rawValue)]
            switch shape.kind {
            case .area:
                o["area_sy"] = .number((Geo.netAreaSqFt(shape) / 9).rounded())
                if shape.workType.hasDepth { o["depth_in"] = .number(shape.depthInches) }
            case .line: o["length_lf"] = .number(Geo.lengthFt(shape.points).rounded())
            case .count: o["count"] = .number(Double(shape.quantity)); o["count_kind"] = .string(shape.countKind.rawValue)
            }
            return .object(o)
        }
        return ["area_sy_by_work": .object(areas), "length_lf_by_work": .object(lines), "counts": .object(counts),
                "surface_tons": .number(s.surfaceTons.rounded()), "base_tons": .number(s.baseTons.rounded()), "shapes": .array(shapes)]
    }

    func invoiceJSON(_ job: Job, _ inv: Invoice) -> JSONValue {
        ["job_id": .string(job.id.uuidString), "job": .string(job.name), "number": .string(inv.number.isEmpty ? "(assigned when applied)" : inv.number),
         "issued": ToolArgs.iso(inv.issued), "due": ToolArgs.iso(inv.due), "amount": .money(inv.amountCents),
         "deposit": .money(inv.depositCents), "balance": .money(inv.balanceCents), "paid_on": ToolArgs.iso(inv.paidOn), "days_late": .number(Double(inv.daysLate))]
    }

    func callJSON(_ day: Date, job: Job?) -> JSONValue {
        guard let f = base.forecast(for: day) else { return "no forecast for this day" }
        let rules = base.settings.weather
        let call = job.map { WeatherJudge.call(for: $0, on: f, rules) } ?? WeatherJudge.general(f, rules)
        return ["high_f": .number(f.high.rounded()), "low_f": .number(f.low.rounded()), "rain_pct": .number(Double(f.rainChance)),
                "call": .string(call.short), "detail": .string(call.detail)]
    }

    // MARK: Read tools

    private func search(_ a: ToolArgs) throws -> ToolOutcome {
        let q = try a.required("query", max: 120)
        let jobs = allJobs.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q)
                || $0.number.localizedCaseInsensitiveContains(q) || customerName($0).localizedCaseInsensitiveContains(q)
        }
        let customers = allCustomers.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.contact.localizedCaseInsensitiveContains(q) }
        return ToolOutcome(output: ["jobs": .array(jobs.prefix(15).map(jobBrief)), "customers": .array(customers.prefix(15).map { customerJSON($0, full: false) })],
                           activity: "Searched for “\(q)”")
    }

    private func getJob(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let e = draft.estimate(j.id, base)
        let crews = base.settings.crews
        var o: [String: JSONValue] = [
            "id": .string(j.id.uuidString), "number": .string(j.number), "name": .string(j.name), "stage": .string(j.stage.rawValue),
            "stage_since": ToolArgs.iso(j.stageChanged), "type": .string(j.type.rawValue), "services": .array(j.services.map { .string($0.rawValue) }),
            "address": .string(j.address), "source": .string(j.source), "notes": .string(String(j.notes.prefix(3000))),
            "bid_due": ToolArgs.iso(j.bidDue), "site_visit": ToolArgs.iso(j.siteVisit), "sent_on": ToolArgs.iso(j.sentOn),
            "completed_on": ToolArgs.iso(j.completedOn), "lost_reason": .string(j.lostReason), "plant_order": .string(j.plantNote),
            "ticket_811": ["number": .string(j.ticket.number), "good_until": ToolArgs.iso(j.ticket.goodUntil), "not_needed": .bool(j.ticket.notNeeded)],
            "weather_rule": .string(j.followsSealcoatRule ? "sealcoat" : "paving"),
            "schedule": .array(j.schedule.sorted { $0.day < $1.day }.map { entry in
                ["id": .string(entry.id.uuidString), "date": ToolArgs.iso(entry.day), "crew": .string(crews.first { $0.id == entry.crewID }?.name ?? "No crew"),
                 "start": .string(entry.startTime), "note": .string(entry.note)]
            }),
            "measured": takeoffJSON(draft.takeoff(j.id, base)),
            "estimate_options": .array(e.options.indices.map { optionJSON(j, e, $0, lines: false) }),
            "sample_job": .bool(j.isSample), "not_saved_yet": .bool(draft.newJobs.contains(j.id)),
        ]
        if let cid = j.customerID, let c = draft.customer(cid, base) { o["customer"] = customerJSON(c, full: false) }
        if let inv = draft.invoice(j.id, base) { o["invoice"] = invoiceJSON(j, inv) }
        o["daily_logs"] = .array(draft.jobLogs(j.id, base).entries.prefix(5).map { log in
            ["date": ToolArgs.iso(log.day), "tons": .number(log.tons), "hours": .number(log.hours), "notes": .string(String(log.notes.prefix(500)))]
        })
        return ToolOutcome(output: .object(o), activity: "Looked at \(j.name)", icon: "list.clipboard")
    }

    private func getEstimate(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let (e, i) = try resolveOption(j, a.string("option"))
        let others = e.options.indices.filter { $0 != i }.map { optionJSON(j, e, $0, lines: false) }
        return ToolOutcome(output: ["job_id": .string(j.id.uuidString), "job": .string(j.name), "option": optionJSON(j, e, i, lines: true), "other_options": .array(others)],
                           activity: "Looked at \(j.name)'s estimate", icon: "doc.text")
    }

    private func listJobs(_ a: ToolArgs) -> ToolOutcome {
        let stage = a.string("stage").flatMap(Stage.init(rawValue:))
        let jobs = allJobs.filter { stage == nil || $0.stage == stage }.sorted { $0.updated > $1.updated }
        let list: [JSONValue] = jobs.prefix(60).map { j in
            jobBrief(j).setting("days_in_stage", .number(Double(Calendar.current.daysBetween(j.stageChanged, today))))
                .setting("sent_on", ToolArgs.iso(j.sentOn))
        }
        return ToolOutcome(output: ["count": .number(Double(jobs.count)), "jobs": .array(list)],
                           activity: stage.map { "Looked at \($0.label) jobs" } ?? "Looked at the pipeline", icon: "rectangle.split.3x1")
    }

    private func getSchedule(_ a: ToolArgs) throws -> ToolOutcome {
        let start = try a.date("start_date", today: today) ?? today
        let count = min(max(a.int("days") ?? 7, 1), 21)
        let crews = base.settings.crews
        let jobs = allJobs
        let days: [JSONValue] = (0..<count).map { offset in
            let day = start.adding(days: offset)
            let entries: [JSONValue] = jobs.flatMap { j in
                j.schedule.filter { $0.day.isSameDay(day) }.map { entry in
                    ["entry_id": .string(entry.id.uuidString), "job_id": .string(j.id.uuidString), "job": .string(j.name),
                     "crew": .string(crews.first { $0.id == entry.crewID }?.name ?? "No crew"), "start": .string(entry.startTime), "note": .string(entry.note)]
                }
            }
            return ["date": ToolArgs.iso(day), "weekday": .string(Fmt.weekday(day)), "weather": callJSON(day, job: nil), "entries": .array(entries)]
        }
        let crewList: [JSONValue] = crews.map { ["id": .string($0.id.uuidString), "name": .string($0.name), "kind": .string($0.kind), "people": .number(Double($0.people))] }
        return ToolOutcome(output: ["crews": .array(crewList), "days": .array(days)], activity: "Checked the schedule", icon: "calendar")
    }

    private func getWeather(_ a: ToolArgs) throws -> ToolOutcome {
        let start = try a.date("start_date", today: today) ?? today
        let count = min(max(a.int("days") ?? 7, 1), 14)
        let job = try a.string("job").map { try resolveJob($0) }
        let days: [JSONValue] = (0..<count).map { offset in
            let day = start.adding(days: offset)
            return ["date": ToolArgs.iso(day), "weekday": .string(Fmt.weekday(day)), "weather": callJSON(day, job: job)]
        }
        let r = base.settings.weather
        let rules: JSONValue = ["paving_min_f": .number(r.pavingMinF), "sealcoat_min_f": .number(r.sealcoatMinF),
                                "sealcoat_hours": .number(Double(r.sealcoatHours)), "rain_chance_max_pct": .number(Double(r.rainChanceMax))]
        return ToolOutcome(output: ["rules": rules, "rule_used": .string(job.map { $0.followsSealcoatRule ? "sealcoat" : "paving" } ?? "general"), "days": .array(days)],
                           activity: "Checked the forecast", icon: "cloud.sun")
    }

    private func getCustomer(_ a: ToolArgs) throws -> ToolOutcome {
        let c = try resolveCustomer(a.string("customer"))
        return ToolOutcome(output: customerJSON(c, full: true), activity: "Looked at \(c.name)", icon: "person")
    }

    private func getRates() -> ToolOutcome {
        let r = draft.currentRates(base)
        let f = r.factors
        let prices: [JSONValue] = r.prices.map { ["rate_id": .string($0.id), "name": .string($0.name), "unit": .string($0.unit), "unit_cost": .money($0.cents), "group": .string($0.group)] }
        let factors: JSONValue = ["mix_lb_per_sy_inch": .number(f.mixLbPerSYInch), "tack_gal_per_sy": .number(f.tackGalPerSY), "waste_pct": .number(f.wastePct),
                                  "truck_tons": .number(f.truckTons), "crew_size": .number(f.crewSize), "hours_per_day": .number(f.hoursPerDay),
                                  "pave_sy_per_day": .number(f.paveSYPerDay), "default_overhead_pct": .number(f.overheadPct), "default_profit_pct": .number(f.profitPct)]
        return ToolOutcome(output: ["prices": .array(prices), "factors": factors], activity: "Looked at your rates", icon: "dollarsign.circle")
    }

    private func getInvoices() -> ToolOutcome {
        let list: [JSONValue] = allJobs.compactMap { j in draft.invoice(j.id, base).map { invoiceJSON(j, $0) } }
        return ToolOutcome(output: ["invoices": .array(list)], activity: "Looked at invoices", icon: "doc.text")
    }

    private func comparePastJobs(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let (e, i) = try resolveOption(j, nil)
        let option = e.options[i]
        let values: [JSONValue] = base.jobs
            .filter { $0.id != j.id && $0.stage == .won && !$0.isSample }
            .sorted { $0.stageChanged > $1.stageChanged }
            .compactMap { past -> JSONValue? in
                guard let o = base.estimates[past.id]?.selected, o.title.caseInsensitiveCompare(option.title) == .orderedSame else { return nil }
                let sy = Estimator.summary(base.takeoffs[past.id] ?? Takeoff(), factors: base.rates.factors).billableSY
                guard sy > 0 else { return nil }
                return ["job": .string(past.name), "per_sy": .number((Double(o.breakdown.priceCents) / 100 / sy * 100).rounded() / 100), "won": ToolArgs.iso(past.stageChanged)]
            }
            .prefix(6).map { $0 }
        let numbers = values.compactMap { $0["per_sy"]?.double }
        return ToolOutcome(output: ["job": .string(j.name), "option": .string(option.title), "this_per_sy": .from(perSY(j, option)),
                                    "past_jobs": .array(values), "low": .from(numbers.min()), "high": .from(numbers.max()),
                                    "note": numbers.count < 2 ? "Fewer than two comparable won jobs, so there's no usual range yet." : .null],
                           activity: "Compared with your past jobs", icon: "chart.bar")
    }

    private func pointAt(_ a: ToolArgs) -> ToolOutcome {
        let ids = (a.strings("ids") ?? []).compactMap(UUID.init(uuidString:))
        return ToolOutcome(output: ["highlighted": .number(Double(ids.count))], activity: "Pointed at \(ids.count == 1 ? "an item" : "\(ids.count) items") on screen",
                           icon: "scope", highlight: ids)
    }

    private func openScreen(_ a: ToolArgs) throws -> ToolOutcome {
        let screen = try a.required("screen", max: 20)
        var label = ""
        let destination: Destination
        switch screen {
        case "today": destination = .today; label = "Today"
        case "pipeline": destination = .pipeline; label = "Pipeline"
        case "measure": destination = .measure; label = "Measure"
        case "jobs": destination = .jobs; label = "Jobs"
        case "customers": destination = .customers(nil); label = "Customers"
        case "invoices": destination = .invoices; label = "Invoices"
        case "settings": destination = .settings; label = "Settings & rates"
        case "schedule":
            let week = try a.date("week_of", today: today).map { Calendar.current.mondayOfWeek($0) }
            destination = .schedule(week: week)
            label = week.map { "Schedule, week of \(Fmt.day($0))" } ?? "Schedule"
        case "job":
            let j = try resolveJob(a.string("job"))
            guard !draft.newJobs.contains(j.id) else { throw ToolError("\(j.name) isn't saved yet. It appears once the owner applies the changes.") }
            let tab = a.string("tab") ?? "overview"
            let tabs = ["overview", "measure", "estimate", "schedule", "logs", "photos", "invoice"]
            destination = .job(j.id, tab: tabs.contains(tab) ? tab : "overview")
            label = "\(j.name) › \(tab == "logs" ? "Daily logs" : tab.prefix(1).uppercased() + tab.dropFirst())"
        default:
            throw ToolError("Unknown screen “\(screen)”.")
        }
        if mode == .chat {
            return ToolOutcome(output: ["status": "button_shown", "screen": .string(label),
                                        "note": "The owner sees an Open button and can click it. They haven't moved yet."],
                               activity: "Offered to open \(label)", icon: "arrow.up.forward.square", suggestion: Suggestion(destination: destination, label: label))
        }
        return ToolOutcome(output: ["status": "opened", "screen": .string(label)], activity: "Opened \(label)", icon: "arrow.up.forward.square", navigate: destination)
    }

    // MARK: Help, showing things, and Apple Maps

    private func searchHelp(_ a: ToolArgs) throws -> ToolOutcome {
        let q = try a.required("question", max: 300)
        let found = KnowledgeBase.search(q, limit: 4)
        var out: [String: JSONValue] = ["articles": .array(found.enumerated().map { KnowledgeBase.json($1, full: $0 < 3) })]
        if found.isEmpty {
            out["note"] = "No help article matches. Don't guess at button names. Say what you do know, or suggest Learn Stringline in the sidebar."
        }
        return ToolOutcome(output: .object(out), activity: "Looked in the help for “\(q.prefix(60))”", icon: "book")
    }

    private func getHelpArticle(_ a: ToolArgs) throws -> ToolOutcome {
        let id = try a.required("id", max: 80)
        guard let article = KnowledgeBase.article(id) else {
            throw ToolError("No article “\(id)”. Use search_help to find one.")
        }
        return ToolOutcome(output: KnowledgeBase.json(article, full: true), activity: "Read “\(article.title)”", icon: "book")
    }

    private func screenDestination(_ screen: String) -> Destination? {
        switch screen {
        case "today": .today
        case "pipeline": .pipeline
        case "measure": .measure
        case "jobs": .jobs
        case "schedule": .schedule(week: nil)
        case "customers": .customers(nil)
        case "invoices": .invoices
        case "learn": .learn
        case "settings": .settings
        default: nil
        }
    }

    private func showMe(_ a: ToolArgs) throws -> ToolOutcome {
        let id = try a.required("spot", max: 60)
        guard let spot = KnowledgeBase.spot(id) else { throw ToolError("Unknown spot “\(id)”. Use one listed in a help article.") }
        var destination: Destination?
        var visible = false
        switch spot.place {
        case .always:
            visible = true
        case .assistant:
            visible = context.panelOpen
        case .screen(let screen):
            visible = context.screen == screen
            destination = screenDestination(screen)
        case .settings(let section):
            visible = context.screen == "settings"
            destination = .settingsSection(section)
        case .jobTab(let tab):
            let named = try a.string("job").map { try resolveJob($0) }
            guard let job = named ?? context.jobID.flatMap({ id in allJobs.first { $0.id == id } }) else {
                throw ToolError("That's on a job's \(tab) tab. Ask which job, or have the owner open one first.")
            }
            guard !draft.newJobs.contains(job.id) else { throw ToolError("\(job.name) isn't saved yet.") }
            let sameJob = context.screen == "job" && context.jobID == job.id
            visible = sameJob && (tab == "overview" || context.jobTab == tab)
            destination = .job(job.id, tab: tab == "overview" && sameJob ? (context.jobTab ?? tab) : tab)
        }
        let label = spot.label
        if visible {
            return ToolOutcome(output: ["status": "showing", "spot": .string(label), "note": "A pulsing ring is around it now."],
                               activity: "Pointed to \(label)", icon: "hand.point.up.left", spotlight: id)
        }
        if mode == .chat {
            return ToolOutcome(output: ["status": "button_shown", "spot": .string(label),
                                        "note": "It's on another screen, so the owner sees a Show me button that opens it and points to it."],
                               activity: "Offered to show \(label)", icon: "hand.point.up.left",
                               suggestion: Suggestion(destination: destination, label: "Show me \(label)", spot: id))
        }
        return ToolOutcome(output: ["status": "opened_and_showing", "spot": .string(label)], activity: "Showed \(label)", icon: "hand.point.up.left",
                           navigate: destination, spotlight: id)
    }

    private func openInMaps(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        guard j.latitude != nil || !j.address.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("\(j.name) has no address or map location yet.")
        }
        let directions = a.bool("directions") ?? false
        let action = ExternalAction.maps(name: j.name, address: j.address, lat: j.latitude, lon: j.longitude, directions: directions)
        let label = directions ? "Directions to \(j.name)" : "\(j.name) in Maps"
        if mode == .chat {
            return ToolOutcome(output: ["status": "button_shown", "note": "The owner sees a button that opens Apple Maps."],
                               activity: "Offered \(label)", icon: "map", suggestion: Suggestion(destination: nil, label: "Open \(label)", external: action))
        }
        return ToolOutcome(output: ["status": "opened", "app": "Apple Maps"], activity: "Opened \(label)", icon: "map", external: action)
    }

    private var homeBase: Coordinate? {
        let c = base.settings.company
        guard let lat = c.homeLatitude, let lon = c.homeLongitude else { return nil }
        return Coordinate(lat: lat, lon: lon)
    }

    private func driveTime(_ a: ToolArgs, _ services: AssistantServices) async throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        guard let home = homeBase else { throw ToolError("Set your home base in Settings › Company first.") }
        let target: Coordinate
        if let lat = j.latitude, let lon = j.longitude {
            target = Coordinate(lat: lat, lon: lon)
        } else if !j.address.isEmpty, let found = await services.findPlaces(j.address, near: home).first {
            target = found.coordinate
        } else {
            throw ToolError("\(j.name) has no address Apple Maps can find.")
        }
        let info = try await services.driveTime(from: home, to: target)
        let from = base.settings.company.homeBase.isEmpty ? "home base" : base.settings.company.homeBase
        return ToolOutcome(output: ["job": .string(j.name), "from": .string(from), "minutes": .number(info.minutes.rounded()),
                                    "miles": .number((info.miles * 10).rounded() / 10), "source": "Apple Maps, driving, typical traffic"],
                           activity: "Checked the drive to \(j.name)", icon: "car")
    }

    private func findPlace(_ a: ToolArgs, _ services: AssistantServices) async throws -> ToolOutcome {
        let q = try a.required("query", max: 200)
        let found = await services.findPlaces(q, near: homeBase)
        let list: [JSONValue] = found.prefix(5).map {
            ["name": .string($0.name), "address": .string($0.address), "latitude": .number($0.coordinate.lat), "longitude": .number($0.coordinate.lon)]
        }
        return ToolOutcome(output: ["results": .array(list), "note": list.isEmpty ? "Nothing found. Try adding the city or ZIP." : .null],
                           activity: "Looked up “\(q.prefix(50))” in Apple Maps", icon: "mappin.and.ellipse")
    }

    private func addToCalendar(_ a: ToolArgs) throws -> ToolOutcome {
        let start = try a.date("start_date", today: today) ?? today
        let days = min(max(a.int("days") ?? 7, 1), 31)
        let end = start.adding(days: days)
        let only = try a.string("job").map { try resolveJob($0) }
        let jobs = allJobs.filter { j in (only == nil || j.id == only?.id) && j.schedule.contains { $0.day >= start && $0.day < end } }
        let entries = jobs.flatMap { j in j.schedule.filter { $0.day >= start && $0.day < end } }
        guard !entries.isEmpty else { throw ToolError("Nothing is scheduled from \(Fmt.day(start)) to \(Fmt.day(end.adding(days: -1))).") }
        return try propose([.calendarExport(CalendarRequest(jobIDs: jobs.map(\.id), from: start, to: end))],
                           title: "Add \(entries.count == 1 ? "1 crew day" : "\(entries.count) crew days") to Apple Calendar",
                           detail: "\(Fmt.day(start)) – \(Fmt.day(end.adding(days: -1))) · \(jobs.map(\.name).joined(separator: ", ")) · Calendar asks which calendar to use")
    }

    private func draftText(_ a: ToolArgs) throws -> ToolOutcome {
        let job = try a.string("job").map { try resolveJob($0) }
        let customer: Customer
        if let ref = a.string("customer") {
            customer = try resolveCustomer(ref)
        } else if let cid = job?.customerID, let c = draft.customer(cid, base) {
            customer = c
        } else {
            throw ToolError("Say which customer the text is for.")
        }
        guard !customer.phone.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("\(customer.name) has no phone number on file. The owner can add one on the Customers screen.")
        }
        let body = try a.required("body", max: 1000)
        let to = customer.contact.isEmpty ? customer.name : "\(customer.contact) (\(customer.name))"
        let preview = body.replacingOccurrences(of: "\n", with: " ").prefix(160)
        return try propose([.textDraft(TextDraft(customerID: customer.id, jobID: job?.id, body: body))],
                           title: "Text message to \(to)", detail: "“\(preview)\(body.count > 160 ? "…" : "")” · Opens in Messages. You press Send.")
    }

    // MARK: Write tools (proposals only)

    func propose(_ ops: [ChangeOp], title: String, detail: String, extra: [String: JSONValue] = [:]) throws -> ToolOutcome {
        var trial = draft
        for op in ops { try trial.apply(op, base: base) }
        draft = trial
        let change = ProposedChange(ops, title: title, detail: detail)
        proposed.append(change)
        var out: [String: JSONValue] = [
            "status": "proposed", "change": .string(title), "detail": .string(detail),
            "note": .string(change.needsOK
                ? "Listed for the owner unticked. It happens only if they tick it and press Apply."
                : "Listed for the owner to review. Nothing is saved until they press Apply."),
        ]
        for (k, v) in extra { out[k] = v }
        return ToolOutcome(output: .object(out), activity: title, icon: change.needsOK ? "hand.raised" : "square.and.pencil")
    }

    private func services(_ a: ToolArgs, _ key: String) -> [Service]? {
        a.strings(key).map { $0.compactMap(Service.init(rawValue:)) }
    }

    private func createLead(_ a: ToolArgs) throws -> ToolOutcome {
        var ops: [ChangeOp] = []
        var job = Job()
        job.name = try a.required("name", max: 120)
        var customerLabel = "No customer"
        if let ref = a.string("customer") {
            let c = try resolveCustomer(ref)
            job.customerID = c.id
            job.type = c.type
            customerLabel = c.name
        } else if let newName = a.string("new_customer_name", max: 120) {
            var c = Customer()
            c.name = newName
            c.contact = a.string("contact", max: 120) ?? ""
            c.address = a.string("address", max: 200) ?? ""
            if let t = a.string("job_type").flatMap(CustomerType.init(rawValue:)) { c.type = t }
            ops.append(.createCustomer(c))
            job.customerID = c.id
            job.type = c.type
            customerLabel = "\(newName) (new customer)"
        }
        if let t = a.string("job_type").flatMap(CustomerType.init(rawValue:)) { job.type = t }
        job.address = a.string("address", max: 200) ?? ""
        job.services = services(a, "services") ?? []
        job.source = a.string("source", max: 120) ?? ""
        job.notes = a.text("notes") ?? ""
        job.bidDue = try a.date("bid_due", today: today)
        if let lat = a.double("latitude"), let lon = a.double("longitude"), abs(lat) <= 90, abs(lon) <= 180 {
            job.latitude = lat
            job.longitude = lon
        }
        job.stage = .lead
        ops.append(.createJob(job))
        var detail = [customerLabel]
        if !job.services.isEmpty { detail.append(job.services.map(\.label).joined(separator: ", ")) }
        if let due = job.bidDue { detail.append("bid due \(Fmt.day(due))") }
        return try propose(ops, title: "New lead: \(job.name)", detail: detail.joined(separator: " · "),
                           extra: ["job_id": .string(job.id.uuidString), "customer_id": .from(job.customerID?.uuidString)])
    }

    private func updateJob(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        var p = JobPatch()
        var parts: [String] = []
        if let v = a.string("name", max: 120), v != j.name { p.name = v; parts.append("Name → \(v)") }
        if let v = a.string("address", max: 200), v != j.address { p.address = v; parts.append("Address → \(v)") }
        if let v = a.string("stage").flatMap(Stage.init(rawValue:)), v != j.stage { p.stage = v; parts.append("Stage \(j.stage.label) → \(v.label)") }
        if let v = services(a, "services"), v != j.services { p.services = v; parts.append("Services → \(v.map(\.label).joined(separator: ", "))") }
        if let v = try a.date("bid_due", today: today) { p.bidDue = v; parts.append("Bid due \(Fmt.day(v))") }
        if let v = try a.date("site_visit", today: today) { p.siteVisit = v; parts.append("Site visit \(Fmt.day(v))") }
        if let v = a.text("add_note", max: 2000) { p.addNote = v; parts.append("Note: “\(v.prefix(60))\(v.count > 60 ? "…" : "")”") }
        if let v = a.string("plant_order", max: 300) { p.plantNote = v; parts.append("Plant order: \(v)") }
        if let v = a.string("ticket_number", max: 40) { p.ticketNumber = v; parts.append("811 ticket #\(v)") }
        if let v = try a.date("ticket_good_until", today: today) { p.ticketGoodUntil = v; parts.append("811 good until \(Fmt.day(v))") }
        if let v = a.bool("ticket_not_needed") { p.ticketNotNeeded = v; parts.append(v ? "No 811 ticket needed" : "811 ticket needed") }
        if let v = try a.date("completed_on", today: today) { p.completedOn = v; parts.append("Finished \(Fmt.day(v))") }
        if let v = a.string("lost_reason", max: 300) { p.lostReason = v; parts.append("Lost: \(v)") }
        guard !p.isEmpty else { throw ToolError("Nothing to change: every field was empty or already the same.") }
        return try propose([.updateJob(j.id, p)], title: "Update \(j.name)", detail: parts.joined(separator: " · "))
    }

    private func addDailyLog(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        var log = DailyLog()
        log.day = try a.date("date", today: today) ?? today
        log.crewID = try resolveCrew(a.string("crew"))?.id ?? j.schedule.first { $0.day.isSameDay(log.day) }?.crewID ?? base.settings.crews.first?.id
        log.tons = min(max(a.double("tons") ?? 0, 0), 100_000)
        log.hours = min(max(a.double("hours") ?? 0, 0), 10_000)
        log.notes = a.text("notes", max: 2000) ?? ""
        if let f = base.forecast(for: log.day) { log.weather = "\(Int(f.high))° / \(Int(f.low))°, \(f.rainChance)% rain" }
        var detail: [String] = []
        if log.tons > 0 { detail.append("\(Fmt.number(log.tons, decimals: log.tons == log.tons.rounded() ? 0 : 1)) tn") }
        if log.hours > 0 { detail.append("\(Fmt.plain(log.hours)) crew hours") }
        if !log.notes.isEmpty { detail.append("“\(log.notes.prefix(60))”") }
        return try propose([.addLog(job: j.id, log)], title: "Daily log: \(j.name), \(Fmt.day(log.day))", detail: detail.joined(separator: " · "))
    }

    private func createCustomer(_ a: ToolArgs) throws -> ToolOutcome {
        var c = Customer()
        c.name = try a.required("name", max: 120)
        c.contact = a.string("contact", max: 120) ?? ""
        c.phone = a.string("phone", max: 40) ?? ""
        c.email = a.string("email", max: 120) ?? ""
        c.address = a.string("address", max: 200) ?? ""
        if let t = a.string("type").flatMap(CustomerType.init(rawValue:)) { c.type = t }
        let detail = [c.contact, c.type.label].filter { !$0.isEmpty }.joined(separator: " · ")
        return try propose([.createCustomer(c)], title: "New customer: \(c.name)", detail: detail, extra: ["customer_id": .string(c.id.uuidString)])
    }

    private func updateCustomer(_ a: ToolArgs) throws -> ToolOutcome {
        let c = try resolveCustomer(a.string("customer"))
        var p = CustomerPatch()
        var parts: [String] = []
        if let v = a.string("name", max: 120), v != c.name { p.name = v; parts.append("Name → \(v)") }
        if let v = a.string("contact", max: 120), v != c.contact { p.contact = v; parts.append("Contact → \(v)") }
        if let v = a.string("phone", max: 40), v != c.phone { p.phone = v; parts.append("Phone → \(v)") }
        if let v = a.string("email", max: 120), v != c.email { p.email = v; parts.append("Email → \(v)") }
        if let v = a.string("address", max: 200), v != c.address { p.address = v; parts.append("Address → \(v)") }
        if let v = a.text("add_note", max: 2000) { p.addNote = v; parts.append("Note: “\(v.prefix(60))\(v.count > 60 ? "…" : "")”") }
        guard !p.isEmpty else { throw ToolError("Nothing to change.") }
        return try propose([.updateCustomer(c.id, p)], title: "Update \(c.name)", detail: parts.joined(separator: " · "))
    }

    private func draftEmail(_ a: ToolArgs) throws -> ToolOutcome {
        let job = try a.string("job").map { try resolveJob($0) }
        let customer: Customer
        if let ref = a.string("customer") {
            customer = try resolveCustomer(ref)
        } else if let cid = job?.customerID, let c = draft.customer(cid, base) {
            customer = c
        } else {
            throw ToolError("Say which customer the email is for.")
        }
        let subject = try a.required("subject", max: 200)
        let body = try a.required("body", max: 6000)
        let to = customer.contact.isEmpty ? customer.name : "\(customer.contact) (\(customer.name))"
        let preview = body.replacingOccurrences(of: "\n", with: " ").prefix(220)
        let detail = "Subject: \(subject) · “\(preview)\(body.count > 220 ? "…" : "")”"
            + (customer.email.isEmpty ? " · No email on file, so Mail opens without an address" : "")
            + " · Opens in Mail. You press Send."
        return try propose([.mailDraft(MailDraft(customerID: customer.id, jobID: job?.id, subject: subject, body: body))],
                           title: "Mail draft to \(to)", detail: detail, extra: ["body_preview": .string(String(body.prefix(400)))])
    }

    private func groupFor(_ price: PriceItem) -> String {
        switch price.group {
        case "Materials": "Materials"
        case "Trucking": "Trucking & general"
        case "Labor & equipment": price.id == "crewLabor" ? "Labor" : (price.id == "mobilization" ? "Trucking & general" : "Equipment & subs")
        default: "Equipment & subs"
        }
    }

    private func optionLabel(_ e: Estimate, _ i: Int) -> String {
        e.options.count > 1 ? " · Option \(Self.letter(i))" : ""
    }

    private func afterTotals(_ j: Job, optionID: UUID) -> JSONValue {
        let e = draft.estimate(j.id, base)
        guard let o = e.options.first(where: { $0.id == optionID }) else { return .null }
        return totalsJSON(j, o)
    }

    private func addLine(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let (e, i) = try resolveOption(j, a.string("option"))
        var item = LineItem()
        let rates = draft.currentRates(base)
        if let rid = a.string("rate_id") {
            guard let price = rates.prices.first(where: { $0.id == rid }) else { throw ToolError("No rate “\(rid)”. Use get_rates.") }
            item.name = a.string("name", max: 120) ?? price.name
            item.unit = a.string("unit", max: 12) ?? price.unit
            item.unitCents = a.double("unit_cost").map { Int(($0 * 100).rounded()) } ?? price.cents
            item.group = a.string("group").flatMap { EstimateOption.groups.contains($0) ? $0 : nil } ?? groupFor(price)
        } else {
            item.name = try a.required("name", max: 120)
            item.unit = a.string("unit", max: 12) ?? "ea"
            guard let cost = a.double("unit_cost") else { throw ToolError("Give unit_cost or a rate_id.") }
            item.unitCents = Int((cost * 100).rounded())
            item.group = a.string("group").flatMap { EstimateOption.groups.contains($0) ? $0 : nil } ?? "Equipment & subs"
        }
        guard let qty = a.double("qty"), qty > 0, qty < 10_000_000 else { throw ToolError("qty must be a positive number.") }
        guard item.unitCents >= 0, item.unitCents < 1_000_000_000 else { throw ToolError("unit_cost is out of range.") }
        item.qty = qty
        let detail = "\(Fmt.number(qty, decimals: qty == qty.rounded() ? 0 : 2)) \(item.unit) × \(Fmt.dollars(item.unitCents)) · \(item.group) · +\(Fmt.dollars(item.totalCents))\(optionLabel(e, i))"
        let optionID = e.options[i].id
        var out = try propose([.addLine(job: j.id, option: optionID, item)], title: "Add line: \(item.name)", detail: detail,
                              extra: ["line_id": .string(item.id.uuidString)])
        out.output = out.output.setting("totals_after", afterTotals(j, optionID: optionID))
        return out
    }

    private func updateLine(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let (e, i) = try resolveOption(j, a.string("option"))
        let line = try resolveLine(e.options[i], try a.required("line", max: 120))
        var p = LinePatch()
        var parts: [String] = []
        if let v = a.string("name", max: 120), v != line.name { p.name = v; parts.append("Name → \(v)") }
        if let v = a.double("qty"), v != line.qty {
            guard v >= 0, v < 10_000_000 else { throw ToolError("qty is out of range.") }
            p.qty = v
            parts.append("Qty \(Fmt.number(line.qty, decimals: 0)) → \(Fmt.number(v, decimals: v == v.rounded() ? 0 : 2)) \(line.unit)")
        }
        if let v = a.string("unit", max: 12), v != line.unit { p.unit = v; parts.append("Unit → \(v)") }
        if let v = a.double("unit_cost") {
            let cents = Int((v * 100).rounded())
            guard cents >= 0, cents < 1_000_000_000 else { throw ToolError("unit_cost is out of range.") }
            if cents != line.unitCents { p.unitCents = cents; parts.append("Unit cost \(Fmt.dollars(line.unitCents)) → \(Fmt.dollars(cents))") }
        }
        guard !p.isEmpty else { throw ToolError("Nothing to change on that line.") }
        var updated = line
        if let v = p.qty { updated.qty = v }
        if let v = p.unitCents { updated.unitCents = v }
        parts.append("Total \(Fmt.dollars(line.totalCents)) → \(Fmt.dollars(updated.totalCents))")
        if line.fromTakeoff && p.qty != nil { parts.append("Update from measurements would reset this quantity") }
        let optionID = e.options[i].id
        var out = try propose([.updateLine(job: j.id, option: optionID, line: line.id, p)], title: "Change line: \(line.name)",
                              detail: parts.joined(separator: " · ") + optionLabel(e, i))
        out.output = out.output.setting("totals_after", afterTotals(j, optionID: optionID))
        return out
    }

    private func removeLine(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let (e, i) = try resolveOption(j, a.string("option"))
        let line = try resolveLine(e.options[i], try a.required("line", max: 120))
        let optionID = e.options[i].id
        var out = try propose([.removeLine(job: j.id, option: optionID, line: line.id)], title: "Remove line: \(line.name)",
                              detail: "−\(Fmt.dollars(line.totalCents))\(optionLabel(e, i))")
        out.output = out.output.setting("totals_after", afterTotals(j, optionID: optionID))
        return out
    }

    private func setMarkup(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let (e, i) = try resolveOption(j, a.string("option"))
        let o = e.options[i]
        let profit = a.double("profit_pct").map { min(max($0, 0), 100) }
        let overhead = a.double("overhead_pct").map { min(max($0, 0), 100) }
        var parts: [String] = []
        if let profit, profit != o.profitPct { parts.append("Profit \(Fmt.plain(o.profitPct))% → \(Fmt.plain(profit))%") }
        if let overhead, overhead != o.overheadPct { parts.append("Overhead \(Fmt.plain(o.overheadPct))% → \(Fmt.plain(overhead))%") }
        guard !parts.isEmpty else { throw ToolError("Markup is already set that way.") }
        let optionID = o.id
        var out = try propose([.setMarkup(job: j.id, option: optionID, profit: profit, overhead: overhead)],
                              title: parts.joined(separator: ", "), detail: "\(j.name)\(optionLabel(e, i))")
        out.output = out.output.setting("totals_after", afterTotals(j, optionID: optionID))
        return out
    }

    private func setScope(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let (e, i) = try resolveOption(j, a.string("option"))
        let scope = try a.required("scope", max: 8000)
        let first = scope.split(separator: "\n").first.map(String.init) ?? scope
        return try propose([.setScope(job: j.id, option: e.options[i].id, scope)], title: "Rewrite the scope of work\(optionLabel(e, i))",
                           detail: "\(first.prefix(110))\(first.count > 110 || scope.contains("\n") ? "…" : "")")
    }

    private func addOption(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let title = try a.required("title", max: 80)
        let e = draft.estimate(j.id, base)
        let rates = draft.currentRates(base)
        var option: EstimateOption
        let from = a.string("start_from") ?? "blank"
        switch from {
        case "measurements":
            let t = draft.takeoff(j.id, base)
            guard !t.shapes.isEmpty else { throw ToolError("\(j.name) has nothing measured yet.") }
            option = Estimator.option(title: title, takeoff: t, rates: rates)
        case "copy_of_selected":
            guard let selected = e.selected else { throw ToolError("There's no option to copy.") }
            option = selected
            option.id = UUID()
            option.items = selected.items.map { var item = $0; item.id = UUID(); return item }
        default:
            option = EstimateOption()
            option.overheadPct = rates.factors.overheadPct
            option.profitPct = rates.factors.profitPct
        }
        option.title = title
        let letter = Self.letter(e.options.count)
        let price = option.items.isEmpty ? "no lines yet" : Fmt.dollars(option.breakdown.priceCents)
        return try propose([.addOption(job: j.id, option)], title: "Add Option \(letter): \(title)",
                           detail: "\(from == "measurements" ? "From the measurements" : from == "copy_of_selected" ? "Copy of the selected option" : "Blank") · \(price)",
                           extra: ["option_id": .string(option.id.uuidString), "letter": .string(letter)])
    }

    private func updateArea(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let shape = try resolveShape(draft.takeoff(j.id, base), a.required("area", max: 120))
        var p = ShapePatch()
        var parts: [String] = []
        if let v = a.string("name", max: 80), v != shape.name { p.name = v; parts.append("Name → \(v)") }
        if let v = a.double("depth_inches") {
            guard v > 0, v <= 24 else { throw ToolError("Depth must be between 0 and 24 inches.") }
            if v != shape.depthInches { p.depthInches = v; parts.append("Depth \(Fmt.plain(shape.depthInches))\" → \(Fmt.plain(v))\"") }
        }
        if let v = a.string("work_type").flatMap(WorkType.init(rawValue:)), v != shape.workType {
            guard v.isArea == shape.workType.isArea else { throw ToolError("An area can't become a line, or a line an area.") }
            p.workType = v
            parts.append("Work \(shape.workType.label) → \(v.label)")
        }
        guard !p.isEmpty else { throw ToolError("Nothing to change on that area.") }
        let name = shape.name.isEmpty ? shape.workType.label : shape.name
        return try propose([.updateShape(job: j.id, shape: shape.id, p)], title: "Measured area: \(name)",
                           detail: parts.joined(separator: " · ") + " · Press Update from measurements on the estimate to carry it through")
    }

    private func scheduleJob(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let dates = try (a.strings("dates") ?? []).map { try ToolArgs.parseDate($0, today: today) }
        guard !dates.isEmpty, dates.count <= 40 else { throw ToolError("Give between 1 and 40 dates.") }
        let crews = base.settings.crews
        let crew = try resolveCrew(a.string("crew")) ?? (j.followsSealcoatRule ? crews.dropFirst().first ?? crews.first : crews.first)
        let start = a.string("start_time", max: 20) ?? "7:00 AM"
        let note = a.string("note", max: 200) ?? ""
        let entries: [ScheduleEntry] = Array(Set(dates)).sorted().map { day in
            var entry = ScheduleEntry()
            entry.day = day
            entry.crewID = crew?.id
            entry.startTime = start
            entry.note = note
            return entry
        }
        let markWon = j.stage != .won
        let rules = base.settings.weather
        let warnings: [String] = entries.compactMap { entry in
            guard let f = base.forecast(for: entry.day) else { return nil }
            let call = WeatherJudge.call(for: j, on: f, rules)
            return call.level == .noGo ? "\(Fmt.weekday(entry.day)) \(Fmt.day(entry.day)): \(call.short)" : nil
        }
        var detail = ["\(crew?.name ?? "No crew") · \(dayRange(entries.map(\.day))) · \(start)"]
        if !note.isEmpty { detail.append(note) }
        if !warnings.isEmpty { detail.append("Weather: " + warnings.joined(separator: "; ")) }
        if markWon { detail.append("Also marks it Won") }
        let weather: [JSONValue] = entries.map { ["date": ToolArgs.iso($0.day), "weather": callJSON($0.day, job: j)] }
        return try propose([.addScheduleDays(job: j.id, entries, markWon: markWon)],
                           title: "Schedule \(j.name)", detail: detail.joined(separator: " · "),
                           extra: ["entry_ids": .array(entries.map { .string($0.id.uuidString) }), "weather": .array(weather)])
    }

    func dayRange(_ days: [Date]) -> String {
        let sorted = days.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        let consecutive = zip(sorted, sorted.dropFirst()).allSatisfy { Calendar.current.daysBetween($0, $1) == 1 }
        if sorted.count == 1 { return "\(Fmt.weekday(first)) \(Fmt.day(first))" }
        if consecutive { return "\(Fmt.weekday(first)) \(Fmt.day(first)) – \(Fmt.weekday(last)) \(Fmt.day(last)) (\(sorted.count) days)" }
        return sorted.map { Fmt.day($0) }.joined(separator: ", ") + " (\(sorted.count) days)"
    }

    private func removeDays(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        let dates = try (a.strings("dates") ?? []).map { try ToolArgs.parseDate($0, today: today) }
        let entries = j.schedule.filter { entry in dates.contains { $0.isSameDay(entry.day) } }
        guard !entries.isEmpty else { throw ToolError("\(j.name) isn't scheduled on those days.") }
        return try propose([.removeScheduleDays(job: j.id, entries.map(\.id))], title: "Take \(j.name) off \(entries.count == 1 ? "1 day" : "\(entries.count) days")",
                           detail: dayRange(entries.map(\.day)))
    }

    private func createInvoice(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        var inv = Invoice()
        let fallback = draft.estimate(j.id, base).selected.map { $0.breakdown.priceCents } ?? 0
        inv.amountCents = a.double("amount").map { Int(($0 * 100).rounded()) } ?? fallback
        inv.depositCents = a.double("deposit").map { Int(($0 * 100).rounded()) } ?? 0
        inv.dueDays = min(max(a.int("due_days") ?? 30, 0), 365)
        inv.issued = today
        guard inv.amountCents > 0, inv.amountCents < 100_000_000_00 else { throw ToolError("The invoice needs an amount.") }
        guard inv.depositCents >= 0, inv.depositCents <= inv.amountCents else { throw ToolError("The deposit can't be more than the amount.") }
        return try propose([.createInvoice(job: j.id, inv)], title: "Invoice \(j.name): \(Fmt.dollars(inv.amountCents))",
                           detail: "Due in \(inv.dueDays) days\(inv.depositCents > 0 ? " · \(Fmt.dollars(inv.depositCents)) deposit" : "") · Numbered when applied")
    }

    private func markPaid(_ a: ToolArgs) throws -> ToolOutcome {
        let j = try resolveJob(a.string("job"))
        guard let inv = draft.invoice(j.id, base) else { throw ToolError("\(j.name) has no invoice.") }
        guard !inv.isPaid else { throw ToolError("That invoice is already marked paid.") }
        let day = try a.date("paid_on", today: today) ?? today
        return try propose([.setInvoicePaid(job: j.id, day)], title: "Mark \(j.name)'s invoice\(inv.number.isEmpty ? "" : " #\(inv.number)") paid",
                           detail: "Paid \(Fmt.day(day)) · \(Fmt.dollars(inv.balanceCents)) balance")
    }

    private func updateRate(_ a: ToolArgs) throws -> ToolOutcome {
        let rates = draft.currentRates(base)
        let id = try a.required("rate_id", max: 60)
        guard let price = rates.prices.first(where: { $0.id == id }) else { throw ToolError("No rate “\(id)”. Use get_rates.") }
        guard let cost = a.double("unit_cost"), cost >= 0, cost < 10_000_000 else { throw ToolError("unit_cost must be a dollar amount.") }
        let cents = Int((cost * 100).rounded())
        guard cents != price.cents else { throw ToolError("That rate is already \(Fmt.dollars(cents)).") }
        return try propose([.updateRate(id: id, cents: cents)], title: "Rate: \(price.name) \(Fmt.dollars(price.cents)) → \(Fmt.dollars(cents)) per \(price.unit)",
                           detail: "Used for new estimates and new lines. Estimates you already have keep their prices.")
    }
}
