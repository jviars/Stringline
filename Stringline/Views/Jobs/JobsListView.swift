import SwiftUI

struct JobsListView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: Filter = .open
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\JobRow.updated, order: .reverse)]

    enum Filter: String, CaseIterable, Identifiable {
        case open = "Open", won = "Won", lost = "Lost", all = "All"
        var id: String { rawValue }
    }

    struct JobRow: Identifiable {
        let id: UUID
        let name: String
        let number: String
        let customer: String
        let stage: Stage
        let priceCents: Int
        let updated: Date
        let isSample: Bool
    }

    private var rows: [JobRow] {
        store.jobs
            .filter { job in
                switch filter {
                case .open: return job.stage != .won && job.stage != .lost
                case .won: return job.stage == .won
                case .lost: return job.stage == .lost
                case .all: return true
                }
            }
            .filter { job in
                query.isEmpty || job.name.localizedCaseInsensitiveContains(query) || job.address.localizedCaseInsensitiveContains(query)
                    || store.customerName(for: job).localizedCaseInsensitiveContains(query) || job.number.contains(query)
            }
            .map { JobRow(id: $0.id, name: $0.name, number: $0.number, customer: store.customerName(for: $0), stage: $0.stage,
                          priceCents: store.priceCents(for: $0.id) ?? 0, updated: $0.updated, isSample: $0.isSample) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "\(store.realJobs.count) job\(store.realJobs.count == 1 ? "" : "s")", title: "Jobs") {
                FieldBox {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                    TextField("Filter jobs", text: $query).textFieldStyle(.plain).frame(width: 180)
                }
                Button {
                    store.showNewLead = true
                } label: {
                    Label("New lead", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)

            if store.jobs.isEmpty {
                EmptyState(icon: "list.clipboard", title: "No jobs yet",
                           message: "Add a lead when someone calls, or start from Measure to size up a lot first.")
                    .card()
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Job", value: \.name) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.name).font(.ui(13, weight: .semibold))
                                if row.isSample { Tag(text: "Sample") }
                            }
                            Text(row.number).font(.ui(11.5)).foregroundStyle(Palette.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                    .width(min: 220, ideal: 300)
                    TableColumn("Customer", value: \.customer) { row in
                        Text(row.customer).foregroundStyle(Palette.secondary)
                    }
                    TableColumn("Stage", value: \.stage.rawValue) { row in
                        HStack(spacing: 6) {
                            Circle().fill(row.stage.dotColor).frame(width: 8, height: 8)
                            Text(row.stage.label)
                        }
                    }
                    .width(120)
                    TableColumn("Price", value: \.priceCents) { row in
                        Text(row.priceCents == 0 ? "—" : Fmt.dollars(row.priceCents, showCents: false))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(110)
                    TableColumn("Updated", value: \.updated) { row in
                        Text(Fmt.ago(row.updated).capitalizedFirst).foregroundStyle(Palette.secondary)
                    }
                    .width(110)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first {
                        Button("Open") { store.openJob(id) }
                        Button("Measure") { store.openJob(id, tab: .measure) }
                        Button("Estimate") { store.openJob(id, tab: .estimate) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { store.openJob(id) }
                }
                .scrollContentBackground(.hidden)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }
}
