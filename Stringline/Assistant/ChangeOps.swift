import Foundation

/// What the assistant can read. AppStore provides it in the app; the logic tests use a stand-in.
@MainActor
protocol AssistantDataSource: AnyObject {
    var jobs: [Job] { get }
    var customers: [Customer] { get }
    var settings: AppSettings { get }
    var rates: Rates { get }
    var estimates: [UUID: Estimate] { get }
    var takeoffs: [UUID: Takeoff] { get }
    var logs: [UUID: JobLogs] { get }
    var invoices: [UUID: Invoice] { get }
    func forecast(for day: Date) -> DayForecast?
}

// MARK: - Patches

struct JobPatch: Hashable {
    var name: String?
    var address: String?
    var stage: Stage?
    var services: [Service]?
    var type: CustomerType?
    var customerID: UUID?
    var bidDue: Date?
    var siteVisit: Date?
    var addNote: String?
    var plantNote: String?
    var ticketNumber: String?
    var ticketGoodUntil: Date?
    var ticketNotNeeded: Bool?
    var completedOn: Date?
    var lostReason: String?

    var isEmpty: Bool { self == JobPatch() }
}

struct CustomerPatch: Hashable {
    var name: String?
    var contact: String?
    var phone: String?
    var email: String?
    var address: String?
    var type: CustomerType?
    var addNote: String?

    var isEmpty: Bool { self == CustomerPatch() }
}

struct LinePatch: Hashable {
    var name: String?
    var qty: Double?
    var unit: String?
    var unitCents: Int?

    var isEmpty: Bool { self == LinePatch() }
}

struct ShapePatch: Hashable {
    var name: String?
    var depthInches: Double?
    var workType: WorkType?

    var isEmpty: Bool { self == ShapePatch() }
}

/// Settings the assistant can change, as in Settings. Nil leaves a value alone.
struct SettingsPatch: Hashable {
    var companyName: String?
    var phone: String?
    var email: String?
    var address: String?
    var license: String?
    var website: String?
    var homeBase: String?
    var homeLatitude: Double?
    var homeLongitude: Double?
    var pavingMinF: Double?
    var sealcoatMinF: Double?
    var sealcoatDryHours: Int?
    var rainChanceMax: Int?
    var proposalValidDays: Int?
    var exclusions: String?
    var terms: String?
    var escalationClause: Bool?
    var backupNightly: Bool?
    var sealcoatCycleYears: Int?
    /// A crew to add (new id) or change (existing id).
    var crew: Crew?

    var isEmpty: Bool { self == SettingsPatch() }

    func apply(to s: inout AppSettings) {
        if let v = companyName { s.company.name = v }
        if let v = phone { s.company.phone = v }
        if let v = email { s.company.email = v }
        if let v = address { s.company.address = v }
        if let v = license { s.company.license = v }
        if let v = website { s.company.website = v }
        if let v = homeBase { s.company.homeBase = v }
        if let v = homeLatitude, let w = homeLongitude { s.company.homeLatitude = v; s.company.homeLongitude = w }
        if let v = pavingMinF { s.weather.pavingMinF = v }
        if let v = sealcoatMinF { s.weather.sealcoatMinF = v }
        if let v = sealcoatDryHours { s.weather.sealcoatHours = v }
        if let v = rainChanceMax { s.weather.rainChanceMax = v }
        if let v = proposalValidDays { s.proposal.validDays = v }
        if let v = exclusions { s.proposal.exclusions = v }
        if let v = terms { s.proposal.terms = v }
        if let v = escalationClause { s.proposal.escalationClause = v }
        if let v = backupNightly { s.backupNightly = v }
        if let v = sealcoatCycleYears { s.sealcoatCycleYears = v }
        if let c = crew {
            if let i = s.crews.firstIndex(where: { $0.id == c.id }) { s.crews[i] = c } else { s.crews.append(c) }
        }
    }
}

/// A Mail draft Stringline opens for the owner. Nothing is ever sent by Stringline.
struct MailDraft: Hashable {
    var customerID: UUID
    var jobID: UUID?
    var subject: String
    var body: String
}

/// A Messages draft to a customer's phone on file. The owner sends it.
struct TextDraft: Hashable {
    var customerID: UUID
    var jobID: UUID?
    var body: String
}

/// Crew days to hand to Apple Calendar, which asks the owner where to add them.
struct CalendarRequest: Hashable {
    var jobIDs: [UUID]
    var from: Date
    var to: Date
}

// MARK: - Operations

/// One change the assistant wants to make. Operations are replayed in order, both to show the
/// assistant what its own proposals look like and, when the owner presses Apply, against the live data.
enum ChangeOp: Hashable {
    case createCustomer(Customer)
    case updateCustomer(UUID, CustomerPatch)
    case createJob(Job)
    case updateJob(UUID, JobPatch)
    case addLine(job: UUID, option: UUID, LineItem)
    case updateLine(job: UUID, option: UUID, line: UUID, LinePatch)
    case removeLine(job: UUID, option: UUID, line: UUID)
    case setMarkup(job: UUID, option: UUID, profit: Double?, overhead: Double?)
    case setScope(job: UUID, option: UUID, String)
    case addOption(job: UUID, EstimateOption)
    case addScheduleDays(job: UUID, [ScheduleEntry], markWon: Bool)
    case removeScheduleDays(job: UUID, [UUID])
    case addLog(job: UUID, DailyLog)
    case createInvoice(job: UUID, Invoice)
    case setInvoicePaid(job: UUID, Date?)
    case updateRate(id: String, cents: Int)
    case updateShape(job: UUID, shape: UUID, ShapePatch)
    /// Adds a measured shape, or replaces the one with the same id (a redrawn outline).
    case putShape(job: UUID, TakeoffShape)
    case removeShape(job: UUID, shape: UUID)
    case updateSettings(SettingsPatch)
    case mailDraft(MailDraft)
    case textDraft(TextDraft)
    case calendarExport(CalendarRequest)

    /// Outward-facing or wide-reaching changes stay unticked until the owner ticks them.
    var needsOK: Bool {
        switch self {
        case .setInvoicePaid, .updateRate, .updateSettings, .mailDraft, .textDraft, .calendarExport: true
        default: false
        }
    }

    var jobID: UUID? {
        switch self {
        case .createJob(let j): j.id
        case .updateJob(let id, _): id
        case .addLine(let j, _, _), .updateLine(let j, _, _, _), .removeLine(let j, _, _), .setMarkup(let j, _, _, _),
             .setScope(let j, _, _), .addOption(let j, _), .addScheduleDays(let j, _, _), .removeScheduleDays(let j, _),
             .addLog(let j, _), .createInvoice(let j, _), .setInvoicePaid(let j, _), .updateShape(let j, _, _),
             .putShape(let j, _), .removeShape(let j, _): j
        case .mailDraft(let m): m.jobID
        case .textDraft(let t): t.jobID
        case .calendarExport(let c): c.jobIDs.first
        case .createCustomer, .updateCustomer, .updateRate, .updateSettings: nil
        }
    }
}

/// A change waiting for the owner, shown in the assistant's change card.
/// Usually one operation; a new lead with a new customer is two that go together.
struct ProposedChange: Identifiable, Hashable {
    let id = UUID()
    let ops: [ChangeOp]
    let title: String
    let detail: String
    var isOn: Bool

    init(_ ops: [ChangeOp], title: String, detail: String) {
        self.ops = ops
        self.title = title
        self.detail = detail
        isOn = !ops.contains { $0.needsOK }
    }

    var needsOK: Bool { ops.contains { $0.needsOK } }
    var jobID: UUID? { ops.lazy.compactMap(\.jobID).first }
}

// MARK: - Draft state

/// The records an assistant run has changed, layered over the real data. Only changed records are kept.
struct DraftState {
    var jobs: [UUID: Job] = [:]
    var customers: [UUID: Customer] = [:]
    var estimates: [UUID: Estimate] = [:]
    var takeoffs: [UUID: Takeoff] = [:]
    var logs: [UUID: JobLogs] = [:]
    var invoices: [UUID: Invoice] = [:]
    var rates: Rates?
    var settings: AppSettings?
    var newJobs: [UUID] = []
    var newCustomers: [UUID] = []
    var mail: [MailDraft] = []
    var texts: [TextDraft] = []
    var calendar: [CalendarRequest] = []

    struct Problem: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var isEmpty: Bool {
        jobs.isEmpty && customers.isEmpty && estimates.isEmpty && takeoffs.isEmpty && logs.isEmpty && invoices.isEmpty && rates == nil
            && settings == nil && mail.isEmpty && texts.isEmpty && calendar.isEmpty
    }

    // Reads through the draft to the real data.
    @MainActor func job(_ id: UUID, _ base: AssistantDataSource) -> Job? { jobs[id] ?? base.jobs.first { $0.id == id } }
    @MainActor func customer(_ id: UUID, _ base: AssistantDataSource) -> Customer? { customers[id] ?? base.customers.first { $0.id == id } }
    @MainActor func estimate(_ id: UUID, _ base: AssistantDataSource) -> Estimate { estimates[id] ?? base.estimates[id] ?? Estimate() }
    @MainActor func takeoff(_ id: UUID, _ base: AssistantDataSource) -> Takeoff { takeoffs[id] ?? base.takeoffs[id] ?? Takeoff() }
    @MainActor func jobLogs(_ id: UUID, _ base: AssistantDataSource) -> JobLogs { logs[id] ?? base.logs[id] ?? JobLogs() }
    @MainActor func invoice(_ id: UUID, _ base: AssistantDataSource) -> Invoice? { invoices[id] ?? base.invoices[id] }
    @MainActor func currentRates(_ base: AssistantDataSource) -> Rates { rates ?? base.rates }
    @MainActor func currentSettings(_ base: AssistantDataSource) -> AppSettings { settings ?? base.settings }

    @MainActor func allJobs(_ base: AssistantDataSource) -> [Job] {
        newJobs.compactMap { jobs[$0] } + base.jobs.map { jobs[$0.id] ?? $0 }
    }

    @MainActor func allCustomers(_ base: AssistantDataSource) -> [Customer] {
        base.customers.map { customers[$0.id] ?? $0 } + newCustomers.compactMap { customers[$0] }
    }

    @MainActor static func replay(_ ops: [ChangeOp], base: AssistantDataSource) -> (state: DraftState, failures: [Int: String]) {
        var state = DraftState()
        var failures: [Int: String] = [:]
        for (i, op) in ops.enumerated() {
            do { try state.apply(op, base: base) } catch { failures[i] = error.localizedDescription }
        }
        return (state, failures)
    }

    // MARK: Apply

    @MainActor
    mutating func apply(_ op: ChangeOp, base: AssistantDataSource) throws {
        let now = Date()
        func needJob(_ id: UUID) throws -> Job {
            guard let j = job(id, base) else { throw Problem(message: "That job no longer exists.") }
            return j
        }
        func optionIndex(_ e: Estimate, _ option: UUID) throws -> Int {
            guard let i = e.options.firstIndex(where: { $0.id == option }) else { throw Problem(message: "That estimate option no longer exists.") }
            return i
        }

        switch op {
        case .createCustomer(let c):
            guard customer(c.id, base) == nil else { throw Problem(message: "That customer already exists.") }
            customers[c.id] = c
            newCustomers.append(c.id)

        case .updateCustomer(let id, let p):
            guard var c = customer(id, base) else { throw Problem(message: "That customer no longer exists.") }
            if let v = p.name { c.name = v }
            if let v = p.contact { c.contact = v }
            if let v = p.phone { c.phone = v }
            if let v = p.email { c.email = v }
            if let v = p.address { c.address = v }
            if let v = p.type { c.type = v }
            if let note = p.addNote { c.notes = c.notes.isEmpty ? note : c.notes + "\n\n" + note }
            customers[id] = c

        case .createJob(let j):
            guard job(j.id, base) == nil else { throw Problem(message: "That job already exists.") }
            if let cid = j.customerID, customer(cid, base) == nil { throw Problem(message: "The job's customer no longer exists.") }
            jobs[j.id] = j
            newJobs.append(j.id)

        case .updateJob(let id, let p):
            var j = try needJob(id)
            if let v = p.name { j.name = v }
            if let v = p.address { j.address = v }
            if let v = p.stage, v != j.stage {
                j.stage = v
                j.stageChanged = now
                if v == .sent && j.sentOn == nil { j.sentOn = now }
            }
            if let v = p.services { j.services = v }
            if let v = p.type { j.type = v }
            if let v = p.customerID {
                guard customer(v, base) != nil else { throw Problem(message: "That customer no longer exists.") }
                j.customerID = v
            }
            if let v = p.bidDue { j.bidDue = v }
            if let v = p.siteVisit { j.siteVisit = v }
            if let note = p.addNote { j.notes = j.notes.isEmpty ? note : j.notes + "\n\n" + note }
            if let v = p.plantNote { j.plantNote = v }
            if let v = p.ticketNumber { j.ticket.number = v }
            if let v = p.ticketGoodUntil { j.ticket.goodUntil = v }
            if let v = p.ticketNotNeeded { j.ticket.notNeeded = v }
            if let v = p.completedOn { j.completedOn = v }
            if let v = p.lostReason { j.lostReason = v }
            j.updated = now
            jobs[id] = j

        case .addLine(let jobID, let optionID, let item):
            _ = try needJob(jobID)
            var e = estimate(jobID, base)
            let i = try optionIndex(e, optionID)
            var items = e.options[i].items
            if let last = items.lastIndex(where: { $0.group == item.group }) {
                items.insert(item, at: last + 1)
            } else {
                let order = EstimateOption.groups
                let rank = order.firstIndex(of: item.group) ?? order.count
                let at = items.firstIndex { (order.firstIndex(of: $0.group) ?? order.count) > rank } ?? items.count
                items.insert(item, at: at)
            }
            e.options[i].items = items
            estimates[jobID] = e

        case .updateLine(let jobID, let optionID, let lineID, let p):
            _ = try needJob(jobID)
            var e = estimate(jobID, base)
            let i = try optionIndex(e, optionID)
            guard let k = e.options[i].items.firstIndex(where: { $0.id == lineID }) else { throw Problem(message: "That line is no longer on the estimate.") }
            if let v = p.name { e.options[i].items[k].name = v }
            if let v = p.qty { e.options[i].items[k].qty = v }
            if let v = p.unit { e.options[i].items[k].unit = v }
            if let v = p.unitCents { e.options[i].items[k].unitCents = v }
            estimates[jobID] = e

        case .removeLine(let jobID, let optionID, let lineID):
            _ = try needJob(jobID)
            var e = estimate(jobID, base)
            let i = try optionIndex(e, optionID)
            guard e.options[i].items.contains(where: { $0.id == lineID }) else { throw Problem(message: "That line is no longer on the estimate.") }
            e.options[i].items.removeAll { $0.id == lineID }
            estimates[jobID] = e

        case .setMarkup(let jobID, let optionID, let profit, let overhead):
            _ = try needJob(jobID)
            var e = estimate(jobID, base)
            let i = try optionIndex(e, optionID)
            if let v = profit { e.options[i].profitPct = min(max(v, 0), 100) }
            if let v = overhead { e.options[i].overheadPct = min(max(v, 0), 100) }
            estimates[jobID] = e

        case .setScope(let jobID, let optionID, let text):
            _ = try needJob(jobID)
            var e = estimate(jobID, base)
            let i = try optionIndex(e, optionID)
            e.options[i].scope = text
            estimates[jobID] = e

        case .addOption(let jobID, let option):
            _ = try needJob(jobID)
            var e = estimate(jobID, base)
            guard !e.options.contains(where: { $0.id == option.id }) else { throw Problem(message: "That option already exists.") }
            e.options.append(option)
            e.selectedOptionID = option.id
            estimates[jobID] = e

        case .addScheduleDays(let jobID, let entries, let markWon):
            var j = try needJob(jobID)
            let fresh = entries.filter { new in !j.schedule.contains { $0.day.isSameDay(new.day) && $0.crewID == new.crewID } }
            guard !fresh.isEmpty else { throw Problem(message: "Those days are already on the schedule.") }
            j.schedule.append(contentsOf: fresh)
            if markWon && j.stage != .won {
                j.stage = .won
                j.stageChanged = now
            }
            j.updated = now
            jobs[jobID] = j

        case .removeScheduleDays(let jobID, let ids):
            var j = try needJob(jobID)
            guard j.schedule.contains(where: { ids.contains($0.id) }) else { throw Problem(message: "Those days are no longer on the schedule.") }
            j.schedule.removeAll { ids.contains($0.id) }
            j.updated = now
            jobs[jobID] = j

        case .addLog(let jobID, let log):
            _ = try needJob(jobID)
            var l = jobLogs(jobID, base)
            l.entries.insert(log, at: 0)
            logs[jobID] = l

        case .createInvoice(let jobID, let invoice):
            _ = try needJob(jobID)
            guard self.invoice(jobID, base) == nil else { throw Problem(message: "This job already has an invoice.") }
            invoices[jobID] = invoice

        case .setInvoicePaid(let jobID, let date):
            guard var inv = invoice(jobID, base) else { throw Problem(message: "This job has no invoice.") }
            inv.paidOn = date
            invoices[jobID] = inv

        case .updateRate(let id, let cents):
            var r = currentRates(base)
            guard let i = r.prices.firstIndex(where: { $0.id == id }) else { throw Problem(message: "That rate isn't in your price list.") }
            r.prices[i].cents = cents
            r.prices[i].changed = now
            rates = r

        case .updateShape(let jobID, let shapeID, let p):
            _ = try needJob(jobID)
            var t = takeoff(jobID, base)
            guard let i = t.shapes.firstIndex(where: { $0.id == shapeID }) else { throw Problem(message: "That measured area no longer exists.") }
            if let v = p.name { t.shapes[i].name = v }
            if let v = p.depthInches { t.shapes[i].depthInches = v }
            if let v = p.workType { t.shapes[i].workType = v }
            takeoffs[jobID] = t

        case .putShape(let jobID, let shape):
            _ = try needJob(jobID)
            var t = takeoff(jobID, base)
            if let i = t.shapes.firstIndex(where: { $0.id == shape.id }) { t.shapes[i] = shape } else { t.shapes.append(shape) }
            takeoffs[jobID] = t

        case .removeShape(let jobID, let shapeID):
            _ = try needJob(jobID)
            var t = takeoff(jobID, base)
            guard t.shapes.contains(where: { $0.id == shapeID }) else { throw Problem(message: "That measured area no longer exists.") }
            t.shapes.removeAll { $0.id == shapeID }
            takeoffs[jobID] = t

        case .updateSettings(let p):
            var s = currentSettings(base)
            p.apply(to: &s)
            settings = s

        case .mailDraft(let m):
            guard customer(m.customerID, base) != nil else { throw Problem(message: "That customer no longer exists.") }
            if let jid = m.jobID { _ = try needJob(jid) }
            mail.append(m)

        case .textDraft(let t):
            guard let c = customer(t.customerID, base) else { throw Problem(message: "That customer no longer exists.") }
            guard !c.phone.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem(message: "\(c.name) has no phone number on file.") }
            if let jid = t.jobID { _ = try needJob(jid) }
            texts.append(t)

        case .calendarExport(let c):
            for id in c.jobIDs { _ = try needJob(id) }
            calendar.append(c)
        }
    }
}
