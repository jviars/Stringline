import SwiftUI

/// The sidebar's Measure entry: size up a lot before there's a job, or jump back into one.
struct MeasureHomeView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false
    @State private var searched = false

    private var openJobs: [Job] {
        store.jobs.filter { $0.stage != .lost && $0.stage != .won }.sorted { $0.updated > $1.updated }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "Size up any lot", title: "Measure")
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Where's the lot?").font(.display(26))
                        Text("Search an address or business. Stringline starts a new lead there so your measurements are saved.")
                            .font(.ui(13.5)).foregroundStyle(Palette.secondary)
                        HStack(spacing: 10) {
                            FieldBox(content: {
                                Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                                TextField("Address, business name or intersection", text: $query)
                                    .textFieldStyle(.plain)
                                    .font(.ui(15))
                                    .onSubmit { AddressCompleter.unlessPicked(search) }
                                    .addressSuggestions($query, places: true) { picked in
                                        if let place = picked.place {
                                            results = [place]
                                            searched = true
                                        }
                                    }
                            }, height: 44)
                            .helpSpot("measure.search")
                            Button(searching ? "Searching…" : "Search", action: search)
                                .buttonStyle(PrimaryButtonStyle(large: true))
                                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                        }
                        if searched && results.isEmpty && !searching {
                            Text("Nothing found. Try adding the city or ZIP.").font(.ui(13)).foregroundStyle(Palette.secondary)
                        }
                        ForEach(results) { result in
                            HStack(spacing: 12) {
                                IconTile(systemName: "mappin.and.ellipse", tone: .neutral, size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.name).font(.ui(14, weight: .semibold))
                                    if !result.detail.isEmpty { Text(result.detail).font(.ui(12.5)).foregroundStyle(Palette.secondary) }
                                }
                                Spacer()
                                Button {
                                    start(at: result)
                                } label: {
                                    Label("Measure here", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
                                }
                                .buttonStyle(DarkButtonStyle())
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .top) { Hairline() }
                        }
                        if let lat = store.settings.company.homeLatitude, let lon = store.settings.company.homeLongitude {
                            Button("Or start near home base without an address") {
                                let job = store.createJob(name: "New lot", coordinate: Coordinate(lat: lat, lon: lon))
                                var takeoff = Takeoff()
                                takeoff.center = Coordinate(lat: lat, lon: lon)
                                takeoff.spanMeters = 3000
                                store.takeoffBinding(job.id).wrappedValue = takeoff
                                store.openJob(job.id, tab: .measure)
                            }
                            .buttonStyle(LinkButtonStyle())
                        }
                    }
                    .card(padding: 24, radius: 16)

                    if !openJobs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "Or pick up where you left off")
                                .padding(.bottom, 6)
                            ForEach(openJobs.prefix(8)) { job in
                                let summary = store.summary(for: job.id)
                                HStack(spacing: 12) {
                                    Circle().fill(job.stage.dotColor).frame(width: 9, height: 9)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(job.name).font(.ui(13.5, weight: .semibold))
                                            if job.isSample { Tag(text: "Sample") }
                                        }
                                        Text(summary.isEmpty ? "Not measured yet" : "\(Fmt.number(summary.pavedSY + summary.sy(.sealcoat))) SY measured · \(job.stage.label)")
                                            .font(.ui(12)).foregroundStyle(Palette.secondary)
                                    }
                                    Spacer()
                                    Button("Measure") { store.openJob(job.id, tab: .measure) }
                                        .buttonStyle(SmallButtonStyle())
                                }
                                .padding(.vertical, 9)
                                .overlay(alignment: .top) { Hairline() }
                            }
                        }
                        .card(padding: 20)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    private func search() {
        searching = true
        Task {
            let near = store.settings.company.homeLatitude.flatMap { lat in store.settings.company.homeLongitude.map { Coordinate(lat: lat, lon: $0) } }
            results = await Places.search(query, near: near)
            searching = false
            searched = true
        }
    }

    private func start(at result: PlaceResult) {
        let job = store.createJob(name: result.name, address: result.detail, coordinate: result.coordinate)
        var takeoff = Takeoff()
        takeoff.center = result.coordinate
        takeoff.spanMeters = 260
        store.takeoffBinding(job.id).wrappedValue = takeoff
        store.openJob(job.id, tab: .measure)
    }
}
