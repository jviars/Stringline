import SwiftUI

struct JobOverviewView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    @State private var finding = false
    @State private var findMessage: String?

    var body: some View {
        let job = store.jobBinding(jobID)
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        CardHeader(title: "Details")
                        TextBox(label: "Job name", text: job.name)
                        LabeledField(label: "Customer") {
                            CustomerPicker(customerID: job.customerID)
                        }
                        LabeledField(label: "Address") {
                            HStack(spacing: 8) {
                                FieldBox {
                                    TextField("Street, city", text: job.address).textFieldStyle(.plain).onSubmit { AddressCompleter.unlessPicked(findOnMap) }
                                        .addressSuggestions(job.address) { picked in if let place = picked.place { putOnMap(place) } }
                                }
                                Button(finding ? "Finding…" : "Find on map", action: findOnMap)
                                    .buttonStyle(SecondaryButtonStyle())
                                    .disabled(job.wrappedValue.address.isEmpty || finding)
                            }
                        }
                        if let findMessage {
                            Text(findMessage).font(.ui(12)).foregroundStyle(Palette.secondary)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            LabeledField(label: "Type") {
                                Picker("Type", selection: job.type) {
                                    ForEach(CustomerType.allCases) { Text($0.label).tag($0) }
                                }
                                .labelsHidden()
                            }
                            TextBox(label: "Lead source", text: job.source, placeholder: "Website, referral, drive-by…")
                        }
                        LabeledField(label: "Services") {
                            ServiceChips(selection: job.services)
                        }
                        LabeledField(label: "Notes") {
                            TextEditor(text: job.notes)
                                .font(.ui(13))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 110)
                                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.control))
                        }
                    }
                    .card(padding: 20)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 18) {
                    statusCard(job)
                    measureSummary
                }
                .frame(width: 380)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
    }

    private func statusCard(_ job: Binding<Job>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Status")
            LabeledField(label: "Stage") {
                Picker("Stage", selection: job.stage) {
                    ForEach(Stage.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            OptionalDateRow(label: "Site visit", date: job.siteVisit, includeTime: true)
            OptionalDateRow(label: "Bid due", date: job.bidDue, includeTime: job.wrappedValue.type == .publicBid)
            OptionalDateRow(label: "Proposal sent", date: job.sentOn)
            if job.wrappedValue.type == .publicBid {
                OptionalDateRow(label: "Pre-bid meeting", date: job.preBid, includeTime: true)
                NumberBox(label: "Bid bond", value: Binding(get: { job.wrappedValue.bidBondPct ?? 0 }, set: { job.wrappedValue.bidBondPct = $0 == 0 ? nil : $0 }), unit: "%")
            }
            if job.wrappedValue.stage == .won {
                OptionalDateRow(label: "Finished", date: job.completedOn)
            }
            if job.wrappedValue.stage == .lost {
                TextBox(label: "Why we lost it", text: job.lostReason, placeholder: "Price, timing, went with someone else…")
            }
        }
        .card(padding: 20)
    }

    private var measureSummary: some View {
        let summary = store.summary(for: jobID)
        let price = store.priceCents(for: jobID)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "At a glance")
            if summary.isEmpty {
                Text("No measurements yet.").font(.ui(13)).foregroundStyle(Palette.secondary)
                Button {
                    store.jobTab = .measure
                } label: {
                    Label("Measure the lot", systemImage: "ruler")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                ForEach(WorkType.allCases.filter { (summary.areaSqFt[$0] ?? 0) > 0 }) { type in
                    row(type.label, "\(Fmt.number(summary.areaSqFt[type] ?? 0)) sq ft · \(Fmt.number(summary.sy(type))) SY")
                }
                ForEach(WorkType.allCases.filter { (summary.lineFt[$0] ?? 0) > 0 }) { type in
                    row(type.label, "\(Fmt.number(summary.lineFt[type] ?? 0)) LF")
                }
                if let price {
                    Divider()
                    row("Bid price", Fmt.dollars(price, showCents: false), bold: true)
                }
            }
        }
        .card(padding: 20)
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.secondary)
            Spacer()
            Text(value).fontWeight(bold ? .bold : .semibold).monospacedDigit()
        }
        .font(.ui(13))
    }

    /// Saves where the job is, and points Measure there if nothing's been drawn yet.
    private func putOnMap(_ place: PlaceResult) {
        guard var updated = store.job(jobID) else { return }
        updated.latitude = place.coordinate.lat
        updated.longitude = place.coordinate.lon
        store.jobBinding(jobID).wrappedValue = updated
        if var takeoff = store.takeoffs[jobID], takeoff.shapes.isEmpty {
            takeoff.center = place.coordinate
            takeoff.spanMeters = 250
            store.takeoffBinding(jobID).wrappedValue = takeoff
        }
        let found = place.detail.contains(place.name) ? place.detail : "\(place.name)\(place.detail.isEmpty ? "" : ", \(place.detail)")"
        findMessage = "On the map: \(found). The Measure tab will open there."
    }

    private func findOnMap() {
        guard let job = store.job(jobID), !job.address.isEmpty else { return }
        finding = true
        Task {
            let near = store.settings.company.homeLatitude.flatMap { lat in store.settings.company.homeLongitude.map { Coordinate(lat: lat, lon: $0) } }
            let results = await Places.search(job.address, near: near)
            finding = false
            if let first = results.first {
                putOnMap(first)
            } else {
                findMessage = "Couldn't find that address. Try adding the city."
            }
        }
    }
}

struct OptionalDateRow: View {
    let label: String
    @Binding var date: Date?
    var includeTime = false

    var body: some View {
        HStack {
            Text(label).font(.ui(12.5, weight: .semibold)).foregroundStyle(Color(hex: 0x3F4249))
            Spacer()
            if let value = date {
                DatePicker(label, selection: Binding(get: { value }, set: { date = $0 }),
                           displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Button {
                    date = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(label)")
            } else {
                Button("Add") { date = Date().startOfDay.addingTimeInterval(includeTime ? 9 * 3600 : 0) }
                    .buttonStyle(SmallButtonStyle())
            }
        }
    }
}

struct ServiceChips: View {
    @Binding var selection: [Service]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Service.allCases) { service in
                let on = selection.contains(service)
                Button {
                    if on { selection.removeAll { $0 == service } } else { selection.append(service) }
                } label: {
                    Text(service.label)
                        .font(.ui(12.5, weight: .semibold))
                        .foregroundStyle(on ? .white : Palette.ink)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(on ? Palette.ink : Palette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Palette.ink : Palette.control))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct CustomerPicker: View {
    @Environment(AppStore.self) private var store
    @Binding var customerID: UUID?
    @State private var addingName = ""
    @State private var showAdd = false

    var body: some View {
        HStack(spacing: 8) {
            Picker("Customer", selection: $customerID) {
                Text("No customer").tag(UUID?.none)
                ForEach(store.customers) { customer in
                    Text(customer.name).tag(UUID?.some(customer.id))
                }
            }
            .labelsHidden()
            Button("New…") { addingName = ""; showAdd = true }
                .buttonStyle(SmallButtonStyle())
        }
        .alert("New customer", isPresented: $showAdd) {
            TextField("Name", text: $addingName)
            Button("Add") {
                let name = addingName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                customerID = store.createCustomer(name: name).id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can add their phone, email and address on the Customers screen.")
        }
    }
}
