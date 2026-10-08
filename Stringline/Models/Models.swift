import Foundation

/// Every model has an `init()` so files written by older versions can be merged
/// with today's defaults when a key is missing.
protocol DefaultInit { init() }

// MARK: - Services and job types

enum Service: String, Codable, CaseIterable, Identifiable, Hashable {
    case millOverlay, newPaving, patching, sealcoat, crackSeal, striping, concrete, grading

    var id: String { rawValue }
    var label: String {
        switch self {
        case .millOverlay: "Mill & overlay"
        case .newPaving: "New paving"
        case .patching: "Patching"
        case .sealcoat: "Sealcoat"
        case .crackSeal: "Crack seal"
        case .striping: "Striping"
        case .concrete: "Concrete"
        case .grading: "Grading & base"
        }
    }
    /// Seal, crack and stripe work follow the sealcoat weather rule instead of the paving rule.
    var followsSealcoatRule: Bool { self == .sealcoat || self == .crackSeal || self == .striping }
}

enum CustomerType: String, Codable, CaseIterable, Identifiable, Hashable {
    case commercial, residential, hoa, publicBid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .commercial: "Commercial"
        case .residential: "Residential"
        case .hoa: "HOA"
        case .publicBid: "Public bid"
        }
    }
}

enum Stage: String, Codable, CaseIterable, Identifiable, Hashable {
    case lead, siteVisit, estimating, sent, won, lost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lead: "Lead"
        case .siteVisit: "Site visit"
        case .estimating: "Estimating"
        case .sent: "Sent"
        case .won: "Won"
        case .lost: "Lost"
        }
    }
    static let board: [Stage] = [.lead, .siteVisit, .estimating, .sent, .won]
}

// MARK: - Settings

struct CompanyInfo: Codable, Hashable, DefaultInit {
    var name = ""
    var phone = ""
    var email = ""
    var address = ""
    var license = ""
    var website = ""
    var homeBase = ""
    var homeLatitude: Double?
    var homeLongitude: Double?
    var hasLogo = false
}

struct WeatherRules: Codable, Hashable, DefaultInit {
    var pavingMinF: Double = 50
    var sealcoatMinF: Double = 50
    var sealcoatHours: Int = 24
    var rainChanceMax: Int = 40
    var rainLookaheadHours: Int = 24
}

struct ProposalTemplate: Codable, Hashable, DefaultInit {
    var validDays = 30
    var escalationClause = true
    var exclusions = "Permits and fees unless listed above. Concrete, curb and drainage repairs. Base or subgrade failures found once work starts. Traffic control beyond cones and barricades."
    var terms = "Payment is due within 30 days of completion. Prices are good for the number of days shown above."
    var escalationText = "If the asphalt price index rises more than 5% before work starts, material prices will be adjusted to match."
}

struct Crew: Codable, Hashable, Identifiable, DefaultInit {
    var id = UUID()
    var name = "New crew"
    var kind = "Paving"
    var people = 4
    var equipment = ""
}

struct AppSettings: Codable, Hashable, DefaultInit {
    var schemaVersion = 1
    var onboardingComplete = false
    var company = CompanyInfo()
    var services: [Service] = [.millOverlay, .newPaving, .patching, .sealcoat, .crackSeal, .striping]
    var weather = WeatherRules()
    var proposal = ProposalTemplate()
    var crews: [Crew] = [
        Crew(name: "Crew A", kind: "Paving", people: 7, equipment: "Paver, two rollers"),
        Crew(name: "Crew B", kind: "Seal & stripe", people: 3, equipment: "Sealer rig, melter"),
    ]
    var sealcoatCycleYears = 3
    var nextProposalNumber = 1
    var nextInvoiceNumber = 1001
    var tourCompleted = false
    var lessonsDone: [String] = []
    var checklistDismissed = false
    var backupNightly = true
    var lastBackup: Date?
}

// MARK: - Customers

struct Customer: Codable, Hashable, Identifiable, DefaultInit {
    var schemaVersion = 1
    var id = UUID()
    var name = ""
    var contact = ""
    var phone = ""
    var email = ""
    var address = ""
    var type: CustomerType = .commercial
    var notes = ""
    var created = Date()
}

// MARK: - Jobs

struct Ticket811: Codable, Hashable, DefaultInit {
    var number = ""
    var goodUntil: Date?
    var notNeeded = false
}

struct ScheduleEntry: Codable, Hashable, Identifiable, DefaultInit {
    var id = UUID()
    var day = Date().startOfDay
    var crewID: UUID?
    var startTime = "7:00 AM"
    var note = ""
}

struct Job: Codable, Hashable, Identifiable, DefaultInit {
    var schemaVersion = 1
    var id = UUID()
    var number = ""
    var name = ""
    var customerID: UUID?
    var address = ""
    var latitude: Double?
    var longitude: Double?
    var type: CustomerType = .commercial
    var services: [Service] = []
    var stage: Stage = .lead
    var stageChanged = Date()
    var created = Date()
    var updated = Date()
    var source = ""
    var notes = ""
    var bidDue: Date?
    var siteVisit: Date?
    var sentOn: Date?
    var preBid: Date?
    var bidBondPct: Double?
    var schedule: [ScheduleEntry] = []
    var ticket = Ticket811()
    var plantNote = ""
    var completedOn: Date?
    var lostReason = ""
    var isSample = false
    var folderName = ""

    var followsSealcoatRule: Bool {
        !services.isEmpty && services.allSatisfy { $0.followsSealcoatRule }
    }
}

// MARK: - Logs and invoices

struct DailyLog: Codable, Hashable, Identifiable, DefaultInit {
    var id = UUID()
    var day = Date().startOfDay
    var crewID: UUID?
    var tons: Double = 0
    var hours: Double = 0
    var weather = ""
    var notes = ""
}

struct JobLogs: Codable, Hashable, DefaultInit {
    var schemaVersion = 1
    var entries: [DailyLog] = []
}

struct Invoice: Codable, Hashable, Identifiable, DefaultInit {
    var schemaVersion = 1
    var id = UUID()
    var number = ""
    var issued = Date().startOfDay
    var dueDays = 30
    var amountCents = 0
    var depositCents = 0
    var paidOn: Date?
    var note = ""

    var due: Date { issued.adding(days: dueDays) }
    var balanceCents: Int { max(0, amountCents - depositCents) }
    var isPaid: Bool { paidOn != nil }
    var daysLate: Int { isPaid ? 0 : max(0, Calendar.current.daysBetween(due, .now)) }
    var daysOutstanding: Int { Calendar.current.daysBetween(issued, paidOn ?? .now) }
}
