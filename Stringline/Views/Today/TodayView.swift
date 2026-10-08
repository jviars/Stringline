import SwiftUI

struct TodayView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: Fmt.longDay(.now), title: "Today") {
                    Button("New lead") { store.showNewLead = true }.buttonStyle(SecondaryButtonStyle())
                    Button {
                        store.selection = .measure
                    } label: {
                        Label("New estimate", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showChecklist { GettingStartedCard() }
                    WeatherCard().tourAnchor(.today).helpSpot("today.weather")
                    HStack(alignment: .top, spacing: 18) {
                        OnScheduleCard().frame(maxWidth: .infinity)
                        AttentionCard().frame(width: 400).helpSpot("today.attention")
                    }
                    HStack(alignment: .top, spacing: 18) {
                        SeasonCard().frame(maxWidth: .infinity)
                        SealcoatDueCard().frame(width: 400)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: 1320, alignment: .leading)
            }
        }
    }

    private var showChecklist: Bool {
        !store.settings.checklistDismissed && ChecklistItem.all(store).contains { !$0.done }
    }
}

// MARK: - Getting started

struct ChecklistItem: Identifiable {
    let id: Int
    let title: String
    let detail: String
    let done: Bool
    let action: SidebarItem

    @MainActor
    static func all(_ store: AppStore) -> [ChecklistItem] {
        let real = store.realJobs
        return [
            ChecklistItem(id: 1, title: "Set up your company and rates", detail: "Done during setup",
                          done: !store.settings.company.name.isEmpty, action: .settings),
            ChecklistItem(id: 2, title: "Measure your first lot", detail: "Search an address and outline the pavement. About two minutes.",
                          done: real.contains { !(store.takeoffs[$0.id]?.shapes.isEmpty ?? true) }, action: .measure),
            ChecklistItem(id: 3, title: "Turn it into an estimate", detail: "Your measurements become priced line items, using your rates.",
                          done: real.contains { !(store.estimates[$0.id]?.selected?.items.isEmpty ?? true) }, action: .jobs),
            ChecklistItem(id: 4, title: "Send your first proposal", detail: "Email a PDF from Mail with your logo on top.",
                          done: real.contains { $0.sentOn != nil }, action: .pipeline),
            ChecklistItem(id: 5, title: "Put a job on the schedule", detail: "See go / no-go weather for every crew day.",
                          done: real.contains { !$0.schedule.isEmpty }, action: .schedule),
        ]
    }
}

private struct GettingStartedCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let items = ChecklistItem.all(store)
        let doneCount = items.filter(\.done).count
        let current = items.first { !$0.done }
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("GETTING STARTED").font(.eyebrow).tracking(1).foregroundStyle(Palette.accent)
                Text("Welcome to Stringline").font(.display(32)).foregroundStyle(.white)
                Text("Five quick things and you're rolling. Most people finish them on their first afternoon.")
                    .font(.ui(14)).foregroundStyle(Palette.sidebarText).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                StakeProgress(fraction: Double(doneCount) / Double(items.count)).padding(.top, 4)
                (Text("\(doneCount) of \(items.count)").bold().foregroundColor(.white) + Text(" done"))
                    .font(.ui(12.5)).foregroundStyle(Palette.onDarkMuted)
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    Button {
                        store.startTour()
                    } label: {
                        Label("Take the 2-minute tour", systemImage: "safari")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Hide") {
                        store.settings.checklistDismissed = true
                        store.markDirty(.settings)
                    }
                    .buttonStyle(.plain)
                    .font(.ui(13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xE6E7E9))
                }
            }
            .padding(26)
            .frame(width: 360, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.asphalt)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    let isCurrent = item.id == current?.id
                    HStack(spacing: 14) {
                        ZStack {
                            if item.done {
                                Circle().fill(Palette.goBg)
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Palette.goInk)
                            } else if isCurrent {
                                Circle().fill(Palette.ink)
                                Text("\(item.id)").font(.ui(13, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Circle().strokeBorder(Color(hex: 0xC9C9C3), lineWidth: 1.5)
                                Text("\(item.id)").font(.ui(13, weight: .bold)).foregroundStyle(Palette.secondary)
                            }
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.ui(isCurrent ? 14 : 13, weight: isCurrent ? .bold : .semibold))
                                .foregroundStyle(item.done ? Palette.secondary : Palette.ink)
                                .strikethrough(item.done, color: Color(hex: 0x9A9DA4))
                            Text(item.detail).font(.ui(12.5)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        if isCurrent {
                            Button {
                                store.selection = item.action
                            } label: {
                                Label("Start", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                            }
                            .buttonStyle(DarkButtonStyle())
                        }
                    }
                    .padding(.vertical, 13)
                    .padding(.horizontal, isCurrent ? 12 : 0)
                    .background(isCurrent ? Palette.accentWash : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Color(hex: 0xF2DFA0) : .clear, lineWidth: 1.5))
                    .padding(.horizontal, isCurrent ? -12 : 0)
                    if item.id != items.count && !isCurrent && items[item.id].id != current?.id { Hairline() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
    }
}

// MARK: - Weather

struct WeatherCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rules = store.settings.weather
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Paving weather") {
                Text(sourceLine).font(.ui(12)).foregroundStyle(Palette.tertiary)
            }
            if store.settings.company.homeLatitude == nil {
                HStack(spacing: 14) {
                    IconTile(systemName: "mappin.and.ellipse", tone: .info, size: 38)
                    Text("Set your home base so Stringline can check the weather against your rules.")
                        .font(.ui(13)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Set home base") { store.selection = .settings }.buttonStyle(SecondaryButtonStyle())
                }
            } else if days.isEmpty {
                HStack(spacing: 10) {
                    if store.weather.loading { ProgressView().controlSize(.small) }
                    Text(store.weather.error ?? "Loading the forecast…").font(.ui(13)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Try again") { store.refreshWeather(force: true) }.buttonStyle(SmallButtonStyle())
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        let call = WeatherJudge.general(day, rules)
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: day.symbol)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(call.level == .noGo ? Palette.blue : Palette.amberInk)
                                .frame(width: 42, height: 42)
                                .background(call.level == .noGo ? Palette.infoBg : Palette.watchBg, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(index == 0 ? "Today" : day.day.formatted(.dateTime.weekday(.wide))).font(.ui(14, weight: .bold))
                                    Text("\(Int(day.high))° / \(Int(day.low))°").font(.ui(13)).foregroundStyle(Palette.secondary).monospacedDigit()
                                }
                                Pill(text: call.short, tone: Tone(call.level),
                                     icon: call.level == .noGo ? "xmark" : (call.level == .watch ? "exclamationmark" : "checkmark"))
                                Text(call.detail).font(.ui(12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.hairline))
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Your rules: asphalt \(Int(rules.pavingMinF))°F and rising · sealcoat \(Int(rules.sealcoatMinF))°F+ for \(rules.sealcoatHours) h · no-go at \(rules.rainChanceMax)% rain")
                    .font(.ui(12)).foregroundStyle(Palette.tertiary)
                Button("Edit rules") { store.selection = .settings }.buttonStyle(LinkButtonStyle())
            }
        }
        .card(padding: 20)
    }

    private var days: [DayForecast] {
        let today = Date().startOfDay
        return Array(store.weather.days.filter { $0.day >= today }.prefix(3))
    }

    private var sourceLine: String {
        let town = store.settings.company.homeBase.isEmpty ? "" : "\(store.settings.company.homeBase) · "
        guard let updated = store.weather.updated else { return "\(town)Open-Meteo" }
        return "\(town)Open-Meteo · updated \(updated.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Schedule and attention

private struct OnScheduleCard: View {
    @Environment(AppStore.self) private var store

    private var entries: [(Job, ScheduleEntry)] {
        let today = Date().startOfDay
        return store.realJobs.flatMap { job in job.schedule.filter { $0.day.isSameDay(today) }.map { (job, $0) } }
            .sorted { $0.1.startTime < $1.1.startTime }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: "On the schedule") {
                Button {
                    store.selection = .schedule
                } label: {
                    Label("Open schedule", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(LinkButtonStyle())
            }
            if entries.isEmpty {
                EmptyState(icon: "calendar", title: "Nothing on the schedule today",
                           message: "Won jobs show up here with their crew, plant order and 811 status.")
            }
            ForEach(entries, id: \.1.id) { job, entry in
                Button {
                    store.openJob(job.id, tab: .schedule)
                } label: {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.startTime.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))
                                .font(.display(22, weight: .semibold)).monospacedDigit()
                            Text(entry.startTime.hasSuffix("PM") ? "PM" : "AM").font(.ui(11.5)).foregroundStyle(Palette.tertiary)
                        }
                        .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            if let crew = store.crew(entry.crewID) {
                                Text("\(crew.name) · \(crew.kind)")
                                    .font(.ui(11, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 7).frame(height: 20)
                                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 5))
                            }
                            Text(job.name).font(.ui(15.5, weight: .bold)).foregroundStyle(Palette.ink)
                            Text([job.services.map(\.label).joined(separator: ", "), job.address].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.ui(13)).foregroundStyle(Palette.secondary)
                            HStack(spacing: 6) {
                                ticketChip(job)
                                if !job.plantNote.isEmpty { Tag(text: job.plantNote) }
                                if !entry.note.isEmpty { Tag(text: entry.note) }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .overlay(alignment: .top) { Hairline() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: 20)
    }

    @ViewBuilder
    private func ticketChip(_ job: Job) -> some View {
        if job.ticket.notNeeded {
            Tag(text: "811 not needed")
        } else if let until = job.ticket.goodUntil, until >= Date().startOfDay {
            Pill(text: "811 clear to \(Fmt.day(until))", tone: .go, icon: "checkmark")
        } else {
            Pill(text: "811 needed", tone: .watch, icon: "exclamationmark")
        }
    }
}

private struct AttentionCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let items = Attention.items(store)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Needs attention").font(.ui(15, weight: .bold))
                if !items.isEmpty {
                    Text("\(items.count)").font(.ui(11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20).background(Palette.ink, in: Capsule())
                }
            }
            if items.isEmpty {
                EmptyState(icon: "checkmark", title: "All clear",
                           message: "Rain on job days, 811 tickets about to expire, quiet bids and late invoices will show up here.", tint: .go)
            }
            ForEach(items) { item in
                HStack(spacing: 12) {
                    IconTile(systemName: icon(item.kind), tone: tone(item.kind), size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.ui(13, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(item.detail).font(.ui(12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 6)
                    Button(item.action) { act(item) }.buttonStyle(SmallButtonStyle())
                }
                .padding(.vertical, 11)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .card(padding: 20)
    }

    private func icon(_ kind: AttentionItem.Kind) -> String {
        switch kind {
        case .rain: "cloud.rain"
        case .ticket: "flag"
        case .followUp: "clock"
        case .invoice: "doc.text"
        }
    }

    private func tone(_ kind: AttentionItem.Kind) -> Tone {
        switch kind {
        case .rain, .invoice: .noGo
        case .ticket: .watch
        case .followUp: .info
        }
    }

    private func act(_ item: AttentionItem) {
        switch item.kind {
        case .rain: store.selection = .schedule
        case .ticket: store.openJob(item.jobID, tab: .schedule)
        case .followUp:
            guard let job = store.job(item.jobID) else { return }
            let customer = store.customer(job.customerID)
            Mailer.compose(to: customer?.email, subject: "Following up on your paving proposal",
                           body: "Hi \(customer?.contact.isEmpty == false ? customer!.contact : "there"),\n\nI wanted to check in on the proposal we sent for \(job.name). Happy to answer any questions or walk the site again.\n\nThanks,\n\(store.settings.company.name)")
        case .invoice: store.openJob(item.jobID, tab: .invoice)
        }
    }
}

// MARK: - Season and repeat business

private struct SeasonCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let year = Calendar.current.component(.year, from: .now)
        let thisYear = store.realJobs.filter { Calendar.current.component(.year, from: $0.stageChanged) == year }
        let won = thisYear.filter { $0.stage == .won }
        let lost = thisYear.filter { $0.stage == .lost }
        let sent = store.realJobs.filter { $0.stage == .sent }
        let wonTotal = won.compactMap { store.priceCents(for: $0.id) }.reduce(0, +)
        let sentTotal = sent.compactMap { store.priceCents(for: $0.id) }.reduce(0, +)
        let decided = won.count + lost.count
        let unpaid = store.realJobs.compactMap { store.invoices[$0.id] }.filter { !$0.isPaid }
        let buckets = [
            unpaid.filter { $0.daysOutstanding <= 30 }.reduce(0) { $0 + $1.balanceCents },
            unpaid.filter { (31...60).contains($0.daysOutstanding) }.reduce(0) { $0 + $1.balanceCents },
            unpaid.filter { $0.daysOutstanding > 60 }.reduce(0) { $0 + $1.balanceCents },
        ]
        let unpaidTotal = buckets.reduce(0, +)

        VStack(alignment: .leading, spacing: 16) {
            CardHeader(title: "Season so far") {
                Text(String(year)).font(.ui(12)).foregroundStyle(Palette.tertiary)
            }
            HStack(alignment: .top, spacing: 28) {
                StatBlock(label: "Won", value: Fmt.dollars(wonTotal, showCents: false), note: "\(won.count) job\(won.count == 1 ? "" : "s")")
                StatBlock(label: "Waiting on an answer", value: Fmt.dollars(sentTotal, showCents: false), note: "\(sent.count) bid\(sent.count == 1 ? "" : "s") sent")
                StatBlock(label: "Win rate", value: decided == 0 ? "—" : "\(Int((Double(won.count) / Double(decided) * 100).rounded()))%", note: "of decided bids")
                StatBlock(label: "Unpaid", value: Fmt.dollars(unpaidTotal, showCents: false), note: "\(unpaid.count) invoice\(unpaid.count == 1 ? "" : "s")")
            }
            if unpaidTotal > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            ForEach(0..<3) { i in
                                Rectangle()
                                    .fill([Color(hex: 0xD5D6D1), Palette.accent, Color(hex: 0xB42318)][i])
                                    .frame(width: max(0, (proxy.size.width - 6) * CGFloat(buckets[i]) / CGFloat(max(unpaidTotal, 1))))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 10)
                    .accessibilityLabel("Unpaid by age")
                    HStack(spacing: 18) {
                        legend(Color(hex: 0xD5D6D1), "Under 30 days", buckets[0])
                        legend(Palette.accent, "31–60 days", buckets[1])
                        legend(Color(hex: 0xB42318), "Over 60 days", buckets[2])
                    }
                }
            }
        }
        .card(padding: 20)
    }

    private func legend(_ color: Color, _ label: String, _ cents: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).foregroundStyle(Palette.secondary)
            Text(Fmt.dollars(cents, showCents: false)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.ui(12))
    }
}

private struct SealcoatDueCard: View {
    @Environment(AppStore.self) private var store

    private var due: [Job] {
        let cutoff = Calendar.current.date(byAdding: .year, value: -store.settings.sealcoatCycleYears, to: .now) ?? .now
        return store.realJobs.filter { job in
            job.services.contains(.sealcoat) && (job.completedOn.map { $0 < cutoff } ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: "Due for sealcoat", subtitle: "Past customers sealed \(store.settings.sealcoatCycleYears)+ years ago")
            if due.isEmpty {
                EmptyState(icon: "arrow.triangle.2.circlepath", title: "No one's due yet",
                           message: "Finished sealcoat jobs come back here when it's time to reseal. Change the cycle in Settings.")
            }
            ForEach(due) { job in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.customer(job.customerID)?.name ?? job.name).font(.ui(13, weight: .semibold))
                        Text("Sealed \(job.completedOn.map(Fmt.monthYear) ?? "") · \(Fmt.number(store.summary(for: job.id).areaSqFt[.sealcoat] ?? 0)) sq ft")
                            .font(.ui(12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button {
                        let customer = store.customer(job.customerID)
                        Mailer.compose(to: customer?.email, subject: "Time to reseal your lot?",
                                       body: "Hi \(customer?.contact ?? ""),\n\nIt's been about \(store.settings.sealcoatCycleYears) years since we sealed \(job.name). A fresh coat now keeps water out and the pavement lasting longer. Want me to come take a look and send a price?\n\nThanks,\n\(store.settings.company.name)")
                    } label: {
                        Label("Remind", systemImage: "envelope")
                    }
                    .buttonStyle(SmallButtonStyle())
                }
                .padding(.vertical, 11)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .card(padding: 20)
    }
}
