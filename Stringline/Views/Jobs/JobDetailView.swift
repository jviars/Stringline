import SwiftUI
import AppKit

struct JobDetailView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    @State private var confirmDelete = false

    var body: some View {
        if let job = store.job(jobID) {
            VStack(spacing: 0) {
                header(job)
                Group {
                    if let part = store.jobTab.part, let issue = store.unavailableParts(of: jobID)[part] {
                        // Never let anyone edit over a file Stringline couldn't read.
                        FileUnavailableView(job: job, part: part, issue: issue)
                    } else if store.jobTab == .estimate, let issue = store.unavailableParts(of: jobID)[.takeoff] {
                        FileUnavailableView(job: job, part: .takeoff, issue: issue)
                    } else {
                        switch store.jobTab {
                        case .overview: JobOverviewView(jobID: jobID)
                        case .measure: MeasureView(jobID: jobID)
                        case .estimate: EstimateView(jobID: jobID)
                        case .schedule: JobScheduleView(jobID: jobID)
                        case .logs: DailyLogsView(jobID: jobID)
                        case .photos: PhotosView(jobID: jobID)
                        case .invoice: InvoiceTabView(jobID: jobID)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .confirmationDialog("Move \(job.name) to the Trash?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { store.deleteJob(jobID) }
            } message: {
                Text("The job's folder goes to the Trash, so you can put it back from Finder if you change your mind.")
            }
        } else {
            EmptyState(icon: "questionmark.folder", title: "This job is gone", message: "It may have been moved to the Trash.")
        }
    }

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Button("Jobs") { store.selection = .jobs }.buttonStyle(.plain)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        Text(job.isSample ? "Sample" : job.type.label)
                    }
                    .font(.ui(12))
                    .foregroundStyle(Palette.tertiary)
                    HStack(spacing: 10) {
                        Text(job.name).font(.display(30))
                        Pill(text: job.isSample ? "Sample job" : job.stage.label, tone: stageTone(job.stage))
                    }
                    HStack(spacing: 18) {
                        if !job.address.isEmpty { Label(job.address, systemImage: "mappin.and.ellipse") }
                        if let customer = store.customer(job.customerID) {
                            Label(customer.contact.isEmpty ? customer.name : "\(customer.name) · \(customer.contact)", systemImage: "person")
                        }
                        if let due = job.bidDue, job.stage != .won, job.stage != .lost {
                            Label("Bid due \(Fmt.day(due))", systemImage: "clock")
                        }
                    }
                    .font(.ui(12.5))
                    .foregroundStyle(Palette.secondary)
                    .padding(.top, 4)
                }
                Spacer()
                Button {
                    if let url = store.jobFolder(job) {
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())
                Menu {
                    Picker("Stage", selection: store.jobBinding(jobID).stage) {
                        ForEach(Stage.allCases) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button("History…") { store.historyRequest = HistoryRequest(jobFolder: job.folderName) }
                    Divider()
                    Button("Open in Maps") { MapsLink.open(job, directions: false) }
                        .disabled(!MapsLink.canOpen(job))
                    Button("Directions") { MapsLink.open(job, directions: true) }
                        .disabled(!MapsLink.canOpen(job))
                    Divider()
                    Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34, height: 34)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0xDCDCD7)))
                .accessibilityLabel("More actions")
                .helpSpot("job.menu")
            }
            HStack(spacing: 4) {
                ForEach(JobTab.allCases) { tab in
                    let active = store.jobTab == tab
                    Button {
                        store.jobTab = tab
                    } label: {
                        Text(label(for: tab, job: job))
                            .font(.ui(13, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? Palette.ink : Palette.secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(active ? Palette.ink : .clear).frame(height: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .helpSpot("job.tabs")
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .background(Palette.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func label(for tab: JobTab, job: Job) -> String {
        if tab == .photos, let folder = store.photosFolder(job) {
            let count = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.count
            return count > 0 ? "Photos · \(count)" : "Photos"
        }
        return tab.label
    }

    private func stageTone(_ stage: Stage) -> Tone {
        switch stage {
        case .lead: .neutral
        case .siteVisit: .info
        case .estimating: .watch
        case .sent: .watch
        case .won: .go
        case .lost: .noGo
        }
    }
}
