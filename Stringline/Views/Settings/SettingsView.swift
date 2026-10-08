import SwiftUI
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case company, rates, weather, proposal, data, crews, assistant
    var id: String { rawValue }
    var label: String {
        switch self {
        case .company: "Company"
        case .rates: "Rates & markup"
        case .weather: "Weather rules"
        case .proposal: "Proposals & reminders"
        case .data: "Data & backups"
        case .crews: "Crews & equipment"
        case .assistant: "AI assistant"
        }
    }
    var icon: String {
        switch self {
        case .company: "building.2"
        case .rates: "dollarsign.circle"
        case .weather: "cloud.sun"
        case .proposal: "doc.text"
        case .data: "externaldrive"
        case .crews: "person.3"
        case .assistant: "bubble.left.and.text.bubble.right"
        }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    var initialSection: SettingsSection = .rates
    @State private var section: SettingsSection?

    var body: some View {
        let current = section ?? (store.tourStop == .settings ? .rates : initialSection)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Saved to PavingData › settings.json and rates.json", title: "Settings & rates") {
                Button {
                    if let url = store.dataFolder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 2) {
                    ForEach(SettingsSection.allCases) { item in
                        let active = item == current
                        Button {
                            section = item
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon).frame(width: 18).foregroundStyle(active ? Palette.ink : Palette.tertiary)
                                Text(item.label).font(.ui(13, weight: active ? .bold : .medium)).foregroundStyle(Palette.ink)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(active ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Palette.border : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
                .frame(width: 220)
                .helpSpot("settings.sections")
                ScrollView {
                    Group {
                        switch current {
                        case .company: CompanySettings()
                        case .rates: RatesSettings()
                        case .weather: WeatherSettings()
                        case .proposal: ProposalSettings()
                        case .data: DataSettings()
                        case .crews: CrewSettings()
                        case .assistant: AssistantSettings()
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: 900, alignment: .leading)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
        }
        .onAppear {
            if let request = store.settingsSectionRequest {
                section = request
                store.settingsSectionRequest = nil
            } else if section == nil, store.tourStop != .settings {
                section = initialSection
            }
        }
        .onChange(of: store.settingsSectionRequest) { _, request in
            guard let request else { return }
            section = request
            store.settingsSectionRequest = nil
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.display(26))
            Text(text).font(.ui(13)).foregroundStyle(Palette.secondary)
        }
    }
}

// MARK: - Company

private struct CompanySettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let s = store.settingsBinding
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Company", text: "This goes at the top of every proposal and invoice.")
            HStack(alignment: .top, spacing: 24) {
                LogoPicker()
                VStack(spacing: 14) {
                    TextBox(label: "Company name", text: s.company.name)
                    HStack(alignment: .top, spacing: 14) {
                        TextBox(label: "Phone", text: s.company.phone)
                        TextBox(label: "Email", text: s.company.email)
                    }
                    TextBox(label: "Mailing address", text: s.company.address, suggestsAddresses: true)
                    HStack(alignment: .top, spacing: 14) {
                        TextBox(label: "Contractor license", text: s.company.license, hint: "optional")
                        TextBox(label: "Website", text: s.company.website, hint: "optional")
                    }
                }
            }
            .card(padding: 20)
            HomeBaseFinder().card(padding: 20)
        }
    }
}

struct HomeBaseFinder: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var searching = false
    @State private var message: String?
    @State private var locator = LocationFetcher()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(systemName: "mappin.and.ellipse", tone: .dark, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text("Home base").font(.ui(15, weight: .bold))
                Text("Used for the go / no-go weather check and as the starting spot on the map.")
                    .font(.ui(13)).foregroundStyle(Palette.secondary)
                HStack(spacing: 10) {
                    FieldBox(content: {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                        TextField("City, state or ZIP", text: $query).textFieldStyle(.plain).onSubmit { AddressCompleter.unlessPicked(find) }
                            .addressSuggestions($query) { picked in if let c = picked.coordinate { set(picked.text, c) } }
                    }, height: 40)
                    Button(searching ? "Finding…" : "Find", action: find).buttonStyle(SecondaryButtonStyle()).disabled(query.isEmpty || searching)
                    Button {
                        useMyLocation()
                    } label: {
                        Label("Use this Mac's location", systemImage: "location")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 8)
                if let line = message ?? (store.settings.company.homeBase.isEmpty ? nil : "Home base: \(store.settings.company.homeBase)") {
                    Label(line, systemImage: store.settings.company.homeLatitude == nil || message != nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .font(.ui(12.5, weight: .semibold))
                        .foregroundStyle(store.settings.company.homeLatitude == nil || message != nil ? Palette.noGoInk : Palette.goInk)
                        .padding(.top, 6)
                }
            }
        }
        .onAppear { query = store.settings.company.homeBase }
    }

    private func find() {
        searching = true
        Task {
            let results = await Places.search(query)
            searching = false
            guard let first = results.first else {
                message = "Couldn't find “\(query)”. Try a city and state."
                return
            }
            let name = first.detail.isEmpty ? first.name : (first.detail.contains(first.name) ? first.detail : "\(first.name), \(first.detail)")
            set(name, first.coordinate)
        }
    }

    private func useMyLocation() {
        Task {
            do {
                let location = try await locator.fetch()
                let name = await Places.townName(for: location) ?? "This Mac's location"
                query = name
                set(name, Coordinate(lat: location.coordinate.latitude, lon: location.coordinate.longitude))
            } catch {
                message = "Location isn't available. Allow it in System Settings › Privacy & Security, or type your town."
            }
        }
    }

    private func set(_ name: String, _ coordinate: Coordinate) {
        store.settings.company.homeBase = name
        store.settings.company.homeLatitude = coordinate.lat
        store.settings.company.homeLongitude = coordinate.lon
        store.markDirty(.settings)
        message = nil
        store.refreshWeather(force: true)
    }
}

// MARK: - Rates

private struct RatesSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rates = store.ratesBinding
        let settings = store.settingsBinding
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Rates & markup", text: "Every new estimate starts with these. You can still change any number on a single job.")
            Label("Changes apply to new estimates. Bids you've already sent keep the numbers they went out with.", systemImage: "info.circle")
                .font(.ui(12.5, weight: .medium))
                .foregroundStyle(Palette.infoInk)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.infoBg, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Prices") {
                    Button {
                        var item = PriceItem(id: "custom-\(UUID().uuidString.prefix(8))", name: "New price", unit: "ea", cents: 0, group: "Materials")
                        item.changed = .now
                        store.rates.prices.append(item)
                        store.markDirty(.rates)
                    } label: {
                        Label("Add a price", systemImage: "plus")
                    }
                    .buttonStyle(LinkButtonStyle())
                }
                .padding(.bottom, 10)
                HStack(spacing: 10) {
                    Text("ITEM").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PRICE").frame(width: 120, alignment: .trailing)
                    Text("PER").frame(width: 70, alignment: .leading)
                    Text("GROUP").frame(width: 150, alignment: .leading)
                    Text("CHANGED").frame(width: 70, alignment: .leading)
                    Color.clear.frame(width: 20)
                }
                .font(.eyebrow).tracking(0.7).foregroundStyle(Palette.tertiary)
                .padding(.vertical, 6)
                ForEach(Rates.groups, id: \.self) { group in
                    let items = store.rates.prices.filter { $0.group == group }
                    if !items.isEmpty {
                        Text(group).font(.ui(12.5, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surfaceSunk)
                        ForEach(items) { item in
                            PriceRow(item: priceBinding(item.id), canDelete: item.id.hasPrefix("custom-")) {
                                store.rates.prices.removeAll { $0.id == item.id }
                                store.markDirty(.rates)
                            }
                            .overlay(alignment: .top) { Hairline() }
                        }
                    }
                }
            }
            .card(padding: 20)
            .tourAnchor(.settings)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Quantities")
                    NumberBox(label: "Mix weight", value: rates.factors.mixLbPerSYInch, unit: "lb / SY / inch")
                    NumberBox(label: "Tack rate", value: rates.factors.tackGalPerSY, unit: "gal / SY", decimals: 2)
                    NumberBox(label: "Paint coverage", value: rates.factors.paintLFPerGal, unit: "LF / gal")
                    NumberBox(label: "Waste", value: rates.factors.wastePct, unit: "%")
                    NumberBox(label: "Truck size", value: rates.factors.truckTons, unit: "tons")
                    NumberBox(label: "Paving crew size", value: rates.factors.crewSize, unit: "people")
                    NumberBox(label: "Crew day", value: rates.factors.hoursPerDay, unit: "hours")
                    NumberBox(label: "Paving per day", value: rates.factors.paveSYPerDay, unit: "SY")
                }
                .card(padding: 20)
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Markup & terms")
                    NumberBox(label: "Overhead", value: rates.factors.overheadPct, unit: "%")
                    NumberBox(label: "Default profit", value: rates.factors.profitPct, unit: "%")
                    NumberBox(label: "Proposals good for", value: Binding(get: { Double(store.settings.proposal.validDays) },
                                                                        set: { settings.wrappedValue.proposal.validDays = Int($0) }), unit: "days")
                    Toggle(isOn: settings.proposal.escalationClause) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add an asphalt price escalation clause").font(.ui(13, weight: .semibold))
                            Text("Protects you if liquid asphalt prices jump before the job.").font(.ui(12)).foregroundStyle(Palette.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .card(padding: 20)
            }
            Text("Saved automatically\(store.lastSaved.map { " · last change \(Fmt.dayYear($0))" } ?? "")")
                .font(.ui(12.5)).foregroundStyle(Palette.tertiary)
        }
    }

    private func priceBinding(_ id: String) -> Binding<PriceItem> {
        Binding(
            get: { store.rates.prices.first { $0.id == id } ?? PriceItem(id: id, name: "", unit: "", cents: 0, group: "") },
            set: { new in
                guard let i = store.rates.prices.firstIndex(where: { $0.id == id }) else { return }
                var updated = new
                if updated.cents != store.rates.prices[i].cents { updated.changed = .now }
                store.rates.prices[i] = updated
                store.markDirty(.rates)
            })
    }
}

private struct PriceRow: View {
    @Binding var item: PriceItem
    var canDelete: Bool
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $item.name).textFieldStyle(.plain).font(.ui(13)).frame(maxWidth: .infinity)
            MoneyInput(cents: $item.cents, label: "\(item.name) price", width: 120)
            TextField("Unit", text: $item.unit).textFieldStyle(.plain).font(.ui(13)).foregroundStyle(Palette.secondary).frame(width: 70)
            Picker("Group", selection: $item.group) {
                ForEach(Rates.groups, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            Text(Fmt.day(item.changed)).font(.ui(12)).foregroundStyle(Palette.tertiary).frame(width: 70, alignment: .leading)
            Button(action: onDelete) { Image(systemName: "minus.circle.fill").foregroundStyle(Palette.control) }
                .buttonStyle(.plain)
                .frame(width: 20)
                .opacity(canDelete ? 1 : 0)
                .disabled(!canDelete)
                .help("Built-in prices can't be removed, only changed")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Weather

private struct WeatherSettings: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Weather rules", text: "Today and the schedule check every job day against these.")
            WeatherRulesEditor(rules: store.settingsBinding.weather).card(padding: 22)
            HomeBaseFinder().card(padding: 20)
            HStack {
                Text(store.weather.updated.map { "Forecast from Open-Meteo, updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Forecast from Open-Meteo")
                    .font(.ui(12.5)).foregroundStyle(Palette.tertiary)
                Spacer()
                Button("Refresh forecast") { store.refreshWeather(force: true) }.buttonStyle(SmallButtonStyle())
            }
        }
    }
}

// MARK: - Proposals

private struct ProposalSettings: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        let s = store.settingsBinding
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Proposals & reminders", text: "The standard wording on every proposal, and when to remind past customers.")
            VStack(alignment: .leading, spacing: 14) {
                editor("Not included", text: s.proposal.exclusions)
                editor("Terms", text: s.proposal.terms)
                editor("Price adjustment clause", text: s.proposal.escalationText)
            }
            .card(padding: 20)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Numbering")
                    NumberBox(label: "Next proposal number", value: Binding(get: { Double(store.settings.nextProposalNumber) }, set: { s.wrappedValue.nextProposalNumber = max(1, Int($0)) }))
                    NumberBox(label: "Next invoice number", value: Binding(get: { Double(store.settings.nextInvoiceNumber) }, set: { s.wrappedValue.nextInvoiceNumber = max(1, Int($0)) }))
                }
                .card(padding: 20)
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Repeat business")
                    NumberBox(label: "Remind about resealing after", value: Binding(get: { Double(store.settings.sealcoatCycleYears) }, set: { s.wrappedValue.sealcoatCycleYears = max(1, Int($0)) }), unit: "years")
                    Text("Finished sealcoat jobs show up under Due for sealcoat on Today once they're this old.")
                        .font(.ui(12)).foregroundStyle(Palette.secondary)
                }
                .card(padding: 20)
            }
        }
    }

    private func editor(_ label: String, text: Binding<String>) -> some View {
        LabeledField(label: label) {
            TextEditor(text: text)
                .font(.ui(13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 70)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.control))
        }
    }
}

// MARK: - Data

private struct DataSettings: View {
    @Environment(AppStore.self) private var store
    @State private var errorText: String?
    @State private var backingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Data & backups", text: "Everything is plain files in one folder. No account, no server.")
            HealthCard()
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "PavingData folder")
                Text(store.dataFolder?.path(percentEncoded: false) ?? "Not set")
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Button {
                        if let url = store.dataFolder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: { Label("Show in Finder", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Open a different folder…") {
                        guard let url = FilePicker.chooseFolder(title: "Open a PavingData folder", prompt: "Open", canCreate: false) else { return }
                        do { try store.openExistingFolder(url) } catch { errorText = error.localizedDescription }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Import from Zoho…") { ZohoImporter.choose(store: store) }
                        .buttonStyle(SecondaryButtonStyle())
                        .helpSpot("settings.zohoImport")
                }
                if store.isInICloud {
                    Label("Tip: in Finder, right-click PavingData and choose Keep Downloaded so jobs open with no internet.", systemImage: "lightbulb")
                        .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                }
            }
            .card(padding: 20)
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "History", subtitle: "Every save, kept on this Mac")
                Text("Each time Stringline saves, it also keeps a copy in a history on this Mac (outside iCloud): every save for two weeks, one an hour back to 90 days, then one a day for two years. Any job or file can be put back the way it was.")
                    .font(.ui(12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    store.historyRequest = HistoryRequest()
                } label: { Label("Browse History…", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .card(padding: 20)
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Backups")
                Toggle("Make a backup every night", isOn: store.settingsBinding.backupNightly).toggleStyle(.checkbox)
                Text(store.settings.lastBackup.map { "Last backup \($0.formatted(date: .abbreviated, time: .shortened)). The last 30 are kept twice: in the backups folder and on this Mac." }
                     ?? "No backup yet.")
                    .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                HStack(spacing: 8) {
                    Button(backingUp ? "Backing up…" : "Back up now") {
                        backingUp = true
                        store.runBackupIfDue(force: true)
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); backingUp = false }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(backingUp)
                    Button("Open backups folder") {
                        if let url = store.dataFolder?.appending(path: "backups", directoryHint: .isDirectory) {
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Backups on this Mac") {
                        if let root = store.dataFolder {
                            let url = store.localBackupsFolder(for: root)
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .card(padding: 20)
            if !store.notices.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "Recent activity")
                    ForEach(store.notices, id: \.self) { notice in
                        Label(notice, systemImage: "info.circle")
                            .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .card(padding: 20)
            }
        }
        .alert("Couldn't open that folder", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }
}

/// Opens and checks every file, and offers a one-click fix for anything that's off.
private struct HealthCard: View {
    @Environment(AppStore.self) private var store
    @State private var checking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(systemName: headlineIcon, tone: headlineTone, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.ui(16, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(subline).font(.ui(12.5)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button(checking ? "Checking…" : "Check Now") { check() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(checking)
            }
            if let report = store.health, !report.issues.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(report.issues.enumerated()), id: \.element.id) { index, issue in
                        if index > 0 { Hairline() }
                        issueRow(issue)
                    }
                }
                .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .card(padding: 20)
        .onAppear { if store.health == nil { store.checkHealth() } }
        .alert("Couldn't restore", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private var headline: String {
        guard let report = store.health else { return "Checking your files…" }
        if report.isHealthy { return "All \(report.files) files are healthy" }
        return "\(report.issues.count) \(report.issues.count == 1 ? "thing needs" : "things need") a look"
    }

    private var subline: String {
        guard let report = store.health else { return "" }
        var parts = ["Checked \(AppStore.when(report.checkedAt))", "\(Fmt.number(Double(report.historyVersions))) versions in History"]
        if report.localBackups > 0 { parts.append("\(report.localBackups) \(report.localBackups == 1 ? "backup" : "backups") on this Mac") }
        return parts.joined(separator: " · ")
    }

    private var headlineIcon: String { store.health?.isHealthy ?? true ? "checkmark.shield" : "exclamationmark.shield" }
    private var headlineTone: Tone { store.health?.isHealthy ?? true ? .go : .watch }

    private func check() {
        checking = true
        store.checkHealth(deep: true)
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            checking = false
        }
    }

    private func issueRow(_ issue: HealthIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(issue.kind)).foregroundStyle(Palette.watchInk).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.ui(13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(issue.detail).font(.ui(12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions(issue.kind) }
        }
        .padding(12)
    }

    private func icon(_ kind: HealthIssue.Kind) -> String {
        switch kind {
        case .file(_, .downloading): "icloud.and.arrow.down"
        case .file(_, .syncNotResponding): "icloud.slash"
        case .file: "exclamationmark.triangle"
        case .conflict: "arrow.triangle.branch"
        case .duplicateFolder: "folder.badge.questionmark"
        case .missingJob, .missingFile: "questionmark.folder"
        case .unsavedLastTime: "clock.badge.exclamationmark"
        case .otherMac: "pause.circle"
        case .lowDisk: "internaldrive"
        case .history: "clock.arrow.circlepath"
        }
    }

    @ViewBuilder
    private func actions(_ kind: HealthIssue.Kind) -> some View {
        switch kind {
        case .file(let path, let issue):
            if issue.waitsOnItsOwn {
                Button("Check Again") { store.checkHealth() }.buttonStyle(SmallButtonStyle())
            } else if !store.versions(of: path).isEmpty {
                Button("History…") { store.historyRequest = HistoryRequest(path: path) }.buttonStyle(SmallButtonStyle())
            }
            showInFinder(path)
        case .conflict:
            EmptyView()
        case .duplicateFolder(let copy, _):
            showInFinder("jobs/\(copy)")
        case .missingJob(let folder):
            Button("Restore") { attempt { try store.restoreJob(folder: folder) } }.buttonStyle(SmallButtonStyle())
            Button("Dismiss") { store.forgetMissing(paths: JobPart.allCases.map { "jobs/\(folder)/\($0.fileName)" }) }.buttonStyle(SmallButtonStyle())
        case .missingFile(let path):
            Button("Restore") {
                attempt {
                    guard let newest = store.versions(of: path).first(where: { $0.reason != .setAside }) else { return }
                    try store.restore(newest)
                }
            }
            .buttonStyle(SmallButtonStyle())
            Button("Dismiss") { store.forgetMissing(paths: [path]) }.buttonStyle(SmallButtonStyle())
        case .unsavedLastTime(let id, let path):
            Button("Restore") {
                attempt {
                    guard let version = store.versions(of: path).first(where: { $0.id == id }) else { return }
                    try store.restore(version)
                }
            }
            .buttonStyle(SmallButtonStyle())
            Button("Dismiss") {
                if let version = store.unsavedLastTime.first(where: { $0.id == id }) { store.dismissUnsaved(version) }
            }
            .buttonStyle(SmallButtonStyle())
        case .otherMac:
            Button("Use This Mac") { store.takeOver(); store.checkHealth() }.buttonStyle(SmallButtonStyle())
        case .lowDisk, .history:
            EmptyView()
        }
    }

    private func showInFinder(_ path: String) -> some View {
        Button("Show in Finder") {
            if let url = store.dataFolder?.appending(path: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .buttonStyle(SmallButtonStyle())
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { errorText = error.localizedDescription }
        store.checkHealth()
    }
}

// MARK: - Crews

private struct CrewSettings: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Crews & equipment", text: "Each crew gets its own row on the schedule.")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.settingsBinding.crews) { $crew in
                    HStack(alignment: .bottom, spacing: 12) {
                        TextBox(label: "Name", text: $crew.name).frame(width: 140)
                        TextBox(label: "Does", text: $crew.kind, placeholder: "Paving, seal & stripe…").frame(width: 170)
                        NumberBox(label: "People", value: Binding(get: { Double(crew.people) }, set: { crew.people = max(1, Int($0)) })).frame(width: 90)
                        TextBox(label: "Equipment", text: $crew.equipment, placeholder: "Paver, rollers, sealer rig…")
                        Button {
                            store.settings.crews.removeAll { $0.id == crew.id }
                            store.markDirty(.settings)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Palette.tertiary).frame(height: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.settings.crews.count <= 1)
                        .accessibilityLabel("Remove \(crew.name)")
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) { Hairline() }
                }
                Button {
                    var crew = Crew()
                    crew.name = "Crew \(String(UnicodeScalar(65 + store.settings.crews.count)!))"
                    store.settings.crews.append(crew)
                    store.markDirty(.settings)
                } label: {
                    Label("Add a crew", systemImage: "plus")
                }
                .buttonStyle(LinkButtonStyle())
                .padding(.top, 12)
            }
            .card(padding: 20)
            Text("Truck and equipment service tracking is planned for a later version.")
                .font(.ui(12.5)).foregroundStyle(Palette.tertiary)
        }
    }
}
