import SwiftUI
import AppKit

struct CustomersView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var confirmDelete = false

    private var filtered: [Customer] {
        store.customers.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.contact.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "\(store.customers.count) customer\(store.customers.count == 1 ? "" : "s")", title: "Customers") {
                Button {
                    ZohoImporter.choose(store: store)
                } label: {
                    Label("Import from Zoho…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(SecondaryButtonStyle())
                .helpSpot("customers.zohoImport")
                Button {
                    let customer = store.createCustomer(name: "New customer")
                    selectedID = customer.id
                } label: {
                    Label("New customer", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .helpSpot("customers.new")
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 0) {
                    FieldBox {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                        TextField("Filter", text: $query).textFieldStyle(.plain)
                    }
                    .padding(12)
                    Divider()
                    if store.customers.isEmpty {
                        Text("No customers yet. Add one here or when you create a lead.")
                            .font(.ui(13)).foregroundStyle(Palette.secondary).padding(16)
                        Spacer()
                    } else {
                        List(filtered, selection: $selectedID) { customer in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(customer.name).font(.ui(13, weight: .semibold))
                                Text([customer.type.label, customer.contact].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.ui(12)).foregroundStyle(Palette.secondary)
                            }
                            .padding(.vertical, 3)
                            .tag(customer.id)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(width: 300)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border))

                if let id = selectedID, store.customers.contains(where: { $0.id == id }) {
                    detail(id)
                } else {
                    EmptyState(icon: "person.2", title: "Pick a customer", message: "Their contact info and every job you've done for them show up here.")
                        .card()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .onAppear {
            if let request = store.customerRequest {
                selectedID = request
                store.customerRequest = nil
            }
            if selectedID == nil { selectedID = store.customers.first?.id }
            store.visibleCustomerID = selectedID
        }
        .onChange(of: selectedID) { _, id in store.visibleCustomerID = id }
        .onChange(of: store.customerRequest) { _, request in
            guard let request else { return }
            selectedID = request
            store.customerRequest = nil
        }
    }

    private func detail(_ id: UUID) -> some View {
        let customer = store.customerBinding(id)
        let jobs = store.jobs.filter { $0.customerID == id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    TextBox(label: "Name", text: customer.name, placeholder: "Company or person")
                    HStack(alignment: .top, spacing: 14) {
                        TextBox(label: "Contact person", text: customer.contact)
                        LabeledField(label: "Type") {
                            Picker("Type", selection: customer.type) {
                                ForEach(CustomerType.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        TextBox(label: "Phone", text: customer.phone)
                        TextBox(label: "Email", text: customer.email)
                    }
                    TextBox(label: "Billing address", text: customer.address, suggestsAddresses: true)
                    LabeledField(label: "Notes") {
                        TextEditor(text: customer.notes)
                            .font(.ui(13))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 80)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.control))
                    }
                    HStack(spacing: 8) {
                        Button {
                            let job = store.createJob(name: customer.wrappedValue.name, customerID: id, type: customer.wrappedValue.type)
                            store.openJob(job.id)
                        } label: {
                            Label("New job", systemImage: "plus")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button {
                            if let url = URL(string: "mailto:\(customer.wrappedValue.email)") { NSWorkspace.shared.open(url) }
                        } label: {
                            Label("Email", systemImage: "envelope")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(customer.wrappedValue.email.isEmpty)
                        Spacer()
                        Button("Delete…", role: .destructive) { confirmDelete = true }.buttonStyle(SmallButtonStyle())
                    }
                }
                .card(padding: 20)

                VStack(alignment: .leading, spacing: 4) {
                    CardHeader(title: "Jobs", subtitle: jobs.isEmpty ? "None yet" : "\(jobs.count) job\(jobs.count == 1 ? "" : "s")")
                        .padding(.bottom, 6)
                    ForEach(jobs) { job in
                        Button {
                            store.openJob(job.id)
                        } label: {
                            HStack {
                                Circle().fill(job.stage.dotColor).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(job.name).font(.ui(13, weight: .semibold))
                                    Text("\(job.number) · \(job.stage.label)").font(.ui(12)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Text(store.priceCents(for: job.id).map { Fmt.dollars($0, showCents: false) } ?? "—").monospacedDigit()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.tertiary)
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .top) { Hairline() }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .card(padding: 20)
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Delete \(customer.wrappedValue.name)?", isPresented: $confirmDelete) {
            Button("Delete customer", role: .destructive) {
                store.deleteCustomer(id)
                selectedID = store.customers.first?.id
            }
        } message: {
            Text("Their jobs stay, just without a customer attached. The customer's file goes to the Trash.")
        }
    }
}
