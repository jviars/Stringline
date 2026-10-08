import Foundation
import AppKit

/// Writes schedule entries to an .ics file and hands it to Calendar, which asks where to put them.
enum CalendarExport {
    static func startDate(for entry: ScheduleEntry) -> Date {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "h:mm a"
        guard let time = parser.date(from: entry.startTime.uppercased()) else { return entry.day.addingTimeInterval(7 * 3600) }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.date(bySettingHour: parts.hour ?? 7, minute: parts.minute ?? 0, second: 0, of: entry.day) ?? entry.day
    }

    static func ics(_ items: [(job: Job, entry: ScheduleEntry, crew: Crew?)]) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Stringline//Schedule//EN", "CALSCALE:GREGORIAN"]
        for item in items {
            let start = startDate(for: item.entry)
            let end = start.addingTimeInterval(10 * 3600)
            let crew = item.crew.map { "\($0.name): " } ?? ""
            let services = item.job.services.map(\.label).joined(separator: ", ")
            lines += [
                "BEGIN:VEVENT",
                "UID:\(item.entry.id.uuidString)@stringline",
                "DTSTAMP:\(stamp.string(from: .now))",
                "DTSTART:\(stamp.string(from: start))",
                "DTEND:\(stamp.string(from: end))",
                "SUMMARY:\(escape(crew + item.job.name))",
                "LOCATION:\(escape(item.job.address))",
                "DESCRIPTION:\(escape([services, item.entry.note, item.job.plantNote].filter { !$0.isEmpty }.joined(separator: "\n")))",
                "END:VEVENT",
            ]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    @MainActor
    static func open(_ items: [(job: Job, entry: ScheduleEntry, crew: Crew?)], name: String) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).ics")
        try ics(items).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }
}
