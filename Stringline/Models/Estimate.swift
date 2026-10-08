import Foundation

struct LineItem: Codable, Hashable, Identifiable, DefaultInit {
    var id = UUID()
    var group = "Materials"
    var name = ""
    var qty: Double = 1
    var unit = "ea"
    var unitCents = 0
    /// Quantity comes straight from the measurements.
    var fromTakeoff = false
    /// Set on lines Stringline generated, so "Update from takeoff" can refresh them. Empty for lines the owner added.
    var key = ""

    var totalCents: Int { Int((qty * Double(unitCents)).rounded()) }
}

struct PriceBreakdown: Hashable {
    var costCents: Int
    var overheadCents: Int
    var profitCents: Int
    var priceCents: Int { costCents + overheadCents + profitCents }
    var overCostCents: Int { priceCents - costCents }
    var marginPct: Double { priceCents == 0 ? 0 : Double(overCostCents) / Double(priceCents) * 100 }
}

struct EstimateOption: Codable, Hashable, Identifiable, DefaultInit {
    var id = UUID()
    var title = "Option"
    var items: [LineItem] = []
    var overheadPct: Double = 10
    var profitPct: Double = 15
    var scope = ""

    static let groups = ["Materials", "Labor", "Equipment & subs", "Trucking & general"]

    var breakdown: PriceBreakdown {
        let cost = items.reduce(0) { $0 + $1.totalCents }
        let overhead = Int((Double(cost) * overheadPct / 100).rounded())
        let profit = Int((Double(cost + overhead) * profitPct / 100).rounded())
        return PriceBreakdown(costCents: cost, overheadCents: overhead, profitCents: profit)
    }

    func subtotal(group: String) -> Int {
        items.filter { $0.group == group }.reduce(0) { $0 + $1.totalCents }
    }
}

struct Estimate: Codable, Hashable, DefaultInit {
    var schemaVersion = 1
    var options: [EstimateOption] = []
    var selectedOptionID: UUID?
    var proposalNumber = ""

    var selected: EstimateOption? {
        options.first { $0.id == selectedOptionID } ?? options.first
    }
}

// MARK: - Rates

struct PriceItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var unit: String
    var cents: Int
    var group: String
    var changed: Date = Date()
}

struct Factors: Codable, Hashable, DefaultInit {
    var mixLbPerSYInch: Double = 110
    var tackGalPerSY: Double = 0.06
    var paintLFPerGal: Double = 320
    var wastePct: Double = 5
    var truckTons: Double = 22
    var overheadPct: Double = 10
    var profitPct: Double = 15
    var crewSize: Double = 7
    var hoursPerDay: Double = 10
    var paveSYPerDay: Double = 2000
}

struct Rates: Codable, Hashable, DefaultInit {
    var schemaVersion = 1
    var prices: [PriceItem] = Rates.starterPrices
    var factors = Factors()

    static let groups = ["Materials", "Subcontractors", "Labor & equipment", "Trucking"]

    /// Sample numbers so the math works on day one. The owner replaces them.
    static let starterPrices: [PriceItem] = [
        PriceItem(id: "surfaceMix", name: "Surface mix 9.5 mm", unit: "ton", cents: 7800, group: "Materials"),
        PriceItem(id: "baseMix", name: "Base & patch mix 19 mm", unit: "ton", cents: 7200, group: "Materials"),
        PriceItem(id: "tack", name: "Tack coat", unit: "gal", cents: 310, group: "Materials"),
        PriceItem(id: "sealcoat", name: "Sealcoat, 2 coats", unit: "SY", cents: 95, group: "Materials"),
        PriceItem(id: "crackSeal", name: "Crack seal, hot-pour", unit: "LF", cents: 85, group: "Materials"),
        PriceItem(id: "milling", name: "Milling (sub)", unit: "SY", cents: 135, group: "Subcontractors"),
        PriceItem(id: "striping", name: "Striping (sub)", unit: "LF", cents: 30, group: "Subcontractors"),
        PriceItem(id: "stencil", name: "Stencils (ADA, arrows)", unit: "ea", cents: 4500, group: "Subcontractors"),
        PriceItem(id: "crewLabor", name: "Crew labor", unit: "hr", cents: 4200, group: "Labor & equipment"),
        PriceItem(id: "paverRollers", name: "Paver & rollers", unit: "day", cents: 145000, group: "Labor & equipment"),
        PriceItem(id: "mobilization", name: "Mobilization", unit: "LS", cents: 180000, group: "Labor & equipment"),
        PriceItem(id: "truckLoad", name: "Tri-axle load", unit: "load", cents: 16500, group: "Trucking"),
    ]

    func cents(_ key: String) -> Int { prices.first { $0.id == key }?.cents ?? 0 }
    func name(_ key: String) -> String { prices.first { $0.id == key }?.name ?? key }
}
