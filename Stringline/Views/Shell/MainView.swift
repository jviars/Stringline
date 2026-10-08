import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let problem = store.launchProblem {
                DataProblemView(problem: problem)
            } else if store.needsOnboarding {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .background(WindowConfigurator())
        .preferredColorScheme(.light)
    }
}

struct MainView: View {
    @Environment(AppStore.self) private var store
    @Environment(Assistant.self) private var assistant
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 236)
                .ignoresSafeArea()
            ContentRouter()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Palette.ground.ignoresSafeArea())
                .overlay(alignment: .top) { AssistantWorkingBanner() }
            if assistant.isOpen {
                AssistantPanel()
                    .frame(width: AssistantPanelWidth.value)
                    .ignoresSafeArea(edges: .top)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.18), value: assistant.isOpen)
        .background(WindowWidener(open: assistant.isOpen))
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            TourLayer(anchors: anchors).ignoresSafeArea()
        }
        .overlayPreferenceValue(HelpSpotKey.self) { anchors in
            SpotlightLayer(anchors: anchors).ignoresSafeArea()
        }
        .overlay(alignment: .bottom) { StatusBanners() }
        .sheet(isPresented: $store.showSearch) { SearchSheet() }
        .background {
            Color.clear.sheet(isPresented: $store.showNewLead) { NewLeadSheet() }
        }
        .background {
            // Two versions of a file: the person chooses before carrying on.
            Color.clear.sheet(item: Binding(get: { store.conflicts.first }, set: { _ in })) { conflict in
                ConflictSheet(conflict: conflict).environment(store)
            }
        }
        .background {
            Color.clear.sheet(isPresented: Binding(get: { store.showLockPrompt && store.savingPaused != nil && store.conflicts.isEmpty },
                                                   set: { store.showLockPrompt = $0 })) {
                if let other = store.savingPaused { LockPromptSheet(other: other).environment(store) }
            }
        }
        .background {
            Color.clear.sheet(item: $store.historyRequest) { request in
                HistorySheet(request: request).environment(store)
            }
        }
        .background {
            Color.clear.sheet(item: $store.zohoImport) { session in
                ZohoImportSheet(session: session, undoManager: undoManager).environment(store)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.rescan()
            store.refreshWeather()
            store.runBackupIfDue()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            store.flush()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            store.flush()
        }
    }
}

struct ContentRouter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.selection {
        case .today: TodayView()
        case .pipeline: PipelineView()
        case .measure: MeasureHomeView()
        case .jobs: JobsListView()
        case .schedule: ScheduleView()
        case .customers: CustomersView()
        case .invoices: InvoicesView()
        case .equipment:
            ComingLaterView(title: "Equipment", icon: "truck.box",
                            message: "Service hours, registrations and inspection dates for your trucks, paver and rollers. This part of Stringline is planned for a later version.")
        case .crew: SettingsView(initialSection: .crews)
        case .documents:
            ComingLaterView(title: "Documents", icon: "folder",
                            message: "Your insurance certificate, W-9 and license in one place, ready to send. Until then, proposals and plans live in each job's docs folder.")
        case .learn: LearnView()
        case .settings: SettingsView()
        case .job(let id): JobDetailView(jobID: id).id(id)
        }
    }
}

struct ComingLaterView: View {
    let title: String
    let icon: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Shop", title: title)
            EmptyState(icon: icon, title: "Coming in a later version", message: message)
                .card()
                .padding(.horizontal, 32)
                .padding(.top, 16)
            Spacer()
        }
    }
}

/// While the assistant works in Action mode, a slim bar over the screen says so, with Stop.
struct AssistantWorkingBanner: View {
    @Environment(Assistant.self) private var assistant

    var body: some View {
        if assistant.isRunning && assistant.mode == .action {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Palette.accent)
                Text("Assistant is working").font(.ui(12.5, weight: .bold)).foregroundStyle(.white)
                if let status = assistant.status {
                    Text(status).font(.ui(12.5)).foregroundStyle(Palette.onDarkMuted).lineLimit(1)
                }
                Button("Stop") { assistant.stop() }
                    .buttonStyle(.plain)
                    .font(.ui(12, weight: .bold))
                    .foregroundStyle(Palette.salmon)
                    .help("Stop (Esc)")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Palette.asphalt, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

enum AssistantPanelWidth {
    static let value: CGFloat = 400
}

/// Makes room for the assistant panel by widening the window when the screen has space,
/// and gives that room back when the panel closes.
struct WindowWidener: NSViewRepresentable {
    let open: Bool

    final class Coordinator {
        var added: CGFloat = 0
        var lastOpen = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard open != coordinator.lastOpen else { return }
        coordinator.lastOpen = open
        DispatchQueue.main.async {
            guard let window = view.window, !window.styleMask.contains(.fullScreen), !window.isZoomed,
                  let screen = window.screen?.visibleFrame else { return }
            var frame = window.frame
            if open {
                let room = max(0, screen.maxX - frame.maxX) + max(0, frame.minX - screen.minX)
                let grow = min(AssistantPanelWidth.value, room)
                guard grow > 0 else { return }
                frame.size.width += grow
                if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
                coordinator.added = grow
            } else {
                guard coordinator.added > 0 else { return }
                frame.size.width = max(window.minSize.width, frame.width - coordinator.added)
                coordinator.added = 0
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

/// Lets the window be dragged by its background, since the title bar is hidden.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Search (⌘K)

struct SearchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var jobHits: [Job] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(store.jobs.prefix(6)) }
        return store.jobs.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q)
                || $0.number.localizedCaseInsensitiveContains(q) || store.customerName(for: $0).localizedCaseInsensitiveContains(q)
        }
    }

    private var customerHits: [Customer] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return store.customers.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.contact.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                TextField("Search jobs, customers, addresses…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.ui(16))
                    .focused($focused)
                    .onSubmit(openFirst)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !jobHits.isEmpty {
                        sectionLabel("Jobs")
                        ForEach(jobHits) { job in
                            row(icon: "list.clipboard", title: job.name, detail: "\(job.number) · \(store.customerName(for: job)) · \(job.stage.label)") {
                                store.openJob(job.id); dismiss()
                            }
                        }
                    }
                    if !customerHits.isEmpty {
                        sectionLabel("Customers")
                        ForEach(customerHits) { customer in
                            row(icon: "person.2", title: customer.name, detail: customer.contact.isEmpty ? customer.type.label : customer.contact) {
                                store.selection = .customers; dismiss()
                            }
                        }
                    }
                    if jobHits.isEmpty && customerHits.isEmpty {
                        Text("Nothing matches “\(query)”.").font(.ui(13)).foregroundStyle(Palette.secondary).padding(16)
                    }
                }
                .padding(8)
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .onAppear { focused = true }
    }

    private func openFirst() {
        if let job = jobHits.first { store.openJob(job.id); dismiss() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.eyebrow).tracking(0.8).foregroundStyle(Palette.tertiary).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    private func row(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(Palette.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.ui(12)).foregroundStyle(Palette.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
