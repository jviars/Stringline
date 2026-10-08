import Foundation

struct Coordinate: Codable, Hashable {
    var lat: Double
    var lon: Double
}

enum ShapeKind: String, Codable, Hashable {
    case area, line, count
}

enum WorkType: String, Codable, CaseIterable, Identifiable, Hashable {
    case millOverlay, newPaving, fullDepthPatch, sealcoat, crackSeal, striping, curb

    var id: String { rawValue }
    var label: String {
        switch self {
        case .millOverlay: "Mill & overlay"
        case .newPaving: "New paving"
        case .fullDepthPatch: "Full-depth patch"
        case .sealcoat: "Sealcoat"
        case .crackSeal: "Crack seal"
        case .striping: "Striping"
        case .curb: "Curb"
        }
    }
    var isArea: Bool { self == .millOverlay || self == .newPaving || self == .fullDepthPatch || self == .sealcoat }
    var hasDepth: Bool { self == .millOverlay || self == .newPaving || self == .fullDepthPatch }
    var defaultDepth: Double {
        switch self {
        case .fullDepthPatch: 4
        case .millOverlay, .newPaving: 2
        default: 0
        }
    }
    /// Map colors differ in lightness, not just hue.
    var hex: UInt32 {
        switch self {
        case .millOverlay: 0xFFC21A
        case .newPaving: 0xB8E04A
        case .fullDepthPatch: 0xF06A1D
        case .sealcoat: 0x3B82F6
        case .crackSeal: 0xF472B6
        case .striping: 0x22D3EE
        case .curb: 0xF5F5F4
        }
    }
    static var areaTypes: [WorkType] { allCases.filter(\.isArea) }
    static var lineTypes: [WorkType] { allCases.filter { !$0.isArea } }
}

enum CountKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case stall, ada, arrow, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stall: "Stalls"
        case .ada: "ADA stalls"
        case .arrow: "Arrows"
        case .other: "Other"
        }
    }
}

struct TakeoffShape: Codable, Hashable, Identifiable, DefaultInit {
    var id = UUID()
    var name = ""
    var kind: ShapeKind = .area
    var workType: WorkType = .millOverlay
    var depthInches: Double = 2
    var points: [Coordinate] = []
    var holes: [[Coordinate]] = []
    var countKind: CountKind = .stall
    var quantity = 1
}

enum Imagery: String, Codable, Hashable {
    case apple, esri
}

struct Takeoff: Codable, Hashable, DefaultInit {
    var schemaVersion = 1
    var shapes: [TakeoffShape] = []
    var imagery: Imagery = .apple
    var center: Coordinate?
    var spanMeters: Double?
}
