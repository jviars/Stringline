import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @State private var step: Step = .welcome
    @State private var folderChoice: FolderChoice = AppStore.iCloudDrive == nil ? .mac : .iCloud
    @State private var macFolder: URL?
    @State private var errorText: String?
    @State private var cloud: CloudCheck = .unknown
    @State private var showCloudStuck = false

    enum Step: Int, CaseIterable {
        case welcome, company, data, rates, ready
    }

    enum FolderChoice { case iCloud, mac, existing }

    /// Whether iCloud Drive is answering on this Mac. Its sync service can get stuck (for example after
    /// the account ran out of space), and anything waiting on it would wait forever.
    enum CloudCheck { case unknown, checking, ok, stuck }

    var body: some View {
        Group {
            if step == .welcome {
                WelcomeView(start: { step = .company }, openExisting: openExisting)
                    .ignoresSafeArea()
            } else {
                HStack(spacing: 0) {
                    SetupRail(step: step).frame(width: 360).ignoresSafeArea()
                    VStack(spacing: 0) {
                        // Keeps the scroll area from sliding up under the title bar.
                        Color.clear.frame(height: 12)
                        ScrollView {
                            Group {
                                switch step {
                                case .company: CompanyStep()
                                case .data: DataStep(choice: $folderChoice, macFolder: $macFolder, cloud: cloud, checkAgain: { Task { await checkCloud() } })
                                case .rates: RatesStep()
                                case .ready: ReadyStep(finish: finish)
                                case .welcome: EmptyView()
                                }
                            }
                            .frame(maxWidth: 800, alignment: .leading)
                            .padding(.horizontal, 48)
                            .padding(.top, 20)
                            .padding(.bottom, 32)
                            .frame(maxWidth: .infinity)
                        }
                        footer
                    }
                    .background(Palette.ground.ignoresSafeArea())
                }
            }
        }
        .onAppear {
            if store.dataFolder != nil { step = .rates }
        }
        .onChange(of: store.onboardingStepRequest) { _, requested in
            if let requested, let target = Step(rawValue: requested) { step = target }
        }
        .task(id: step) {
            if step == .data, store.dataFolder == nil, AppStore.iCloudDrive != nil, cloud == .unknown { await checkCloud() }
        }
        .alert("iCloud Drive isn't responding", isPresented: $showCloudStuck) {
            Button("Use a Folder on This Mac…") { useMacFolderInstead() }
            Button("Try Again") { createFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stringline tried to reach iCloud Drive, but macOS's iCloud sync isn't answering on this Mac. Nothing was saved there.\n\nRestarting the Mac usually fixes it. Or keep your jobs in a folder on this Mac for now. Later you can move the PavingData folder into iCloud Drive in Finder and open it from Settings › Data & backups.")
        }
        .alert("Couldn't use that folder", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Button {
                step = Step(rawValue: step.rawValue - 1) ?? .welcome
            } label: {
                Label("Back", systemImage: "arrow.left")
            }
            .buttonStyle(SecondaryButtonStyle(large: true))
            Spacer()
            switch step {
            case .company:
                Button("Skip for now") { step = .data }.buttonStyle(.plain).font(.ui(13, weight: .semibold)).foregroundStyle(Palette.secondary)
                continueButton { step = .data }
            case .data:
                if folderChoice == .iCloud, cloud == .checking, store.dataFolder == nil {
                    Button {} label: {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking iCloud Drive…")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .disabled(true)
                } else {
                    continueButton(createFolder)
                }
            case .rates:
                Button("Use the samples for now") { step = .ready }.buttonStyle(.plain).font(.ui(13, weight: .semibold)).foregroundStyle(Palette.secondary)
                continueButton { step = .ready }
            case .ready:
                Button {
                    finish(nil)
                } label: {
                    Label("Open Stringline", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
            case .welcome:
                EmptyView()
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 16)
        .background(Palette.surface)
        .overlay(alignment: .top) { Hairline() }
    }

    private func continueButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Continue", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(PrimaryButtonStyle(large: true))
        .keyboardShortcut(.defaultAction)
    }

    private func createFolder() {
        if store.dataFolder != nil { step = .rates; return }
        guard folderChoice == .iCloud, AppStore.iCloudDrive != nil, cloud != .ok else { return makeFolder() }
        // Ask iCloud first, off the main thread, so a stuck sync service can't freeze setup.
        Task {
            if await checkCloud() { makeFolder() } else { showCloudStuck = true }
        }
    }

    /// True if iCloud Drive answers within a few seconds.
    @discardableResult
    private func checkCloud() async -> Bool {
        guard let target = AppStore.suggestedICloudFolder else { return false }
        cloud = .checking
        let answered = await Task.detached { SafeFile.checkSync(target) }.value
        cloud = answered ? .ok : .stuck
        return answered
    }

    private func useMacFolderInstead() {
        folderChoice = .mac
        if macFolder == nil {
            macFolder = FilePicker.chooseFolder(title: "Choose where PavingData should go", prompt: "Choose", canCreate: true)
        }
        if macFolder != nil { makeFolder() }
    }

    private func makeFolder() {
        let target: URL?
        switch folderChoice {
        case .iCloud: target = AppStore.suggestedICloudFolder
        case .mac: target = macFolder?.appending(path: "PavingData", directoryHint: .isDirectory)
        case .existing:
            openExisting()
            return
        }
        guard let target else {
            errorText = folderChoice == .mac ? "Choose a folder on this Mac first." : "iCloud Drive isn't turned on for this Mac."
            return
        }
        do {
            if JSONFile.exists(target.appending(path: "settings.json")) {
                try store.openExistingFolder(target)
                if store.settings.onboardingComplete { return }
            } else {
                try store.createDataFolder(at: target)
            }
            store.savePendingLogo()
            step = .rates
        } catch SafeFile.Failure.notResponding {
            cloud = .stuck
            showCloudStuck = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openExisting() {
        guard let url = FilePicker.chooseFolder(title: "Open your PavingData folder", prompt: "Open", canCreate: false) else { return }
        do {
            try store.openExistingFolder(url)
            if !store.settings.onboardingComplete { step = .rates }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func finish(_ destination: SidebarItem?) {
        store.settings.onboardingComplete = true
        store.markDirty(.settings)
        store.flush()
        store.selection = destination ?? .today
        store.refreshWeather(force: true)
    }
}

// MARK: - Left rail

private struct SetupRail: View {
    let step: OnboardingView.Step

    private let steps: [(OnboardingView.Step, String, String)] = [
        (.company, "Your company", "Name, logo, home base"),
        (.data, "Where your data lives", "A folder you own"),
        (.rates, "Services & rates", "What you do and what it costs"),
        (.ready, "Ready", "Pick where to start"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 10) {
                LogoMark(size: 34)
                Text("Stringline").font(.display(22)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up Stringline").font(.display(36)).foregroundStyle(.white)
                Text("About three minutes. You can change any of this later in Settings.")
                    .font(.ui(14)).foregroundStyle(Palette.onDarkMuted).lineSpacing(3)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    let state: StepState = item.0.rawValue < step.rawValue ? .done : (item.0 == step ? .current : .upcoming)
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            switch state {
                            case .done:
                                Circle().fill(Palette.accent)
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Palette.ink)
                            case .current:
                                Circle().strokeBorder(.white, lineWidth: 2)
                                Text("\(index + 1)").font(.ui(13, weight: .bold)).foregroundStyle(.white)
                            case .upcoming:
                                Circle().strokeBorder(Palette.asphaltRule, lineWidth: 2)
                                Text("\(index + 1)").font(.ui(13, weight: .bold)).foregroundStyle(Palette.sidebarMuted)
                            }
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.1).font(.ui(14, weight: state == .current ? .bold : .semibold))
                                .foregroundStyle(state == .upcoming ? Palette.onDarkMuted : .white)
                            Text(item.2).font(.ui(12.5)).foregroundStyle(state == .upcoming ? Palette.sidebarMuted : Palette.onDarkMuted)
                        }
                        .padding(.top, 3)
                    }
                    .padding(.bottom, index == steps.count - 1 ? 0 : 24)
                    .background(alignment: .topLeading) {
                        if index < steps.count - 1 {
                            Rectangle().fill(state == .done ? Palette.accent : Palette.asphaltLine)
                                .frame(width: 2).padding(.top, 32).padding(.bottom, 4).offset(x: 13)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(state == .current ? .isSelected : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Label("TIP", systemImage: "lightbulb").font(.eyebrow).tracking(0.9).foregroundStyle(Palette.accent)
                Text(tip).font(.ui(13)).foregroundStyle(Palette.sidebarText).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Palette.asphaltRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.asphaltActive))
        }
        .padding(.top, 48)
        .padding(.horizontal, 36)
        .padding(.bottom, 32)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.asphalt)
    }

    private enum StepState { case done, current, upcoming }

    private var tip: String {
        switch step {
        case .company: "Your logo and contact info go on every proposal and invoice, so your paperwork looks the same every time."
        case .data: "With iCloud Drive plus Time Machine, your jobs are backed up twice without you thinking about it."
        case .rates: "Not sure about a number? Leave the sample for now. After a few jobs, compare what you bid with what you actually spent."
        default: "Press ⌘K anytime to jump to any job or customer."
        }
    }
}

private struct StepHeading: View {
    let number: Int?
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let number {
                Text("STEP \(number) OF 4").font(.eyebrow).tracking(0.9).foregroundStyle(Palette.tertiary)
            }
            Text(title).font(.display(36)).foregroundStyle(Palette.ink)
            Text(text).font(.ui(15)).foregroundStyle(Palette.secondary).frame(maxWidth: 600, alignment: .leading)
        }
    }
}

// MARK: - Step 1: company

private struct CompanyStep: View {
    @Environment(AppStore.self) private var store
    @State private var townQuery = ""
    @State private var searching = false
    @State private var townMessage: String?
    @State private var locator = LocationFetcher()

    var body: some View {
        let settings = store.settingsBinding
        VStack(alignment: .leading, spacing: 28) {
            StepHeading(number: 1, title: "Tell us about your company", text: "This shows up at the top of every proposal and invoice Stringline makes for you.")
            HStack(alignment: .top, spacing: 24) {
                LogoPicker()
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        TextBox(label: "Company name", text: settings.company.name, placeholder: "As it should read on proposals").gridCellColumns(2)
                    }
                    GridRow {
                        TextBox(label: "Phone", text: settings.company.phone, placeholder: "Office or cell")
                        TextBox(label: "Email", text: settings.company.email, placeholder: "Where customers reply")
                    }
                    GridRow {
                        TextBox(label: "Mailing address", text: settings.company.address, placeholder: "Street, city, state, ZIP", suggestsAddresses: true).gridCellColumns(2)
                    }
                    GridRow {
                        TextBox(label: "Contractor license", text: settings.company.license, placeholder: "License number", hint: "optional")
                        TextBox(label: "Website", text: settings.company.website, placeholder: "yourcompany.com", hint: "optional")
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                IconTile(systemName: "mappin.and.ellipse", tone: .dark, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home base").font(.ui(15, weight: .bold))
                    Text("Stringline uses this for the go / no-go weather check and as the starting spot on the map.")
                        .font(.ui(13)).foregroundStyle(Palette.secondary)
                    HStack(spacing: 10) {
                        FieldBox(content: {
                            Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                            TextField("City, state or ZIP", text: $townQuery)
                                .textFieldStyle(.plain)
                                .onSubmit { AddressCompleter.unlessPicked(findTown) }
                                .addressSuggestions($townQuery) { picked in if let c = picked.coordinate { setHome(name: picked.text, coordinate: c) } }
                        }, height: 40)
                        Button("Find", action: findTown).buttonStyle(SecondaryButtonStyle()).disabled(townQuery.isEmpty || searching)
                        Button {
                            useMyLocation()
                        } label: {
                            Label("Use this Mac's location", systemImage: "location")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, 8)
                    if let message = townMessage ?? (store.settings.company.homeBase.isEmpty ? nil : "Home base: \(store.settings.company.homeBase)") {
                        Label(message, systemImage: store.settings.company.homeLatitude == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .font(.ui(12.5, weight: .semibold))
                            .foregroundStyle(store.settings.company.homeLatitude == nil ? Palette.noGoInk : Palette.goInk)
                            .padding(.top, 6)
                    }
                }
            }
            .card(padding: 20, radius: 16)
        }
        .onAppear { townQuery = store.settings.company.homeBase }
    }

    private func findTown() {
        searching = true
        Task {
            let results = await Places.search(townQuery)
            searching = false
            guard let first = results.first else {
                townMessage = "Couldn't find “\(townQuery)”. Try a city and state."
                return
            }
            let name = first.detail.isEmpty ? first.name : (first.detail.contains(first.name) ? first.detail : "\(first.name), \(first.detail)")
            setHome(name: name, coordinate: first.coordinate)
        }
    }

    private func useMyLocation() {
        Task {
            do {
                let location = try await locator.fetch()
                let name = await Places.townName(for: location) ?? "This Mac's location"
                townQuery = name
                setHome(name: name, coordinate: Coordinate(lat: location.coordinate.latitude, lon: location.coordinate.longitude))
            } catch {
                townMessage = "Location isn't available. Allow it in System Settings › Privacy & Security, or type your town."
            }
        }
    }

    private func setHome(name: String, coordinate: Coordinate) {
        store.settings.company.homeBase = name
        store.settings.company.homeLatitude = coordinate.lat
        store.settings.company.homeLongitude = coordinate.lon
        store.markDirty(.settings)
        townMessage = nil
        store.refreshWeather(force: true)
    }
}

struct LogoPicker: View {
    @Environment(AppStore.self) private var store
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Logo").font(.ui(12.5, weight: .semibold)).foregroundStyle(Color(hex: 0x3F4249))
            Button(action: choose) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(targeted ? Palette.surfaceSunk : Palette.surface)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(hex: 0xC9C9C3), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    if let image = store.logoImage {
                        Image(nsImage: image).resizable().scaledToFit().padding(14)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Color(hex: 0x3F4249))
                                .frame(width: 44, height: 44).background(Palette.chip, in: RoundedRectangle(cornerRadius: 12))
                            Text("Add your logo").font(.ui(13, weight: .bold)).foregroundStyle(Palette.ink)
                            Text("Drop a file or click").font(.ui(11.5)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .frame(width: 150, height: 150)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return store.setLogo(from: url)
            } isTargeted: { targeted = $0 }
            .accessibilityLabel("Add your logo")
        }
    }

    private func choose() {
        if let url = FilePicker.chooseImages(multiple: false).first {
            _ = store.setLogo(from: url)
        }
    }
}

// MARK: - Step 2: data folder

private struct DataStep: View {
    @Environment(AppStore.self) private var store
    @Binding var choice: OnboardingView.FolderChoice
    @Binding var macFolder: URL?
    let cloud: OnboardingView.CloudCheck
    let checkAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            StepHeading(number: 2, title: "Where should your jobs live?",
                        text: "Stringline saves everything as ordinary files in one folder. No account, no server. If you ever stop using the app, your jobs are still right there.")
            if let folder = store.dataFolder {
                Label("Using \(folder.path(percentEncoded: false))", systemImage: "checkmark.circle.fill")
                    .font(.ui(13, weight: .semibold)).foregroundStyle(Palette.goInk)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    option(.iCloud, icon: "icloud", tone: .info, title: "iCloud Drive", badge: "Recommended",
                           text: AppStore.iCloudDrive == nil
                               ? "iCloud Drive is off on this Mac. Turn it on in System Settings to use it."
                               : "Backs itself up and syncs to your other Macs. Open any proposal on your iPhone in the Files app.",
                           path: "iCloud Drive › Stringline › PavingData")
                        .disabled(AppStore.iCloudDrive == nil)
                    if AppStore.iCloudDrive != nil, store.dataFolder == nil {
                        cloudStatus
                    }
                    option(.mac, icon: "desktopcomputer", tone: .neutral, title: "A folder on this Mac", badge: nil,
                           text: "Pick any folder. Back it up with Time Machine or an external drive.",
                           path: macFolder.map { "\($0.path(percentEncoded: false))/PavingData" } ?? "Choose a folder…")
                    option(.existing, icon: "folder.badge.gearshape", tone: .neutral, title: "Open an existing PavingData folder", badge: nil,
                           text: "Already using Stringline on another Mac? Point this one at the same folder.", path: nil)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text("WHAT GETS CREATED").font(.eyebrow).tracking(0.9).foregroundStyle(Palette.onDarkMuted)
                    VStack(alignment: .leading, spacing: 3) {
                        treeLine("PavingData/", bright: true)
                        treeLine("├─ settings.json")
                        treeLine("├─ rates.json")
                        treeLine("├─ customers/")
                        treeLine("├─ jobs/")
                        treeLine("│  └─ 2026-001-maple-ridge/", accent: true)
                        treeLine("│     ├─ job.json")
                        treeLine("│     ├─ takeoff.json")
                        treeLine("│     ├─ estimate.json")
                        treeLine("│     └─ photos/")
                        treeLine("└─ backups/")
                    }
                    .padding(.top, 12)
                    Spacer(minLength: 12)
                    Text("One folder per job. Open it in Finder anytime, and Quick Look works on everything.")
                        .font(.ui(12.5)).foregroundStyle(Palette.onDarkMuted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(width: 290)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Palette.asphalt, in: RoundedRectangle(cornerRadius: 16))
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: store.settingsBinding.backupNightly) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Make a backup every night").font(.ui(13, weight: .semibold))
                        Text("Zips your job files and keeps the last 30 days in the backups folder.").font(.ui(12.5)).foregroundStyle(Palette.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                if choice == .iCloud {
                    Label("Tip: in Finder, right-click the PavingData folder and choose Keep Downloaded, so jobs open even with no internet at a job site.", systemImage: "lightbulb")
                        .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                }
            }
            .card(padding: 18)
            Label("Your jobs stay in this folder. There's no Stringline account and no Stringline server.", systemImage: "lock")
                .font(.ui(12.5)).foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder
    private var cloudStatus: some View {
        switch cloud {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking that iCloud Drive is answering…").font(.ui(12.5)).foregroundStyle(Palette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        case .stuck:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "icloud.slash").foregroundStyle(Palette.watchInk)
                VStack(alignment: .leading, spacing: 4) {
                    Text("iCloud Drive isn't responding on this Mac right now.").font(.ui(12.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Restarting the Mac usually fixes it. Or pick a folder on this Mac for now.")
                        .font(.ui(12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Check Again", action: checkAgain).buttonStyle(SmallButtonStyle())
            }
            .padding(12)
            .background(Palette.watchBg, in: RoundedRectangle(cornerRadius: 10))
        case .unknown, .ok:
            EmptyView()
        }
    }

    private func option(_ value: OnboardingView.FolderChoice, icon: String, tone: Tone, title: String, badge: String?, text: String, path: String?) -> some View {
        let selected = choice == value
        return Button {
            choice = value
            if value == .mac, macFolder == nil {
                macFolder = FilePicker.chooseFolder(title: "Choose where PavingData should go", prompt: "Choose", canCreate: true)
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17)).foregroundStyle(selected ? Palette.ink : Palette.tertiary).padding(.top, 10)
                IconTile(systemName: icon, tone: tone, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.ui(15, weight: .bold)).foregroundStyle(Palette.ink)
                        if let badge { Pill(text: badge, tone: .accent) }
                    }
                    Text(text).font(.ui(13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    if let path {
                        Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(hex: 0x3F4249)).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Palette.ink : Palette.border, lineWidth: 2))
            .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 11, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func treeLine(_ text: String, bright: Bool = false, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: bright ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(accent ? Palette.accent : (bright ? .white : Palette.sidebarMuted))
    }
}

// MARK: - Step 3: services and rates

private struct RatesStep: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rates = store.ratesBinding
        let settings = store.settingsBinding
        VStack(alignment: .leading, spacing: 24) {
            StepHeading(number: 3, title: "What do you do, and what does it cost?",
                        text: "Every estimate starts from these numbers. You can change any of them on a single job.")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Services").font(.ui(15, weight: .bold))
                    Text("\(store.settings.services.count) selected").font(.ui(12.5)).foregroundStyle(Palette.tertiary)
                }
                FlowLayout(spacing: 8) {
                    ForEach(Service.allCases) { service in
                        let on = store.settings.services.contains(service)
                        Button {
                            if on { store.settings.services.removeAll { $0 == service } } else { store.settings.services.append(service) }
                            store.markDirty(.settings)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(on ? Palette.accent : Palette.tertiary)
                                Text(service.label).font(.ui(13, weight: .semibold))
                            }
                            .foregroundStyle(on ? .white : Palette.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(on ? Palette.ink : Palette.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Palette.ink : Palette.control, lineWidth: 1.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("Starting rates").font(.ui(15, weight: .bold))
                    Pill(text: "Sample numbers", tone: .watch)
                }
                Text("These get the math working on day one. Swap in your real costs whenever you're ready.")
                    .font(.ui(13)).foregroundStyle(Palette.secondary)
                rateGroup("Materials") {
                    priceBox("Surface mix", key: "surfaceMix", unit: "per ton")
                    priceBox("Base & patch mix", key: "baseMix", unit: "per ton")
                    NumberBox(label: "Mix weight", value: rates.factors.mixLbPerSYInch, unit: "lb / SY / inch")
                    NumberBox(label: "Tack coat", value: rates.factors.tackGalPerSY, unit: "gal / SY", decimals: 2)
                }
                rateGroup("Labor & trucking") {
                    priceBox("Crew labor", key: "crewLabor", unit: "per hour")
                    NumberBox(label: "Truck size", value: rates.factors.truckTons, unit: "tons")
                    priceBox("Trucking", key: "truckLoad", unit: "per load")
                    NumberBox(label: "Crew size", value: rates.factors.crewSize, unit: "people")
                }
                rateGroup("Markup") {
                    NumberBox(label: "Waste", value: rates.factors.wastePct, unit: "%")
                    NumberBox(label: "Overhead", value: rates.factors.overheadPct, unit: "%")
                    NumberBox(label: "Profit", value: rates.factors.profitPct, unit: "%")
                    Color.clear.frame(height: 1)
                }
            }
            .card(padding: 22, radius: 16)

            WeatherRulesEditor(rules: settings.weather)
                .card(padding: 22, radius: 16)
        }
    }

    private func rateGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.eyebrow).tracking(0.9).foregroundStyle(Palette.tertiary)
            HStack(alignment: .top, spacing: 12) { content() }
        }
    }

    private func priceBox(_ label: String, key: String, unit: String) -> some View {
        LabeledField(label: label) {
            FieldBox {
                Text("$").foregroundStyle(Palette.tertiary)
                TextField(label, value: priceBinding(key), format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.plain).font(.ui(13.5, weight: .semibold)).monospacedDigit().labelsHidden()
                Text(unit).font(.ui(12)).foregroundStyle(Palette.tertiary).fixedSize()
            }
        }
    }

    private func priceBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { Double(store.rates.cents(key)) / 100 },
            set: { value in
                guard let i = store.rates.prices.firstIndex(where: { $0.id == key }) else { return }
                store.rates.prices[i].cents = Int((value * 100).rounded())
                store.rates.prices[i].changed = .now
                store.markDirty(.rates)
            })
    }
}

struct WeatherRulesEditor: View {
    @Binding var rules: WeatherRules

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(systemName: "cloud.rain", tone: .info, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weather rules").font(.ui(15, weight: .bold))
                    Text("The schedule flags any job day that breaks these.").font(.ui(12.5)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.bottom, 10)
            rule("Paving") {
                Text("Go when it's at least")
                small($rules.pavingMinF, unit: "°F")
                Text("and rising")
            }
            rule("Sealcoat & stripe") {
                Text("Go when it stays above")
                small($rules.sealcoatMinF, unit: "°F")
                Text("for")
                small(Binding(get: { Double(rules.sealcoatHours) }, set: { rules.sealcoatHours = Int($0) }), unit: "h")
            }
            rule("Rain") {
                Text("No-go if the chance is")
                small(Binding(get: { Double(rules.rainChanceMax) }, set: { rules.rainChanceMax = Int($0) }), unit: "%")
                Text("or more")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rule<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.ui(14, weight: .bold)).frame(width: 140, alignment: .leading)
            content()
        }
        .font(.ui(14))
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Hairline() }
    }

    private func small(_ value: Binding<Double>, unit: String) -> some View {
        FieldBox(content: {
            TextField(unit, value: value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.ui(14, weight: .bold))
                .monospacedDigit()
                .frame(width: 32)
            Text(unit).foregroundStyle(Palette.tertiary)
        }, height: 32)
        .fixedSize()
    }
}

// MARK: - Step 4: ready

private struct ReadyStep: View {
    @Environment(AppStore.self) private var store
    var finish: (SidebarItem?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StringlineArt(levelBody: Palette.ink, ground: Palette.control)
                .frame(width: 440, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("ALL SET").font(.eyebrow).tracking(0.9).foregroundStyle(Palette.goInk)
                Text("You're level and ready to go.").font(.display(40))
                Text("Stringline is set up\(store.settings.company.name.isEmpty ? "" : " for \(store.settings.company.name)"). Here's what got saved.")
                    .font(.ui(15)).foregroundStyle(Palette.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    check("Company info\(store.logoImage == nil ? "" : " and logo")", store.settings.company.name.isEmpty ? "Add it later in Settings" : "On every proposal and invoice")
                    check(store.isInICloud ? "PavingData in iCloud Drive" : "PavingData on this Mac", store.settings.backupNightly ? "Backed up every night" : "Nightly backup is off")
                }
                GridRow {
                    check("\(store.settings.services.count) services and starting rates", "Sample numbers for now", amber: true)
                    check(store.settings.company.homeBase.isEmpty ? "Weather check" : "Weather for \(store.settings.company.homeBase)",
                          store.settings.company.homeLatitude == nil ? "Set your home base in Settings" : "Go / no-go is on")
                }
            }
            .card(padding: 20, radius: 16)
            VStack(alignment: .leading, spacing: 10) {
                Text("Where do you want to start?").font(.ui(15, weight: .bold))
                HStack(spacing: 12) {
                    choice(icon: "safari", title: "Take the 2-minute tour", text: "Six quick stops that show where everything lives.", suggested: true) {
                        finish(.today)
                        store.startTour()
                    }
                    choice(icon: "square.dashed", title: "Measure your first lot", text: "Type an address and outline the pavement.") {
                        finish(.measure)
                    }
                    choice(icon: "flask", title: "Practice on a sample job", text: "Practice Plaza has fake numbers. Try anything.") {
                        finish(nil)
                        let job = store.ensurePracticeJob()
                        store.openJob(job.id, tab: .measure)
                    }
                }
            }
        }
    }

    private func check(_ title: String, _ detail: String, amber: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.goInk)
                .frame(width: 22, height: 22).background(Palette.goBg, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(13, weight: .semibold))
                Text(detail).font(.ui(12.5)).foregroundStyle(amber ? Palette.amberInk : Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice(icon: String, title: String, text: String, suggested: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    IconTile(systemName: icon, tone: suggested ? .dark : .neutral, size: 38)
                    Spacer()
                    if suggested { Text("Suggested").font(.ui(11, weight: .bold)).foregroundStyle(Palette.secondary) }
                }
                Text(title).font(.ui(15, weight: .bold)).foregroundStyle(Palette.ink)
                Text(text).font(.ui(12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(suggested ? Palette.ink : Palette.border, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Simple wrapping layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
