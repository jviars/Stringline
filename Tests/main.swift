import Foundation
import CoreLocation

// Child-process mode for the kill test: write forever until killed.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--writer" {
    runWriter(folder: URL(fileURLWithPath: CommandLine.arguments[2]), start: Int(CommandLine.arguments[3]) ?? 0)
}
// Checker for scripts/kill-test.sh: is every file in a PavingData folder whole after the app was force-quit?
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--verify" {
    verifyFolder(URL(fileURLWithPath: CommandLine.arguments[2]), minimumCounter: Int(CommandLine.arguments[3]) ?? 0)
}

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name)  \(detail())") }
}
func near(_ a: Double, _ b: Double, _ pct: Double) -> Bool { abs(a - b) <= abs(b) * pct / 100 }

// Rectangle of w × h meters at a latitude
func rect(lat: Double, lon: Double, w: Double, h: Double) -> [Coordinate] {
    let dLat = h / 111_132.954
    let dLon = w / (111_320 * cos(lat * .pi / 180))
    return [Coordinate(lat: lat, lon: lon), Coordinate(lat: lat, lon: lon + dLon),
            Coordinate(lat: lat + dLat, lon: lon + dLon), Coordinate(lat: lat + dLat, lon: lon)]
}

// MARK: Geometry
let lot = rect(lat: 40, lon: -83, w: 100, h: 50)
let lotSqFt = Geo.areaSqFt(lot)
check("100 m × 50 m lot is 53,820 sq ft (±1%)", near(lotSqFt, 5000 * 10.7639, 1), "\(lotSqFt)")
let lotAt60 = Geo.areaSqFt(rect(lat: 60, lon: 10, w: 100, h: 50))
check("Area is right at other latitudes too", near(lotAt60, 5000 * 10.7639, 1), "\(lotAt60)")
let length = Geo.lengthFt([lot[0], lot[1]])
check("100 m line is 328 ft (±0.5%)", near(length, 328.084, 0.5), "\(length)")
var shape = TakeoffShape()
shape.points = lot
shape.holes = [rect(lat: 40.0001, lon: -82.9997, w: 10, h: 10)]
let net = Geo.netAreaSqFt(shape)
check("Cut-out subtracts 1,076 sq ft", near(lotSqFt - net, 100 * 10.7639, 2), "\(lotSqFt - net)")
check("Point inside lot", Geo.contains(lot, Geo.centroid(lot)))
check("Point outside lot", !Geo.contains(lot, Coordinate(lat: 41, lon: -83)))
check("Clockwise and counter-clockwise give the same area", near(Geo.areaSqFt(lot.reversed()), lotSqFt, 0.001))

// MARK: Worked example
var s = TakeoffSummary()
s.areaSqFt[.millOverlay] = 44_850
s.areaSqFt[.fullDepthPatch] = 1_350
s.lineFt[.striping] = 2_860
s.counts[.stall] = 112; s.counts[.ada] = 4; s.counts[.arrow] = 6
s.surfaceTons = 44_850.0 / 9 * 2 * 110 / 2000
s.baseTons = 1_350.0 / 9 * 4 * 110 / 2000
let rates = Rates()
let items = Estimator.buildItems(s, takeoff: Takeoff(), rates: rates)
func qty(_ key: String) -> Double { items.first { $0.key == key }?.qty ?? -1 }
check("Surface mix 576 tn (548 + 5% waste, rounded up)", qty("surfaceMix") == 576, "\(qty("surfaceMix"))")
check("Base mix 35 tn", qty("baseMix") == 35, "\(qty("baseMix"))")
check("Tack 299 gal", qty("tack") == 299, "\(qty("tack"))")
check("Milling 4,983 SY", qty("milling") == 4983, "\(qty("milling"))")
check("Crew 210 hours (7 × 10 × 3 days)", qty("crewLabor") == 210, "\(qty("crewLabor"))")
check("Paver 3 days", qty("paverRollers") == 3, "\(qty("paverRollers"))")
check("Striping 2,860 LF", qty("striping") == 2860, "\(qty("striping"))")
check("Stencils 10 (4 ADA + 6 arrows)", qty("stencil") == 10, "\(qty("stencil"))")
check("Truck loads 28", qty("truckLoad") == 28, "\(qty("truckLoad"))")
var opt = EstimateOption()
opt.items = items.filter { $0.key != "stencil" }
let b = opt.breakdown
check("Cost $75,549.95", b.costCents == 7_554_995, Fmt.dollars(b.costCents))
check("Overhead 10% = $7,555.00", b.overheadCents == 755_500, Fmt.dollars(b.overheadCents))
check("Profit 15% = $12,465.74", b.profitCents == 1_246_574, Fmt.dollars(b.profitCents))
check("Bid price $95,570.69", b.priceCents == 9_557_069, Fmt.dollars(b.priceCents))
check("Gross margin 20.9%", String(format: "%.1f", b.marginPct) == "20.9", "\(b.marginPct)")
check("Price per SY $18.62", String(format: "%.2f", Double(b.priceCents) / 100 / s.billableSY) == "18.62")
let scope = Estimator.scope(s, takeoff: Takeoff())
check("Scope mentions restriping counts", scope.contains("Restripe 112 stalls, 4 ADA stalls and 6 arrows"), scope)
check("Empty takeoff makes no lines", Estimator.buildItems(TakeoffSummary(), takeoff: Takeoff(), rates: rates).isEmpty)
var sealOnly = TakeoffSummary(); sealOnly.areaSqFt[.sealcoat] = 9_000
let sealItems = Estimator.buildItems(sealOnly, takeoff: Takeoff(), rates: rates)
check("Sealcoat-only job: no crew/paver/trucks, 1,000 SY sealer", sealItems.contains { $0.key == "sealcoat" && $0.qty == 1000 } && !sealItems.contains { $0.key == "crewLabor" || $0.key == "truckLoad" })

// MARK: Weather rules
let rules = WeatherRules()
func day(high: Double, low: Double, rain: Int, temps: [Double]) -> DayForecast {
    DayForecast(day: Date().startOfDay, high: high, low: low, rainChance: rain, code: 0, hourlyTemp: temps, hourlyRain: Array(repeating: rain, count: 24))
}
let warming = (0..<24).map { h -> Double in h < 6 ? 42 : min(62, 40 + Double(h - 6) * 2.6) }   // crosses 50 at ~10 AM
check("Rain 60% is a no-go", WeatherJudge.paving(day(high: 70, low: 55, rain: 60, temps: Array(repeating: 65, count: 24)), rules).level == .noGo)
check("High of 45 is too cold to pave", WeatherJudge.paving(day(high: 45, low: 30, rain: 0, temps: Array(repeating: 40, count: 24)), rules).level == .noGo)
let later = WeatherJudge.paving(day(high: 62, low: 42, rain: 0, temps: warming), rules)
check("Cold morning warming past 50 is 'Go after 10 AM'", later.level == .goLater && later.short == "Go after 10 AM", later.short)
check("Warm day is a plain Go", WeatherJudge.paving(day(high: 75, low: 58, rain: 10, temps: Array(repeating: 66, count: 24)), rules).level == .go)
check("Cold night is a sealcoat no-go", WeatherJudge.sealcoat(day(high: 62, low: 40, rain: 0, temps: warming), rules).level == .noGo)
check("General call warns about cold nights", WeatherJudge.general(day(high: 62, low: 40, rain: 0, temps: warming), rules).level == .watch)
var sealJob = Job(); sealJob.services = [.sealcoat, .striping]
var paveJob = Job(); paveJob.services = [.millOverlay, .striping]
check("Seal-and-stripe job follows the sealcoat rule", sealJob.followsSealcoatRule && !paveJob.followsSealcoatRule)

// MARK: Forecast parsing
let sample = """
{"daily":{"time":["2026-10-08","2026-10-09"],"temperature_2m_max":[62.1,57.0],"temperature_2m_min":[44.0,49.2],"precipitation_probability_max":[0,70],"weather_code":[1,63]},
 "hourly":{"time":[\((0..<48).map { "\"2026-10-\($0 < 24 ? "08" : "09")T\(String(format: "%02d", $0 % 24)):00\"" }.joined(separator: ","))],
 "temperature_2m":[\((0..<48).map { _ in "50.0" }.joined(separator: ","))],"precipitation_probability":[\((0..<48).map { _ in "10" }.joined(separator: ","))]}}
"""
let parsed = (try? MainActor.assumeIsolated { try WeatherModel.parse(Data(sample.utf8)) }) ?? []
check("Open-Meteo response parses into days with 24 hourly temps", parsed.count == 2 && parsed[0].hourlyTemp.count == 24 && parsed[1].rainChance == 70)
check("Rain code shows a rain icon", parsed.last?.symbol == "cloud.rain")

// MARK: Files
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let settingsURL = dir.appendingPathComponent("settings.json")
var settings = AppSettings(); settings.company.name = "Round Trip Co"; settings.lastBackup = Date()
try! JSONFile.write(settings, to: settingsURL)
check("Settings survive a write and read", JSONFile.read(AppSettings.self, from: settingsURL)?.company.name == "Round Trip Co")
try! Data(#"{"schemaVersion":1,"factors":{"wastePct":7}}"#.utf8).write(to: dir.appendingPathComponent("rates.json"))
let oldRates = JSONFile.read(Rates.self, from: dir.appendingPathComponent("rates.json"))
check("Old rates file keeps its own waste % and gets default prices", oldRates?.factors.wastePct == 7 && oldRates?.factors.mixLbPerSYInch == 110 && oldRates?.prices.count == 12)
try! Data("{ not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
check("A broken file returns nothing instead of crashing", JSONFile.read(Job.self, from: dir.appendingPathComponent("broken.json")) == nil)

// MARK: Calendar, formatting, invoices
var entry = ScheduleEntry(); entry.day = Date().startOfDay; entry.startTime = "7:30 AM"
let start = CalendarExport.startDate(for: entry)
check("Start time 7:30 AM is read correctly", Calendar.current.component(.hour, from: start) == 7 && Calendar.current.component(.minute, from: start) == 30)
var calJob = Job(); calJob.name = "Smith, Jones; Lot"; calJob.address = "1 Main St, Town"
let ics = CalendarExport.ics([(job: calJob, entry: entry, crew: nil)])
check("Calendar file escapes commas and semicolons", ics.contains("SUMMARY:Smith\\, Jones\\; Lot") && ics.contains("BEGIN:VEVENT"))
check("Money formats with commas and cents", Fmt.dollars(7_554_995) == "$75,549.95" && Fmt.dollars(9_557_069, showCents: false) == "$95,571")
check("Folder names are safe", Fmt.slug("Maple Ridge Plaza / Lot #2!") == "maple-ridge-plaza-lot-2")
var invoice = Invoice(); invoice.issued = Date().adding(days: -45); invoice.dueDays = 30; invoice.amountCents = 100_000; invoice.depositCents = 25_000
check("Invoice 45 days old on Net 30 is 15 days late, $750 balance", invoice.daysLate == 15 && invoice.balanceCents == 75_000, "\(invoice.daysLate)")
invoice.paidOn = Date()
check("Paid invoice is never late", invoice.daysLate == 0)
check("Monday of the week", Calendar.current.component(.weekday, from: Calendar.current.mondayOfWeek(Date())) == 2)

// MARK: Assistant
runAssistantTests(workedExample: items)
runAssistantTortureTests()
runAssistantMapTests()
runZohoImportTests()

// MARK: Data safety
print("\n-- Data safety")
runSafetyTests(dir)
runSyncStallTests(dir)
print("\n-- Kill test")
runKillTest(dir, rounds: Int(ProcessInfo.processInfo.environment["STRINGLINE_KILL_ROUNDS"] ?? "") ?? 300)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
