import SwiftUI

struct ScheduleView: View {
    @Environment(AppStore.self) private var store
    @State private var weekStart = Calendar.current.mondayOfWeek(.now)
    @State private var schedulingJob: Job?
    @State private var errorText: String?

    private var days: [Date] { (0..<6).map { weekStart.adding(days: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "Week of \(weekStart.formatted(.dateTime.month(.wide).day().year()))", title: "Schedule") {
                    HStack(spacing: 0) {
                        Button { weekStart = weekStart.adding(days: -7) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 32) }
                            .accessibilityLabel("Previous week")
                        Divider().frame(height: 32)
                        Button("Today") { weekStart = Calendar.current.mondayOfWeek(.now) }.padding(.horizontal, 12).frame(height: 32)
                        Divider().frame(height: 32)
                        Button { weekStart = weekStart.adding(days: 7) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 32) }
                            .accessibilityLabel("Next week")
                    }
                    .buttonStyle(.plain)
                    .font(.ui(13, weight: .semibold))
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0xDCDCD7)))
                    .helpSpot("schedule.week")
                    Button {
                        exportWeek()
                    } label: {
                        Label("Add to Calendar", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Opens this week's jobs in Apple Calendar")
                    .helpSpot("schedule.calendar")
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WeekGrid(days: days)
                        .tourAnchor(.schedule)
                    HStack(alignment: .top, spacing: 18) {
                        unscheduledCard.frame(maxWidth: .infinity).helpSpot("schedule.unscheduled")
                        ticketsCard.frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .sheet(item: $schedulingJob) { job in ScheduleJobSheet(job: job) }
        .alert("Couldn't open Calendar", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onAppear {
            store.refreshWeather()
            if let week = store.scheduleWeekRequest {
                weekStart = week
                store.scheduleWeekRequest = nil
            }
            store.visibleScheduleWeek = weekStart
        }
        .onChange(of: weekStart) { _, week in store.visibleScheduleWeek = week }
        .onChange(of: store.scheduleWeekRequest) { _, week in
            guard let week else { return }
            weekStart = Calendar.current.mondayOfWeek(week)
            store.scheduleWeekRequest = nil
        }
    }

    private func exportWeek() {
        let end = weekStart.adding(days: 7)
        let items = store.realJobs.flatMap { job in
            job.schedule.filter { $0.day >= weekStart && $0.day < end }.map { (job: job, entry: $0, crew: store.crew($0.crewID)) }
        }
        guard !items.isEmpty else {
            errorText = "There's nothing scheduled this week yet."
            return
        }
        do {
            try CalendarExport.open(items, name: "Stringline week of \(weekStart.formatted(.iso8601.year().month().day()))")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var unscheduledCard: some View {
        let waiting = store.realJobs.filter { $0.stage == .won && $0.completedOn == nil && $0.schedule.isEmpty }
        return VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: "Won, not scheduled", subtitle: waiting.isEmpty ? nil : "Pick a crew and dates")
                .padding(.bottom, 6)
            if waiting.isEmpty {
                Text("Every won job has a date.").font(.ui(13)).foregroundStyle(Palette.secondary).padding(.vertical, 10)
            }
            ForEach(waiting) { job in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.name).font(.ui(13, weight: .semibold))
                        let summary = store.summary(for: job.id)
                        let size = summary.isEmpty ? "" : " · \(Fmt.number(summary.pavedSY + summary.sy(.sealcoat))) SY"
                        Text(job.services.map(\.label).joined(separator: ", ") + size + (job.followsSealcoatRule ? " · needs \(Int(store.settings.weather.sealcoatMinF))°+" : ""))
                            .font(.ui(12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button("Schedule") { schedulingJob = job }.buttonStyle(SmallButtonStyle())
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .card(padding: 20)
    }

    private var ticketsCard: some View {
        let today = Date().startOfDay
        let jobs = store.realJobs.filter { job in job.stage == .won && job.schedule.contains { $0.day >= today } }
        return VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: "811 locate tickets", subtitle: "For jobs on the schedule")
                .padding(.bottom, 6)
            if jobs.isEmpty {
                Text("Nothing upcoming.").font(.ui(13)).foregroundStyle(Palette.secondary).padding(.vertical, 10)
            }
            ForEach(jobs) { job in
                Button {
                    store.openJob(job.id, tab: .schedule)
                } label: {
                    HStack(spacing: 10) {
                        Text(job.name).font(.ui(13, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(job.ticket.number.isEmpty ? "—" : job.ticket.number)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary).frame(width: 100, alignment: .leading)
                        Text(job.ticket.goodUntil.map(Fmt.day) ?? "—").font(.ui(12.5)).monospacedDigit().frame(width: 60, alignment: .leading)
                        ticketPill(job).frame(width: 140, alignment: .trailing)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Hairline() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: 20)
    }

    @ViewBuilder
    private func ticketPill(_ job: Job) -> some View {
        if job.ticket.notNeeded {
            Pill(text: "Not needed", tone: .neutral)
        } else if let until = job.ticket.goodUntil {
            let days = Calendar.current.daysBetween(.now, until)
            if days < 0 { Pill(text: "Expired", tone: .noGo) }
            else if days <= 2 { Pill(text: "Renew", tone: .watch) }
            else { Pill(text: "Clear", tone: .go) }
        } else {
            Pill(text: "Call 811", tone: .info)
        }
    }
}

// MARK: - Week grid

private struct WeekGrid: View {
    @Environment(AppStore.self) private var store
    let days: [Date]

    var body: some View {
        let rules = store.settings.weather
        let today = Date().startOfDay
        VStack(spacing: 0) {
            row(height: nil) {
                Color.clear
            } cell: { day in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(Fmt.weekday(day).uppercased()).font(.system(size: 11.5, weight: day == today ? .bold : .semibold)).tracking(0.6)
                        if day == today { Pill(text: "Today", tone: .accent) }
                    }
                    Text(day.formatted(.dateTime.day())).font(.display(22, weight: day == today ? .bold : .semibold))
                }
                .foregroundStyle(day < today ? Palette.tertiary : Palette.ink)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            row(height: nil, background: Palette.surfaceSunk) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weather").font(.ui(13, weight: .bold))
                    Text("Go / no-go").font(.ui(12)).foregroundStyle(Palette.tertiary)
                }
                .padding(14)
            } cell: { day in
                VStack(alignment: .leading, spacing: 6) {
                    if let forecast = store.weather.forecast(for: day) {
                        let call = WeatherJudge.general(forecast, rules)
                        HStack(spacing: 5) {
                            Image(systemName: forecast.symbol).font(.system(size: 12)).foregroundStyle(call.level == .noGo ? Palette.blue : Palette.secondary)
                            Text("\(Int(forecast.high))° / \(Int(forecast.low))°").font(.ui(13)).monospacedDigit().foregroundStyle(Palette.secondary)
                        }
                        Pill(text: call.short, tone: Tone(call.level))
                    } else {
                        Text(store.settings.company.homeLatitude == nil ? "Set home base" : "—").font(.ui(12)).foregroundStyle(Palette.tertiary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(store.settings.crews.enumerated()), id: \.element.id) { index, crew in
                row(height: 118) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 3).fill(index == 0 ? Palette.ink : Palette.blue).frame(width: 10, height: 10)
                            Text("\(crew.name) · \(crew.kind)").font(.ui(13, weight: .bold)).lineLimit(2)
                        }
                        Text("\(crew.people) people\(crew.equipment.isEmpty ? "" : " · \(crew.equipment)")").font(.ui(12)).foregroundStyle(Palette.tertiary).lineLimit(2)
                    }
                    .padding(14)
                } cell: { day in
                    VStack(spacing: 6) {
                        ForEach(entries(crew: crew.id, day: day), id: \.1.id) { job, entry in
                            ScheduleBlock(job: job, entry: entry, crewIndex: index)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            let unassigned = days.flatMap { day in entries(crew: nil, day: day) }
            if !unassigned.isEmpty {
                row(height: 110) {
                    Text("No crew yet").font(.ui(13, weight: .bold)).padding(14)
                } cell: { day in
                    VStack(spacing: 6) {
                        ForEach(entries(crew: nil, day: day), id: \.1.id) { job, entry in
                            ScheduleBlock(job: job, entry: entry, crewIndex: 1)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
    }

    private func entries(crew: UUID?, day: Date) -> [(Job, ScheduleEntry)] {
        let knownCrews = Set(store.settings.crews.map(\.id))
        return store.jobs.flatMap { job in
            job.schedule.filter { entry in
                guard entry.day.isSameDay(day) else { return false }
                if let crew { return entry.crewID == crew }
                return entry.crewID == nil || !knownCrews.contains(entry.crewID!)
            }.map { (job, $0) }
        }
        .sorted { $0.1.startTime < $1.1.startTime }
    }

    private func row<Label: View, Cell: View>(height: CGFloat?, background: Color = .clear,
                                              @ViewBuilder label: () -> Label, @ViewBuilder cell: @escaping (Date) -> Cell) -> some View {
        let today = Date().startOfDay
        return HStack(spacing: 0) {
            label().frame(width: 170, alignment: .leading)
            ForEach(days, id: \.self) { day in
                cell(day)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(day == today ? Palette.accentWash : .clear)
                    .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 1) }
            }
        }
        .frame(minHeight: height)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

private struct ScheduleBlock: View {
    @Environment(AppStore.self) private var store
    let job: Job
    let entry: ScheduleEntry
    let crewIndex: Int
    @State private var editing = false

    var body: some View {
        let today = Date().startOfDay
        let past = entry.day < today
        let call = store.weather.forecast(for: entry.day).map { WeatherJudge.call(for: job, on: $0, store.settings.weather) }
        let conflict = !past && call?.level == .noGo
        let highlighted = store.assistantHighlights.contains(entry.id)
        Button {
            editing = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if conflict, let call {
                    Label(call.short.replacingOccurrences(of: "No-go · ", with: "").capitalizedFirst, systemImage: "exclamationmark.triangle")
                        .font(.ui(11.5, weight: .bold)).foregroundStyle(Palette.noGoInk)
                } else if past {
                    Label("Done", systemImage: "checkmark").font(.ui(11.5, weight: .bold)).foregroundStyle(Palette.goInk)
                } else {
                    Text(entry.startTime).font(.ui(11.5, weight: .bold)).foregroundStyle(crewIndex == 0 ? Palette.accent : Palette.infoInk)
                }
                Text(job.name).font(.ui(13, weight: .bold)).foregroundStyle(crewIndex == 0 && !past && !conflict ? .white : Palette.ink).lineLimit(2)
                Text(entry.note.isEmpty ? job.services.map(\.label).joined(separator: ", ") : entry.note)
                    .font(.ui(12)).lineLimit(2)
                    .foregroundStyle(crewIndex == 0 && !past && !conflict ? Palette.sidebarText : Palette.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(past: past, conflict: conflict), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(conflict ? Color(hex: 0xB42318) : (crewIndex == 0 || past ? .clear : Color(hex: 0xC6D6F3)),
                              style: StrokeStyle(lineWidth: conflict ? 1.5 : 1, dash: conflict ? [5, 3] : [])))
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.accent, lineWidth: 2.5).padding(-3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            EntryEditor(jobID: job.id, entryID: entry.id, call: call)
        }
        .help(call?.detail ?? job.name)
    }

    private func background(past: Bool, conflict: Bool) -> Color {
        if conflict { return Palette.noGoBg }
        if past { return Color(hex: 0xEDEDEA) }
        return crewIndex == 0 ? Palette.ink : Palette.infoBg
    }
}

private struct EntryEditor: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    let entryID: UUID
    let call: GoCall?

    var body: some View {
        let job = store.jobBinding(jobID)
        if let index = job.wrappedValue.schedule.firstIndex(where: { $0.id == entryID }) {
            let entry = job.schedule[index]
            VStack(alignment: .leading, spacing: 12) {
                Text(job.wrappedValue.name).font(.ui(15, weight: .bold))
                if let call {
                    Label(call.detail, systemImage: call.level == .noGo ? "exclamationmark.triangle" : "cloud.sun")
                        .font(.ui(12.5)).foregroundStyle(call.level == .noGo ? Palette.noGoInk : Palette.secondary)
                }
                DatePicker("Day", selection: Binding(get: { entry.wrappedValue.day }, set: { entry.wrappedValue.day = $0.startOfDay }), displayedComponents: .date)
                Picker("Crew", selection: entry.crewID) {
                    Text("No crew").tag(UUID?.none)
                    ForEach(store.settings.crews) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                TextBox(label: "Start time", text: entry.startTime, placeholder: "7:00 AM")
                TextBox(label: "Note", text: entry.note, placeholder: "Mill day, pave day, plant order…")
                HStack {
                    Button("Open job") { store.openJob(jobID, tab: .schedule) }.buttonStyle(SmallButtonStyle())
                    Spacer()
                    Button("Remove day", role: .destructive) {
                        job.wrappedValue.schedule.removeAll { $0.id == entryID }
                    }
                    .buttonStyle(SmallButtonStyle())
                }
            }
            .padding(16)
            .frame(width: 300)
        } else {
            Text("This day was removed.").padding(16)
        }
    }
}

// MARK: - Schedule a job

struct ScheduleJobSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var crewID: UUID?
    @State private var start = Date().adding(days: 1).startOfDay
    @State private var dayCount = 1
    @State private var startTime = "7:00 AM"
    @State private var skipSundays = true

    var body: some View {
        let rules = store.settings.weather
        VStack(alignment: .leading, spacing: 16) {
            Text("Schedule \(job.name)").font(.display(26))
            Picker("Crew", selection: $crewID) {
                Text("No crew").tag(UUID?.none)
                ForEach(store.settings.crews) { Text("\($0.name) · \($0.kind)").tag(UUID?.some($0.id)) }
            }
            DatePicker("First day", selection: $start, displayedComponents: .date)
            Stepper("\(dayCount) day\(dayCount == 1 ? "" : "s")", value: $dayCount, in: 1...20)
            TextBox(label: "Start time", text: $startTime, placeholder: "7:00 AM")
            Toggle("Skip Sundays", isOn: $skipSundays).toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 6) {
                Text("Weather for these days").font(.ui(12.5, weight: .semibold)).foregroundStyle(Color(hex: 0x3F4249))
                ForEach(plannedDays, id: \.self) { day in
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.ui(12.5)).frame(width: 110, alignment: .leading)
                        if let forecast = store.weather.forecast(for: day) {
                            let call = WeatherJudge.call(for: job, on: forecast, rules)
                            Pill(text: call.short, tone: Tone(call.level))
                        } else {
                            Text("No forecast yet").font(.ui(12)).foregroundStyle(Palette.tertiary)
                        }
                    }
                }
            }
            .padding(12)
            .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Schedule") {
                    var updated = store.job(job.id) ?? job
                    for day in plannedDays {
                        var entry = ScheduleEntry()
                        entry.day = day
                        entry.crewID = crewID
                        entry.startTime = startTime
                        updated.schedule.append(entry)
                    }
                    if updated.stage != .won { updated.stage = .won }
                    store.jobBinding(job.id).wrappedValue = updated
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            crewID = (job.followsSealcoatRule ? store.settings.crews.dropFirst().first : store.settings.crews.first)?.id
        }
    }

    private var plannedDays: [Date] {
        var result: [Date] = []
        var day = start.startOfDay
        while result.count < dayCount {
            if !(skipSundays && Calendar.current.component(.weekday, from: day) == 1) { result.append(day) }
            day = day.adding(days: 1)
        }
        return result
    }
}

// MARK: - Job tab

struct JobScheduleView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    @State private var scheduling: Job?

    var body: some View {
        let job = store.jobBinding(jobID)
        let rules = store.settings.weather
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    if job.wrappedValue.stage != .won {
                        HStack(spacing: 12) {
                            IconTile(systemName: "calendar", tone: .info, size: 34)
                            Text("Jobs go on the schedule once they're won.").font(.ui(13)).foregroundStyle(Palette.secondary)
                            Spacer()
                            Button("Mark as won") { store.setStage(jobID, .won) }.buttonStyle(SecondaryButtonStyle())
                        }
                        .card(padding: 16)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeader(title: "Crew days") {
                            Button {
                                scheduling = job.wrappedValue
                            } label: {
                                Label("Add days", systemImage: "plus")
                            }
                            .buttonStyle(SmallButtonStyle())
                        }
                        .padding(.bottom, 6)
                        if job.wrappedValue.schedule.isEmpty {
                            Text("No days booked yet.").font(.ui(13)).foregroundStyle(Palette.secondary).padding(.vertical, 10)
                        }
                        ForEach(job.wrappedValue.schedule.sorted { $0.day < $1.day }) { entry in
                            let call = store.weather.forecast(for: entry.day).map { WeatherJudge.call(for: job.wrappedValue, on: $0, rules) }
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.ui(13, weight: .semibold))
                                    Text("\(store.crew(entry.crewID)?.name ?? "No crew") · \(entry.startTime)\(entry.note.isEmpty ? "" : " · \(entry.note)")")
                                        .font(.ui(12)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                if let call { Pill(text: call.short, tone: Tone(call.level)) }
                                Button {
                                    job.wrappedValue.schedule.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(Palette.tertiary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove this day")
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .top) { Hairline() }
                        }
                    }
                    .card(padding: 20)
                    .helpSpot("jobSchedule.days")
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "Plant order", subtitle: "Shows on the schedule and Today")
                        TextBox(label: "Order", text: job.plantNote, placeholder: "310 tn surface, confirmed with the plant")
                    }
                    .card(padding: 20)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "811 locate ticket")
                    Toggle("Not needed for this job (surface work only)", isOn: job.ticket.notNeeded).toggleStyle(.checkbox)
                    if !job.wrappedValue.ticket.notNeeded {
                        TextBox(label: "Ticket number", text: job.ticket.number, placeholder: "From your 811 center")
                        OptionalDateRow(label: "Good until", date: job.ticket.goodUntil)
                        Text("Ticket rules vary by state. Stringline warns you two days before it runs out.")
                            .font(.ui(12)).foregroundStyle(Palette.tertiary)
                    }
                    Divider()
                    OptionalDateRow(label: "Finished", date: job.completedOn)
                }
                .card(padding: 20)
                .frame(width: 360)
                .helpSpot("jobSchedule.ticket")
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        .sheet(item: $scheduling) { job in ScheduleJobSheet(job: job) }
    }
}
