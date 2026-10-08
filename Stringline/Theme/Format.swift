import Foundation

enum Fmt {
    private static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// Cents to "$1,234.56".
    static func dollars(_ cents: Int, showCents: Bool = true) -> String {
        money.minimumFractionDigits = showCents ? 2 : 0
        money.maximumFractionDigits = showCents ? 2 : 0
        return money.string(from: NSNumber(value: Double(cents) / 100)) ?? "$0"
    }

    static func number(_ value: Double, decimals: Int = 0) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: value)) ?? "0"
    }

    static func plain(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }

    static func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
    static func dayYear(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day().year()) }
    static func weekday(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated)) }
    static func longDay(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
    static func monthYear(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).year()) }

    static func hour12(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    static func ago(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: .now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "job" : String(out.prefix(40))
    }
}

extension Calendar {
    func daysBetween(_ a: Date, _ b: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: a), to: startOfDay(for: b)).day ?? 0
    }

    /// Monday of the week containing `date`.
    func mondayOfWeek(_ date: Date) -> Date {
        let start = startOfDay(for: date)
        let weekday = component(.weekday, from: start) // 1 = Sunday
        let offset = (weekday + 5) % 7
        return self.date(byAdding: .day, value: -offset, to: start) ?? start
    }
}

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
    func adding(days: Int) -> Date { Calendar.current.date(byAdding: .day, value: days, to: self) ?? self }
    func isSameDay(_ other: Date) -> Bool { Calendar.current.isDate(self, inSameDayAs: other) }
}
