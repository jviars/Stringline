import SwiftUI

struct Lesson: Identifiable, Hashable {
    let id: String
    let group: String
    let title: String
    let minutes: Int
    let icon: String
    let summary: String
    let steps: [String]
    let tryLabel: String

    static let all: [Lesson] = [
        Lesson(id: "tour", group: "Getting started", title: "Tour of Stringline", minutes: 2, icon: "safari",
               summary: "Six stops: Today, Pipeline, Measure, Estimate, Schedule and Settings.",
               steps: ["The tour walks you through each part of the app on a sample job.", "Use Next and Back to move between stops, or press Esc to leave anytime."],
               tryLabel: "Start the tour"),
        Lesson(id: "data", group: "Getting started", title: "Your data folder and backups", minutes: 2, icon: "folder.badge.gearshape",
               summary: "Where your jobs live, how the nightly backup works, and how to see them on your iPhone.",
               steps: ["Everything lives in the PavingData folder. Click the folder card at the bottom of the sidebar to open it in Finder.",
                       "Each job is its own folder: job.json, takeoff.json, estimate.json, plus photos and docs.",
                       "Every night Stringline zips your job files into the backups folder and keeps the last 30.",
                       "If PavingData is in iCloud Drive, open the Files app on your iPhone to find proposals in each job's docs folder."],
               tryLabel: "Open Data & backups"),
        Lesson(id: "measure", group: "Winning work", title: "Measure a lot from satellite", minutes: 4, icon: "pentagon",
               summary: "Find the address, outline the pavement, and switch imagery when the photo is old.",
               steps: ["Click Measure in the sidebar and search the address.", "Zoom in until you can see the stall lines.",
                       "Press A, click each corner of the pavement, then press Return.", "If the photo looks old, switch Apple to Esri at the top of the map.",
                       "Rename the area on the right, like Main lot, and set the depth."],
               tryLabel: "Try it on Practice Plaza"),
        Lesson(id: "cutout", group: "Winning work", title: "Cut out islands and buildings", minutes: 2, icon: "scissors",
               summary: "Remove landscaping and buildings so you only bid what gets paved.",
               steps: ["Press X for the Cut out tool.", "Click around the island or building inside an area.", "Press Return. The area's square footage drops by that amount.",
                       "Changed your mind? Select the area and click Remove under its cut-outs."],
               tryLabel: "Try it on Practice Plaza"),
        Lesson(id: "estimate", group: "Winning work", title: "Build an estimate", minutes: 4, icon: "function",
               summary: "Turn measurements into priced line items and set your margin with one slider.",
               steps: ["On the Measure tab, click Send to estimate.", "Each line uses your rates. Change any quantity or unit cost right in the table.",
                       "Drag Profit in the bid summary and watch the price per SY.", "Add an Option B (like sealcoat only) so the customer has a choice."],
               tryLabel: "Open Practice Plaza's estimate"),
        Lesson(id: "proposal", group: "Winning work", title: "Send a proposal from Mail", minutes: 2, icon: "envelope",
               summary: "Preview the PDF, offer options, and email it in one click.",
               steps: ["Click Preview to see the two-page proposal with your logo and a satellite picture of the lot.",
                       "Click Email to customer. Mail opens with the PDF attached and a short note.", "The job moves to Sent, and Today reminds you to follow up after a week."],
               tryLabel: "Open Practice Plaza's estimate"),
        Lesson(id: "schedule", group: "Running jobs", title: "Schedule crews with the weather", minutes: 3, icon: "calendar.badge.checkmark",
               summary: "Book crew days and let go / no-go warn you about rain and cold.",
               steps: ["Won jobs show up under Won, not scheduled. Click Schedule and pick a crew and days.",
                       "Each day is checked against your weather rules. A red card means move it.", "Click a card to change the day or crew. Add to Calendar sends the week to Apple Calendar."],
               tryLabel: "Open the schedule"),
        Lesson(id: "logs", group: "Running jobs", title: "Daily logs and how close you bid", minutes: 3, icon: "list.clipboard",
               summary: "Log tons and hours each day, then compare with what you bid.",
               steps: ["Open a job and choose Daily logs.", "Click Add today's log and fill in tons laid and crew hours.", "The bars at the top compare your actuals with the estimate."],
               tryLabel: "Open Jobs"),
        Lesson(id: "invoices", group: "Running jobs", title: "Invoices and getting paid", minutes: 3, icon: "doc.text",
               summary: "Turn a finished job into an invoice and keep an eye on what's late.",
               steps: ["Open a won job and choose Invoice, then Create invoice.", "Set the terms, record any deposit, and click Email invoice.",
                       "Mark it paid when the check comes in. Late invoices show up on Today."],
               tryLabel: "Open Invoices"),
    ]
}

struct LearnView: View {
    @Environment(AppStore.self) private var store
    @Environment(Assistant.self) private var assistant
    @State private var openLesson: Lesson?
    @State private var confirmReset = false

    private var done: Set<String> {
        var set = Set(store.settings.lessonsDone)
        if store.settings.tourCompleted { set.insert("tour") }
        return set
    }

    var body: some View {
        let lessons = Lesson.all
        let next = lessons.first { !done.contains($0.id) }
        let minutesLeft = lessons.filter { !done.contains($0.id) }.reduce(0) { $0 + $1.minutes }
        VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "Help", title: "Learn Stringline") {
                    Button {
                        assistant.openForHelp()
                    } label: {
                        Label("Ask how to do anything", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Opens the assistant (⌘J). It answers from Stringline's built-in help, step by step.")
                    Button {
                        store.startTour()
                    } label: {
                        Label("Restart the tour", systemImage: "safari")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Open practice job") { openPractice(.measure) }.buttonStyle(PrimaryButtonStyle())
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 32) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("YOUR PROGRESS").font(.eyebrow).tracking(0.9).foregroundStyle(Palette.onDarkMuted)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(done.count) of \(lessons.count)").font(.display(38)).foregroundStyle(.white)
                                Text("lessons done").font(.ui(13)).foregroundStyle(Palette.sidebarText)
                            }
                            Text(minutesLeft == 0 ? "All done. Nice work." : "About \(minutesLeft) minutes left").font(.ui(12.5)).foregroundStyle(Palette.onDarkMuted)
                        }
                        StakeProgress(fraction: Double(done.count) / Double(lessons.count))
                        if let next {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("UP NEXT").font(.eyebrow).tracking(0.8).foregroundStyle(Palette.accent)
                                    Text(next.title).font(.ui(13, weight: .semibold)).foregroundStyle(.white)
                                    Text("\(next.minutes) min").font(.ui(12)).foregroundStyle(Palette.onDarkMuted)
                                }
                                Button("Start") { openLesson = next }.buttonStyle(PrimaryButtonStyle())
                            }
                            .padding(12)
                            .background(Palette.asphaltField, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(24)
                    .background(Palette.asphalt, in: RoundedRectangle(cornerRadius: 18))

                    HStack(alignment: .top, spacing: 18) {
                        practiceCard.frame(maxWidth: .infinity)
                        shortcutsCard.frame(width: 400)
                    }

                    ForEach(["Getting started", "Winning work", "Running jobs"], id: \.self) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.uppercased()).font(.system(size: 13, weight: .bold)).tracking(0.9).foregroundStyle(Palette.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                                ForEach(lessons.filter { $0.group == group }) { lesson in
                                    LessonCard(lesson: lesson, done: done.contains(lesson.id), isNext: lesson.id == next?.id) { openLesson = lesson }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 44)
                .frame(maxWidth: 1320, alignment: .leading)
            }
        }
        .sheet(item: $openLesson) { lesson in
            LessonSheet(lesson: lesson, isDone: done.contains(lesson.id)) { action in
                openLesson = nil
                perform(lesson, action: action)
            }
        }
        .confirmationDialog("Reset Practice Plaza?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.resetPracticeJob() }
        } message: {
            Text("Its measurements, estimate and logs go back to empty. Your real jobs aren't touched.")
        }
    }

    private var practiceCard: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x55663E))
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x474A4D)).frame(width: 150, height: 64).offset(y: 8)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xD4D2CB)).frame(width: 96, height: 22).offset(y: -38)
                Rectangle().fill(Palette.accent.opacity(0.22)).frame(width: 76, height: 34).offset(x: -37, y: -7)
                    .overlay(Rectangle().strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(width: 76, height: 34).offset(x: -37, y: -7))
            }
            .frame(width: 200, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Practice Plaza").font(.display(24))
                    Tag(text: "Sample job")
                }
                Text("A made-up job with fake numbers. Measure it, bid it, schedule it, even email yourself the proposal. Reset puts it back the way it was.")
                    .font(.ui(13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    Button("Open practice job") { openPractice(.measure) }.buttonStyle(PrimaryButtonStyle())
                    Button {
                        confirmReset = true
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(store.practiceJob == nil)
                }
            }
        }
        .card(padding: 18, radius: 16)
    }

    private var shortcutsCard: some View {
        let keys: [(String, String)] = [("⌘K", "Search anything"), ("⌘N", "New lead"), ("A", "Area tool"), ("L", "Line tool"),
                                        ("C", "Count markers"), ("X", "Cut out"), ("⏎", "Close the shape"), ("⌘Z", "Undo")]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard shortcuts").font(.ui(15, weight: .bold))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 0) {
                ForEach(keys, id: \.0) { key, label in
                    HStack(spacing: 10) {
                        KeyCap(key: key).frame(minWidth: 34)
                        Text(label).font(.ui(13)).foregroundStyle(Color(hex: 0x3F4249))
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
        }
        .card(padding: 18, radius: 16)
    }

    private func openPractice(_ tab: JobTab) {
        let job = store.ensurePracticeJob()
        store.openJob(job.id, tab: tab)
    }

    private func perform(_ lesson: Lesson, action: LessonSheet.Action) {
        if action == .markDone || action == .tryIt, !store.settings.lessonsDone.contains(lesson.id) {
            store.settings.lessonsDone.append(lesson.id)
            store.markDirty(.settings)
        }
        guard action == .tryIt else { return }
        switch lesson.id {
        case "tour": store.startTour()
        case "data": store.selection = .settings
        case "measure", "cutout": openPractice(.measure)
        case "estimate", "proposal": openPractice(.estimate)
        case "schedule": store.selection = .schedule
        case "logs": store.selection = .jobs
        case "invoices": store.selection = .invoices
        default: break
        }
    }
}

private struct LessonCard: View {
    let lesson: Lesson
    let done: Bool
    let isNext: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Palette.asphalt
                    Image(systemName: lesson.icon).font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent)
                }
                .frame(height: 112)
                .overlay(alignment: .topLeading) {
                    if done {
                        Pill(text: "Done", tone: .go, icon: "checkmark").padding(10)
                    } else if isNext {
                        Pill(text: "Up next", tone: .accent).padding(10)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(lesson.minutes) min").font(.ui(11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(.white.opacity(0.14), in: Capsule()).padding(10)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lesson.title).font(.ui(15, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(lesson.summary).font(.ui(12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Label(done ? "Go over it again" : "Start lesson", systemImage: "play.fill")
                        .font(.ui(12.5, weight: .bold)).foregroundStyle(Palette.amberInk)
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isNext ? Palette.ink : Palette.border, lineWidth: isNext ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LessonSheet: View {
    enum Action { case close, markDone, tryIt }
    let lesson: Lesson
    let isDone: Bool
    let finish: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                IconTile(systemName: lesson.icon, tone: .dark, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(lesson.group.uppercased()) · \(lesson.minutes) MIN").font(.eyebrow).tracking(0.8).foregroundStyle(Palette.tertiary)
                    Text(lesson.title).font(.display(26))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(lesson.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.ui(13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Palette.ink, in: Circle())
                        Text(step).font(.ui(14)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Button("Close") { finish(.close) }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if !isDone {
                    Button("Mark as done") { finish(.markDone) }.buttonStyle(SecondaryButtonStyle())
                }
                Button {
                    finish(.tryIt)
                } label: {
                    Label(lesson.tryLabel, systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 560)
    }
}
