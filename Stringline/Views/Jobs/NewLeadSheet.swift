import SwiftUI

struct NewLeadSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var customerID: UUID?
    @State private var address = ""
    @State private var coordinate: Coordinate?
    @State private var type: CustomerType = .commercial
    @State private var services: [Service] = []
    @State private var source = ""
    @State private var notes = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New lead").font(.display(28))
                Text("Just the basics. You can fill in the rest on the job.").font(.ui(13)).foregroundStyle(Palette.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextBox(label: "Job name", text: $name, placeholder: "Property or customer name, like Maple Ridge Plaza")
                    LabeledField(label: "Customer") { CustomerPicker(customerID: $customerID) }
                    LabeledField(label: "Address") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                FieldBox {
                                    Image(systemName: "mappin.and.ellipse").foregroundStyle(Palette.tertiary)
                                    TextField("Street and city", text: $address)
                                        .textFieldStyle(.plain)
                                        .onSubmit { AddressCompleter.unlessPicked(search) }
                                        .addressSuggestions($address) { picked in
                                            coordinate = picked.coordinate
                                            results = []
                                        }
                                }
                                Button(searching ? "Looking…" : "Look up", action: search)
                                    .buttonStyle(SecondaryButtonStyle())
                                    .disabled(address.isEmpty || searching)
                            }
                            if coordinate != nil {
                                Label("On the map", systemImage: "checkmark.circle.fill").font(.ui(12, weight: .semibold)).foregroundStyle(Palette.goInk)
                            }
                            ForEach(results) { result in
                                Button {
                                    address = result.detail.isEmpty ? result.name : "\(result.name), \(result.detail)"
                                    coordinate = result.coordinate
                                    results = []
                                } label: {
                                    HStack {
                                        Image(systemName: "mappin").foregroundStyle(Palette.tertiary)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(result.name).font(.ui(13, weight: .semibold))
                                            Text(result.detail).font(.ui(12)).foregroundStyle(Palette.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    LabeledField(label: "Type") {
                        Picker("Type", selection: $type) {
                            ForEach(CustomerType.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    LabeledField(label: "What they want") { ServiceChips(selection: $services) }
                    TextBox(label: "How they found you", text: $source, placeholder: "Phone call, website, referral…")
                    LabeledField(label: "Notes") {
                        TextEditor(text: $notes)
                            .font(.ui(13))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 80)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.control))
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add lead", action: create)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 680)
        .background(Palette.ground)
    }

    private func search() {
        searching = true
        Task {
            let near = store.settings.company.homeLatitude.flatMap { lat in store.settings.company.homeLongitude.map { Coordinate(lat: lat, lon: $0) } }
            results = await Places.search(address, near: near)
            searching = false
            if results.count == 1, let only = results.first {
                coordinate = only.coordinate
                results = []
            }
        }
    }

    private func create() {
        var job = store.createJob(name: name.trimmingCharacters(in: .whitespaces), customerID: customerID, address: address,
                                  type: type, services: services, stage: .lead, source: source, coordinate: coordinate)
        job.notes = notes
        store.jobBinding(job.id).wrappedValue = job
        if let coordinate {
            var takeoff = Takeoff()
            takeoff.center = coordinate
            takeoff.spanMeters = 250
            store.takeoffBinding(job.id).wrappedValue = takeoff
        }
        dismiss()
        store.openJob(job.id)
    }
}
