import SwiftUI

struct PipelineView: View {
    @Environment(AppStore.self) private var store
    @State private var typeFilter: CustomerType?
    @State private var showLost = false

    private var jobs: [Job] {
        store.jobs.filter { typeFilter == nil || $0.type == typeFilter }
    }

    var body: some View {
        let real = store.realJobs
        let open = real.filter { Stage.board.dropLast().contains($0.stage) }
        let monthAgo = Date.now.adding(days: -30)
        let wonRecent = real.filter { $0.stage == .won && $0.stageChanged >= monthAgo }
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "\(open.count) open · \(wonRecent.count) won in the last 30 days", title: "Pipeline") {
                Toggle("Show lost", isOn: $showLost).toggleStyle(.button).buttonStyle(SecondaryButtonStyle()).helpSpot("pipeline.showLost")
                Button {
                    store.showNewLead = true
                } label: {
                    Label("New lead", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .helpSpot("pipeline.newLead")
            }
            VStack(alignment: .leading, spacing: 14) {
                stats(real)
                HStack {
                    Picker("Customer type", selection: $typeFilter) {
                        Text("All").tag(CustomerType?.none)
                        ForEach(CustomerType.allCases) { Text($0.label).tag(CustomerType?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 440)
                    Spacer()
                    Text("Drag a card to move it to another stage").font(.ui(12)).foregroundStyle(Palette.tertiary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 14)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Stage.board + (showLost ? [.lost] : [])) { stage in
                        let column = PipelineColumn(stage: stage, jobs: jobs.filter { $0.stage == stage }.sorted { $0.stageChanged > $1.stageChanged })
                        if stage == .sent {
                            column.tourAnchor(.pipeline)
                        } else {
                            column
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .helpSpot("pipeline.board")
        }
    }

    private func stats(_ real: [Job]) -> some View {
        let sent = real.filter { $0.stage == .sent }
        let estimating = real.filter { $0.stage == .estimating }
        let monthAgo = Date.now.adding(days: -30)
        let won = real.filter { $0.stage == .won && $0.stageChanged >= monthAgo }
        let year = Calendar.current.component(.year, from: .now)
        let decided = real.filter { ($0.stage == .won || $0.stage == .lost) && Calendar.current.component(.year, from: $0.stageChanged) == year }
        let wonYear = decided.filter { $0.stage == .won }.count
        let followUps = sent.filter { ($0.sentOn.map { Calendar.current.daysBetween($0, .now) } ?? 0) >= 7 }.count
        func total(_ list: [Job]) -> Int { list.compactMap { store.priceCents(for: $0.id) }.reduce(0, +) }
        return HStack(spacing: 0) {
            stat("Sent, waiting on an answer", Fmt.dollars(total(sent), showCents: false),
                 "\(sent.count) bid\(sent.count == 1 ? "" : "s")\(followUps > 0 ? " · \(followUps) need a follow-up" : "")")
            VRule().padding(.vertical, 4)
            stat("Being estimated", Fmt.dollars(total(estimating), showCents: false), "\(estimating.count) draft\(estimating.count == 1 ? "" : "s")")
            VRule().padding(.vertical, 4)
            stat("Won, last 30 days", Fmt.dollars(total(won), showCents: false), "\(won.count) job\(won.count == 1 ? "" : "s")")
            VRule().padding(.vertical, 4)
            stat("Win rate this year", decided.isEmpty ? "—" : "\(Int((Double(wonYear) / Double(decided.count) * 100).rounded()))%",
                 decided.isEmpty ? "No decided bids yet" : "\(wonYear) of \(decided.count) decided")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border))
    }

    private func stat(_ label: String, _ value: String, _ note: String) -> some View {
        StatBlock(label: label, value: value, note: note)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }
}

private struct PipelineColumn: View {
    @Environment(AppStore.self) private var store
    let stage: Stage
    let jobs: [Job]
    @State private var targeted = false

    var body: some View {
        let total = jobs.compactMap { store.priceCents(for: $0.id) }.reduce(0, +)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(stage.dotColor).frame(width: 8, height: 8)
                Text(stage.label).font(.ui(13, weight: .bold))
                Text("\(jobs.count)").font(.ui(12)).foregroundStyle(Palette.secondary)
                Spacer()
                if total > 0 {
                    Text(Fmt.dollars(total, showCents: false)).font(.ui(12, weight: .semibold)).foregroundStyle(Color(hex: 0x3F4249)).monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            if jobs.isEmpty {
                Text(emptyText)
                    .font(.ui(12))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xD5D5D0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            }
            ForEach(jobs) { job in
                PipelineCard(job: job)
                    .draggable(job.id.uuidString) {
                        Text(job.name).font(.ui(13, weight: .semibold)).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .padding(10)
        .frame(width: 214, alignment: .top)
        .frame(minHeight: 420, alignment: .top)
        .background(targeted ? Color(hex: 0xDEDED8) : Color(hex: 0xE9E9E5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Palette.ink : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            store.setStage(id, stage)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var emptyText: String {
        switch stage {
        case .lead: "New calls and web forms land here"
        case .siteVisit: "Drag a lead here once you book a visit"
        case .estimating: "Jobs you're pricing"
        case .sent: "Proposals waiting on an answer"
        case .won: "Signed work"
        case .lost: "Bids that didn't go your way"
        }
    }
}

private struct PipelineCard: View {
    @Environment(AppStore.self) private var store
    let job: Job
    @State private var hovering = false

    var body: some View {
        let days = Calendar.current.daysBetween(job.stageChanged, .now)
        let price = store.priceCents(for: job.id)
        Button {
            store.openJob(job.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.isSample ? "SAMPLE" : job.type.label.uppercased())
                        .font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                        .foregroundStyle(job.type == .publicBid ? Palette.blue : Palette.tertiary)
                    Spacer()
                    Text(days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s")").font(.ui(11.5)).foregroundStyle(Palette.tertiary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name).font(.ui(14, weight: .bold)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                    Text(store.customerName(for: job)).font(.ui(12)).foregroundStyle(Palette.secondary)
                }
                if !job.services.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(job.services) { Tag(text: $0.label) }
                    }
                }
                if let price {
                    HStack {
                        Text(Fmt.dollars(price, showCents: false)).font(.display(19)).foregroundStyle(Palette.ink).monospacedDigit()
                        Spacer()
                        if job.stage == .estimating { Text("Draft").font(.ui(12)).foregroundStyle(Palette.tertiary) }
                    }
                    .padding(.top, 6)
                    .overlay(alignment: .top) { Hairline() }
                }
                statusPill
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(hovering ? Color(hex: 0xC9C9C3) : Palette.border))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(Stage.allCases) { stage in
                Button("Move to \(stage.label)") { store.setStage(job.id, stage) }.disabled(stage == job.stage)
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch job.stage {
        case .lead:
            if job.type == .publicBid, let due = job.bidDue {
                Pill(text: "Due \(Fmt.day(due))", tone: .info, icon: "flag")
            }
        case .siteVisit:
            if let visit = job.siteVisit {
                Pill(text: "Visit \(visit.formatted(.dateTime.weekday(.abbreviated).hour().minute()))", tone: .info, icon: "calendar")
            }
        case .estimating:
            if let due = job.bidDue { Pill(text: "Bid due \(Fmt.day(due))", tone: .watch, icon: "clock") }
        case .sent:
            let days = job.sentOn.map { Calendar.current.daysBetween($0, .now) } ?? 0
            if days >= 7 { Pill(text: "Follow up · \(days) days", tone: .watch, icon: "clock") }
        case .won:
            if let invoice = store.invoices[job.id] {
                Pill(text: invoice.isPaid ? "Paid" : (invoice.daysLate > 0 ? "Invoice \(invoice.daysLate) days late" : "Invoiced"),
                     tone: invoice.isPaid ? .go : (invoice.daysLate > 0 ? .noGo : .neutral))
            } else if job.completedOn != nil {
                Pill(text: "Done · send invoice", tone: .neutral)
            } else if let first = job.schedule.map(\.day).min() {
                Pill(text: "Scheduled · \(Fmt.day(first))", tone: .go)
            } else {
                Pill(text: "Needs a date", tone: .watch)
            }
        case .lost:
            if !job.lostReason.isEmpty { Text(job.lostReason).font(.ui(11.5)).foregroundStyle(Palette.secondary) }
        }
    }
}
