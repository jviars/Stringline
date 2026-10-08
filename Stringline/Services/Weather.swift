import Foundation

struct DayForecast: Identifiable, Hashable {
    var id: Date { day }
    let day: Date
    let high: Double
    let low: Double
    let rainChance: Int
    let code: Int
    let hourlyTemp: [Double]
    let hourlyRain: [Int]

    var symbol: String {
        switch code {
        case 0: "sun.max"
        case 1, 2: "cloud.sun"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51...67, 80...82: "cloud.rain"
        case 71...77, 85, 86: "cloud.snow"
        case 95...99: "cloud.bolt.rain"
        default: "cloud.sun"
        }
    }
}

/// Forecast from Open-Meteo (free, no key). Only the home base coordinates are sent.
@Observable @MainActor
final class WeatherModel {
    var days: [DayForecast] = []
    var updated: Date?
    var error: String?
    var loading = false

    @ObservationIgnored private var lastKey = ""

    func forecast(for day: Date) -> DayForecast? {
        days.first { $0.day.isSameDay(day) }
    }

    func refresh(lat: Double, lon: Double, force: Bool = false) async {
        let key = String(format: "%.3f,%.3f", lat, lon)
        if !force, key == lastKey, let updated, Date.now.timeIntervalSince(updated) < 30 * 60 { return }
        loading = true
        defer { loading = false }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "past_days", value: "7"),
            URLQueryItem(name: "forecast_days", value: "14"),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            days = try Self.parse(data)
            updated = .now
            error = nil
            lastKey = key
        } catch {
            self.error = "Couldn't reach the weather service."
        }
    }

    private struct Response: Decodable {
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Int?]
            let weather_code: [Int?]
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let precipitation_probability: [Int?]
        }
        let daily: Daily
        let hourly: Hourly
    }

    static func parse(_ data: Data) throws -> [DayForecast] {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        dayFormat.locale = Locale(identifier: "en_US_POSIX")

        var temps: [String: [Double]] = [:]
        var rains: [String: [Int]] = [:]
        for (i, stamp) in r.hourly.time.enumerated() {
            let key = String(stamp.prefix(10))
            temps[key, default: []].append(r.hourly.temperature_2m[safe: i].flatMap { $0 } ?? .nan)
            rains[key, default: []].append(r.hourly.precipitation_probability[safe: i].flatMap { $0 } ?? 0)
        }

        return r.daily.time.enumerated().compactMap { i, stamp in
            guard let day = dayFormat.date(from: stamp),
                  let high = r.daily.temperature_2m_max[safe: i].flatMap({ $0 }),
                  let low = r.daily.temperature_2m_min[safe: i].flatMap({ $0 }) else { return nil }
            return DayForecast(day: day.startOfDay, high: high, low: low,
                               rainChance: r.daily.precipitation_probability_max[safe: i].flatMap { $0 } ?? 0,
                               code: r.daily.weather_code[safe: i].flatMap { $0 } ?? 0,
                               hourlyTemp: temps[stamp] ?? [], hourlyRain: rains[stamp] ?? [])
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
