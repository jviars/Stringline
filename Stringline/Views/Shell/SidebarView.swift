import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let attention = Attention.items(store).count
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LogoMark(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Stringline").font(.display(20)).foregroundStyle(.white)
                    Text(store.settings.company.name.isEmpty ? "Your company" : store.settings.company.name)
                        .font(.ui(11.5)).foregroundStyle(Palette.sidebarMuted).lineLimit(1)
                }
            }
            .padding(.horizontal, 6)

            Button { store.showSearch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    Text("Search jobs, customers…").font(.ui(13))
                    Spacer()
                    Text("⌘K").font(.ui(11)).padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.asphaltRule))
                }
                .foregroundStyle(Palette.sidebarMuted)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Palette.asphaltField, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.asphaltLine))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .helpSpot("sidebar.search")

            VStack(spacing: 2) {
                NavRow(item: .today, title: "Today", icon: "sun.max", badge: attention > 0 ? "\(attention)" : nil, badgeIsAccent: true)
                    .helpSpot("sidebar.today")
                NavRow(item: .pipeline, title: "Pipeline", icon: "rectangle.split.3x1", count: store.realJobs.filter { Stage.board.dropLast().contains($0.stage) }.count)
                    .helpSpot("sidebar.pipeline")
                NavRow(item: .measure, title: "Measure", icon: "ruler")
                    .helpSpot("sidebar.measure")
                NavRow(item: .jobs, title: "Jobs", icon: "list.clipboard")
                    .helpSpot("sidebar.jobs")
                NavRow(item: .schedule, title: "Schedule", icon: "calendar")
                    .helpSpot("sidebar.schedule")
                NavRow(item: .customers, title: "Customers", icon: "person.2")
                    .helpSpot("sidebar.customers")
                NavRow(item: .invoices, title: "Invoices", icon: "doc.text", note: lateInvoiceNote)
                    .helpSpot("sidebar.invoices")
            }

            VStack(alignment: .leading, spacing: 2) {
                SidebarSectionLabel("Shop")
                NavRow(item: .equipment, title: "Equipment", icon: "truck.box")
                NavRow(item: .crew, title: "Crews", icon: "person.3")
                    .helpSpot("sidebar.crews")
                NavRow(item: .documents, title: "Documents", icon: "folder")
            }

            if !recentJobs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarSectionLabel("Recent jobs").helpSpot("sidebar.recent")
                    ForEach(recentJobs) { job in
                        RecentJobRow(job: job)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 2) {
                AssistantNavRow().helpSpot("sidebar.assistant")
                NavRow(item: .learn, title: "Learn Stringline", icon: "book", dot: !store.settings.tourCompleted)
                    .helpSpot("sidebar.learn")
                NavRow(item: .settings, title: "Settings & rates", icon: "slider.horizontal.3")
                    .helpSpot("sidebar.settings")
            }
            DataFolderStatus().helpSpot("sidebar.data")
        }
        .padding(.top, 44)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.asphalt)
    }

    private var recentJobs: [Job] {
        let recent = store.recentJobIDs.compactMap { store.job($0) }
        let fill = store.jobs.filter { job in !recent.contains { $0.id == job.id } }.sorted { $0.updated > $1.updated }
        return Array((recent + fill).prefix(3))
    }

    private var lateInvoiceNote: String? {
        let late = store.realJobs.filter { (store.invoices[$0.id]?.daysLate ?? 0) > 0 }.count
        return late > 0 ? "\(late) late" : nil
    }
}

struct SidebarSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Palette.sidebarMuted)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

struct NavRow: View {
    @Environment(AppStore.self) private var store
    let item: SidebarItem
    let title: String
    let icon: String
    var badge: String?
    var badgeIsAccent = false
    var count: Int?
    var note: String?
    var dot = false
    @State private var hovering = false

    private var isActive: Bool {
        if store.selection == item { return true }
        if item == .measure, case .job = store.selection, store.jobTab == .measure { return false }
        return false
    }

    var body: some View {
        Button {
            store.selection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isActive ? Palette.accent : Palette.sidebarMuted)
                Text(title)
                    .font(.ui(13, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? .white : Palette.sidebarText)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.ui(11, weight: .bold))
                        .foregroundStyle(badgeIsAccent && isActive ? Palette.ink : Color(hex: 0xE6E7E9))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(badgeIsAccent && isActive ? Palette.accent : Palette.asphaltRule, in: Capsule())
                }
                if let count, count > 0 {
                    Text("\(count)").font(.ui(12)).foregroundStyle(Palette.sidebarMuted).monospacedDigit()
                }
                if let note {
                    Text(note).font(.ui(11, weight: .semibold)).foregroundStyle(Palette.salmon)
                }
                if dot {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7).accessibilityLabel("New")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isActive ? Palette.asphaltActive : (hovering ? Palette.asphaltField : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Opens and closes the assistant panel (⌘J).
struct AssistantNavRow: View {
    @Environment(Assistant.self) private var assistant
    @State private var hovering = false

    var body: some View {
        Button {
            assistant.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(assistant.isOpen ? Palette.accent : Palette.sidebarMuted)
                Text("Assistant")
                    .font(.ui(13, weight: assistant.isOpen ? .semibold : .medium))
                    .foregroundStyle(assistant.isOpen ? .white : Palette.sidebarText)
                Spacer(minLength: 4)
                if assistant.isRunning {
                    ProgressView().controlSize(.mini).tint(Palette.accent)
                } else if assistant.account.isReady {
                    ChatGPTLogo(size: 13, white: true).opacity(0.85)
                }
                Text("⌘J").font(.ui(11)).foregroundStyle(Palette.sidebarMuted)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.asphaltRule))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(assistant.isOpen ? Palette.asphaltActive : (hovering ? Palette.asphaltField : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(assistant.account.isReady ? "Ask ChatGPT about anything here, or have it make changes" : "Connect ChatGPT to use the assistant")
        .accessibilityLabel(assistant.isOpen ? "Hide assistant" : "Show assistant")
    }
}

struct RecentJobRow: View {
    @Environment(AppStore.self) private var store
    let job: Job
    @State private var hovering = false

    private var isActive: Bool {
        if case .job(let id) = store.selection { return id == job.id }
        return false
    }

    var body: some View {
        Button {
            store.openJob(job.id)
        } label: {
            HStack(spacing: 10) {
                if job.isSample {
                    Circle().strokeBorder(Palette.sidebarMuted, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 8, height: 8)
                } else {
                    Circle().fill(job.stage.dotColor).frame(width: 8, height: 8)
                }
                Text(job.name)
                    .font(.ui(13, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? .white : Palette.sidebarText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if job.isSample {
                    Text("Sample").font(.ui(10.5, weight: .semibold)).foregroundStyle(Palette.onDarkMuted)
                        .padding(.horizontal, 6).background(Palette.asphaltActive, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isActive ? Palette.asphaltActive : (hovering ? Palette.asphaltField : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DataFolderStatus: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(needsAttention ? Palette.salmon : store.savingPaused != nil ? Palette.accent : Palette.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PavingData folder").font(.ui(12, weight: .semibold)).foregroundStyle(Color(hex: 0xE6E7E9))
                    Text(statusLine).font(.ui(11.5)).foregroundStyle(Palette.sidebarMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Palette.asphaltRaised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.asphaltActive))
            .contentShape(Rectangle())
            .onTapGesture {
                store.settingsSectionRequest = .data
                store.selection = .settings
            }
            .contextMenu {
                Button("Show in Finder") {
                    if let url = store.dataFolder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Browse History…") { store.historyRequest = HistoryRequest() }
            }
            .help("Data & backups")
            .accessibilityAddTraits(.isButton)
        }
    }

    private var attentionCount: Int {
        store.unavailable.count + store.conflicts.count + store.unsavedLastTime.count
    }

    private var needsAttention: Bool { store.problem != nil || attentionCount > 0 }

    private var icon: String {
        if needsAttention { return "exclamationmark.icloud" }
        if store.savingPaused != nil { return "pause.circle" }
        return store.isInICloud ? "checkmark.icloud" : "checkmark.circle"
    }

    private var statusLine: String {
        let place = store.isInICloud ? "iCloud Drive" : "This Mac"
        if store.savingPaused != nil { return "Saving paused" }
        if attentionCount > 0 { return "\(attentionCount) \(attentionCount == 1 ? "item needs" : "items need") a look" }
        if store.pendingCount > 0 { return "\(place) · saving…" }
        guard let saved = store.lastSaved else { return "\(place) · up to date" }
        let seconds = Date.now.timeIntervalSince(saved)
        let when = seconds < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: saved, relativeTo: .now)
        return "\(place) · saved \(when)"
    }
}
