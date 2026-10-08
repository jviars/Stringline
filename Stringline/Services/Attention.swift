import Foundation

struct AttentionItem: Identifiable, Hashable {
    enum Kind { case rain, ticket, followUp, invoice }
    var id: String { "\(kind)-\(jobID)-\(title)" }
    let kind: Kind
    let title: String
    let detail: String
    let jobID: UUID
    let action: String
}

/// The "Needs attention" list on Today: rain on a job day, 811 tickets, quiet bids, late invoices.
enum Attention {
    @MainActor
    static func items(_ store: AppStore) -> [AttentionItem] {
        var out: [AttentionItem] = []
        let cal = Calendar.current
        let today = Date().startOfDay
        let rules = store.settings.weather

        for job in store.realJobs where job.stage == .won {
            let upcoming = job.schedule.filter { $0.day >= today }
            for entry in upcoming where entry.day <= today.adding(days: 3) {
                guard let forecast = store.weather.forecast(for: entry.day) else { continue }
                let call = WeatherJudge.call(for: job, on: forecast, rules)
                if call.level == .noGo {
                    out.append(AttentionItem(kind: .rain, title: "\(call.short.replacingOccurrences(of: "No-go · ", with: "").capitalizedFirst) \(Fmt.weekday(entry.day)) at \(job.name)",
                                             detail: call.detail, jobID: job.id, action: "Move"))
                }
            }
            guard !upcoming.isEmpty, !job.ticket.notNeeded else { continue }
            if let until = job.ticket.goodUntil {
                let days = cal.daysBetween(today, until)
                if days <= 2 {
                    let when = days < 0 ? "expired" : days == 0 ? "expires today" : days == 1 ? "expires tomorrow" : "expires in 2 days"
                    let number = job.ticket.number.isEmpty ? "" : " · #\(job.ticket.number)"
                    out.append(AttentionItem(kind: .ticket, title: "811 ticket \(when)", detail: "\(job.name)\(number)", jobID: job.id, action: "Renew"))
                }
            } else if job.ticket.number.isEmpty {
                out.append(AttentionItem(kind: .ticket, title: "No 811 ticket yet", detail: "\(job.name) is on the schedule", jobID: job.id, action: "Add"))
            }
        }

        for job in store.realJobs where job.stage == .sent {
            guard let sent = job.sentOn else { continue }
            let days = cal.daysBetween(sent, today)
            if days >= 7 {
                let price = store.priceCents(for: job.id).map { Fmt.dollars($0, showCents: false) + " · " } ?? ""
                out.append(AttentionItem(kind: .followUp, title: "Follow up: \(job.name)", detail: "\(price)sent \(days) days ago, no reply", jobID: job.id, action: "Follow up"))
            }
        }

        for job in store.realJobs {
            guard let invoice = store.invoices[job.id], !invoice.isPaid, invoice.daysLate > 0 else { continue }
            out.append(AttentionItem(kind: .invoice, title: "Invoice \(invoice.number) is \(invoice.daysLate) days late",
                                     detail: "\(store.customerName(for: job)) · \(Fmt.dollars(invoice.balanceCents, showCents: false))", jobID: job.id, action: "Open"))
        }
        return out
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
