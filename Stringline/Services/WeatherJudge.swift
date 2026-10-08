import Foundation

enum GoLevel: Int, Comparable {
    case go = 0, goLater, watch, noGo
    static func < (a: GoLevel, b: GoLevel) -> Bool { a.rawValue < b.rawValue }
}

struct GoCall: Hashable {
    let level: GoLevel
    let short: String
    let detail: String
}

/// Applies the owner's weather rules to a day's forecast.
enum WeatherJudge {
    static func paving(_ d: DayForecast, _ r: WeatherRules) -> GoCall {
        let min = Int(r.pavingMinF)
        if d.rainChance >= r.rainChanceMax {
            return GoCall(level: .noGo, short: "No-go · \(d.rainChance)% rain", detail: "\(d.rainChance)% chance of rain.")
        }
        if d.high < r.pavingMinF {
            return GoCall(level: .noGo, short: "No-go · too cold", detail: "High of \(Int(d.high))°, under your \(min)° minimum.")
        }
        let temps = d.hourlyTemp
        for hour in 6...15 where hour + 1 < temps.count {
            let now = temps[hour], next = temps[hour + 1]
            guard !now.isNaN, !next.isNaN else { continue }
            if now >= r.pavingMinF && next >= now - 0.5 {
                let rain = d.rainChance == 0 ? "No rain." : "Rain \(d.rainChance)%."
                if hour <= 8 {
                    return GoCall(level: .go, short: "Go", detail: "\(min)° and rising by \(Fmt.hour12(hour)). \(rain)")
                }
                return GoCall(level: .goLater, short: "Go after \(Fmt.hour12(hour))", detail: "\(min)° and rising by \(Fmt.hour12(hour)). \(rain)")
            }
        }
        return GoCall(level: .watch, short: "Watch", detail: "Only briefly above \(min)°. High of \(Int(d.high))°.")
    }

    static func sealcoat(_ d: DayForecast, _ r: WeatherRules) -> GoCall {
        if d.rainChance >= r.rainChanceMax {
            return GoCall(level: .noGo, short: "No-go · \(d.rainChance)% rain", detail: "\(d.rainChance)% chance of rain.")
        }
        if d.low < r.sealcoatMinF {
            return GoCall(level: .noGo, short: "No-go · cold night", detail: "Low of \(Int(d.low))°. Sealcoat needs \(Int(r.sealcoatMinF))°+ for \(r.sealcoatHours) h.")
        }
        return GoCall(level: .go, short: "Go", detail: "Stays above \(Int(r.sealcoatMinF))° all day and night.")
    }

    /// The headline call for the weather card: paving first, with a heads-up when it's too cold for sealcoat.
    static func general(_ d: DayForecast, _ r: WeatherRules) -> GoCall {
        let pave = paving(d, r)
        guard pave.level != .noGo, d.low < r.sealcoatMinF else { return pave }
        let paveText = pave.level == .go ? "Paving is fine." : "Paving OK after \(pave.short.replacingOccurrences(of: "Go after ", with: ""))."
        return GoCall(level: .watch, short: "Watch · cold night", detail: "\(paveText) Too cold overnight for sealcoat.")
    }

    static func call(for job: Job, on d: DayForecast, _ r: WeatherRules) -> GoCall {
        job.followsSealcoatRule ? sealcoat(d, r) : paving(d, r)
    }
}
