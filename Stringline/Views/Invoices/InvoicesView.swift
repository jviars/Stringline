import SwiftUI
import AppKit

struct InvoicesView: View {
    @Environment(AppStore.self) private var store

    private var rows: [(Job, Invoice)] {
        store.realJobs.compactMap { job in store.invoices[job.id].map { (job, $0) } }
            .sorted { a, b in
                if a.1.isPaid != b.1.isPaid { return !a.1.isPaid }
                return a.1.issued > b.1.issued
            }
    }

    var body: some View {
        let unpaid = rows.filter { !$0.1.isPaid }
        let readyToBill = store.realJobs.filter { $0.stage == .won && store.invoices[$0.id] == nil && ($0.completedOn != nil || $0.schedule.contains { $0.day < Date().startOfDay }) }
        VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "\(unpaid.count) unpaid · \(Fmt.dollars(unpaid.reduce(0) { $0 + $1.1.balanceCents }, showCents: false))", title: "Invoices")
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    aging(unpaid.map(\.1))
                    if !readyToBill.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            CardHeader(title: "Ready to bill", subtitle: "Won jobs that are done or underway with no invoice yet").padding(.bottom, 6)
                            ForEach(readyToBill) { job in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(job.name).font(.ui(13, weight: .semibold))
                                        Text(store.customerName(for: job)).font(.ui(12)).foregroundStyle(Palette.secondary)
                                    }
                                    Spacer()
                                    Text(store.priceCents(for: job.id).map { Fmt.dollars($0) } ?? "No price").monospacedDigit()
                                    Button("Create invoice") {
                                        store.createInvoice(for: job.id)
                                        store.openJob(job.id, tab: .invoice)
                                    }
                                    .buttonStyle(SmallButtonStyle())
                                }
                                .padding(.vertical, 9)
                                .overlay(alignment: .top) { Hairline() }
                            }
                        }
                        .card(padding: 20)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Text("INVOICE").frame(width: 70, alignment: .leading)
                            Text("JOB").frame(maxWidth: .infinity, alignment: .leading)
                            Text("ISSUED").frame(width: 80, alignment: .leading)
                            Text("BALANCE").frame(width: 100, alignment: .trailing)
                            Text("STATUS").frame(width: 150, alignment: .trailing)
                            Color.clear.frame(width: 90)
                        }
                        .font(.eyebrow).tracking(0.7).foregroundStyle(Palette.tertiary)
                        .padding(.bottom, 8)
                        if rows.isEmpty {
                            Text("No invoices yet. Create one from a won job's Invoice tab.")
                                .font(.ui(13)).foregroundStyle(Palette.secondary).padding(.vertical, 12)
                                .overlay(alignment: .top) { Hairline() }
                        }
                        ForEach(rows, id: \.1.id) { job, invoice in
                            HStack(spacing: 10) {
                                Text(invoice.number).font(.ui(13, weight: .semibold)).monospacedDigit().frame(width: 70, alignment: .leading)
                                Button {
                                    store.openJob(job.id, tab: .invoice)
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(job.name).font(.ui(13, weight: .semibold)).foregroundStyle(Palette.ink)
                                        Text(store.customerName(for: job)).font(.ui(12)).foregroundStyle(Palette.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Text(Fmt.day(invoice.issued)).font(.ui(12.5)).frame(width: 80, alignment: .leading)
                                Text(Fmt.dollars(invoice.balanceCents)).font(.ui(13, weight: .semibold)).monospacedDigit().frame(width: 100, alignment: .trailing)
                                InvoiceStatusPill(invoice: invoice).frame(width: 150, alignment: .trailing)
                                Group {
                                    if invoice.isPaid {
                                        Button("Unpaid") { setPaid(job.id, nil) }
                                    } else {
                                        Button("Mark paid") { setPaid(job.id, .now) }
                                    }
                                }
                                .buttonStyle(SmallButtonStyle())
                                .frame(width: 90, alignment: .trailing)
                            }
                            .padding(.vertical, 10)
                            .overlay(alignment: .top) { Hairline() }
                        }
                    }
                    .card(padding: 20)
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
    }

    private func setPaid(_ jobID: UUID, _ date: Date?) {
        guard var invoice = store.invoices[jobID] else { return }
        invoice.paidOn = date
        store.invoiceBinding(jobID).wrappedValue = invoice
    }

    private func aging(_ unpaid: [Invoice]) -> some View {
        let notDue = unpaid.filter { $0.daysLate == 0 }.reduce(0) { $0 + $1.balanceCents }
        let late30 = unpaid.filter { (1...30).contains($0.daysLate) }.reduce(0) { $0 + $1.balanceCents }
        let late60 = unpaid.filter { (31...60).contains($0.daysLate) }.reduce(0) { $0 + $1.balanceCents }
        let lateMore = unpaid.filter { $0.daysLate > 60 }.reduce(0) { $0 + $1.balanceCents }
        return HStack(spacing: 0) {
            StatBlock(label: "Not due yet", value: Fmt.dollars(notDue, showCents: false)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            VRule().padding(.vertical, 4)
            StatBlock(label: "1–30 days late", value: Fmt.dollars(late30, showCents: false)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            VRule().padding(.vertical, 4)
            StatBlock(label: "31–60 days late", value: Fmt.dollars(late60, showCents: false)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            VRule().padding(.vertical, 4)
            StatBlock(label: "Over 60 days late", value: Fmt.dollars(lateMore, showCents: false)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border))
    }
}

struct InvoiceStatusPill: View {
    let invoice: Invoice
    var body: some View {
        if let paid = invoice.paidOn {
            Pill(text: "Paid \(Fmt.day(paid))", tone: .go, icon: "checkmark")
        } else if invoice.daysLate > 0 {
            Pill(text: "\(invoice.daysLate) days late", tone: .noGo)
        } else {
            let days = Calendar.current.daysBetween(.now, invoice.due)
            Pill(text: days == 0 ? "Due today" : "Due in \(days) days", tone: .neutral)
        }
    }
}

// MARK: - Job tab

struct InvoiceTabView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            Group {
                if let invoice = store.invoices[jobID] {
                    editor(invoice).helpSpot("jobInvoice.card")
                } else {
                    VStack(spacing: 14) {
                        EmptyState(icon: "doc.text", title: "No invoice yet",
                                   message: store.priceCents(for: jobID).map { "Create one for \(Fmt.dollars($0)), the price of the option you picked. You can change the amount." }
                                       ?? "Create one and enter the amount, or build an estimate first.")
                        Button {
                            store.createInvoice(for: jobID)
                        } label: {
                            Label("Create invoice", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                    }
                    .card(padding: 32)
                    .frame(maxWidth: 620)
                    .helpSpot("jobInvoice.card")
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Couldn't make the invoice", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func editor(_ invoice: Invoice) -> some View {
        let binding = Binding<Invoice>(
            get: { store.invoices[jobID] ?? invoice },
            set: { store.invoiceBinding(jobID).wrappedValue = $0 })
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Invoice \(invoice.number)").font(.display(26))
                    Spacer()
                    InvoiceStatusPill(invoice: invoice)
                }
                HStack(alignment: .top, spacing: 14) {
                    LabeledField(label: "Issued") {
                        DatePicker("Issued", selection: binding.issued, displayedComponents: .date).labelsHidden()
                    }
                    LabeledField(label: "Payment terms") {
                        Picker("Terms", selection: binding.dueDays) {
                            Text("Due on receipt").tag(0)
                            Text("Net 15").tag(15)
                            Text("Net 30").tag(30)
                            Text("Net 45").tag(45)
                            Text("Net 60").tag(60)
                        }
                        .labelsHidden()
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    LabeledField(label: "Amount") { MoneyInput(cents: binding.amountCents, label: "Amount") }
                    LabeledField(label: "Deposit received") { MoneyInput(cents: binding.depositCents, label: "Deposit") }
                }
                TextBox(label: "Note on the invoice", text: binding.note, placeholder: "Thanks for your business!")
                Divider()
                HStack {
                    Text("Balance due").font(.ui(14, weight: .semibold))
                    Spacer()
                    Text(Fmt.dollars(invoice.balanceCents)).font(.display(28)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    if invoice.isPaid {
                        Button("Mark unpaid") { binding.wrappedValue.paidOn = nil }.buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button {
                            binding.wrappedValue.paidOn = .now
                        } label: {
                            Label("Mark paid", systemImage: "checkmark")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button {
                        email(invoice)
                    } label: {
                        Label("Email invoice", systemImage: "envelope")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Spacer()
                    Button("Delete invoice", role: .destructive) { store.invoiceBinding(jobID).wrappedValue = nil }
                        .buttonStyle(SmallButtonStyle())
                }
            }
            .card(padding: 22)
            .frame(maxWidth: 620)
            Spacer(minLength: 0)
        }
    }

    private func email(_ invoice: Invoice) {
        guard let job = store.job(jobID), let docs = store.docsFolder(job) else { return }
        let url = docs.appending(path: "Invoice \(invoice.number) - \(job.name.replacingOccurrences(of: "/", with: "-")).pdf")
        do {
            try InvoicePDF.render(InvoicePage(company: store.settings.company, logo: store.logoImage,
                                              customer: store.customer(job.customerID), job: job, invoice: invoice,
                                              lines: store.estimates[jobID]?.selected.map { [$0.title] } ?? []), to: url)
        } catch {
            errorText = error.localizedDescription
            return
        }
        let customer = store.customer(job.customerID)
        Mailer.compose(to: customer?.email, subject: "Invoice \(invoice.number) for \(job.name)",
                       body: "Hi \(customer?.contact.isEmpty == false ? customer!.contact : "there"),\n\nAttached is invoice \(invoice.number) for \(job.name). The balance of \(Fmt.dollars(invoice.balanceCents)) is due by \(Fmt.dayYear(invoice.due)).\n\nThanks,\n\(store.settings.company.name)",
                       attachments: [url])
    }
}

extension AppStore {
    func createInvoice(for jobID: UUID) {
        var invoice = Invoice()
        invoice.number = nextInvoiceNumber()
        invoice.amountCents = priceCents(for: jobID) ?? 0
        invoiceBinding(jobID).wrappedValue = invoice
    }
}

// MARK: - Invoice PDF

struct InvoicePage: View {
    let company: CompanyInfo
    let logo: NSImage?
    let customer: Customer?
    let job: Job
    let invoice: Invoice
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    if let logo { Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 48) } else { LogoMark(size: 34) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(company.name.isEmpty ? "Your company" : company.name).font(.display(18))
                        Text([company.phone, company.email].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 8.5))
                        if !company.address.isEmpty { Text(company.address).font(.system(size: 8.5)) }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("INVOICE").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(Palette.tertiary)
                    Text("No. \(invoice.number)").font(.system(size: 10, weight: .semibold))
                    Text("Issued \(Fmt.dayYear(invoice.issued))").font(.system(size: 9.5))
                    Text("Due \(Fmt.dayYear(invoice.due))").font(.system(size: 9.5, weight: .semibold))
                }
            }
            Rectangle().fill(Palette.ink).frame(height: 1.5)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BILL TO").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
                    Text(customer?.name ?? "—").font(.system(size: 11, weight: .semibold))
                    if let contact = customer?.contact, !contact.isEmpty { Text(contact).font(.system(size: 9.5)) }
                    if let address = customer?.address, !address.isEmpty { Text(address).font(.system(size: 9.5)) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROJECT").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Palette.tertiary)
                    Text(job.name).font(.system(size: 11, weight: .semibold))
                    if !job.address.isEmpty { Text(job.address).font(.system(size: 9.5)) }
                }
                Spacer()
            }
            VStack(spacing: 0) {
                row(lines.first.map { "\($0) — as proposed" } ?? "Paving work", Fmt.dollars(invoice.amountCents), bold: false)
                if invoice.depositCents > 0 { row("Deposit received", "−" + Fmt.dollars(invoice.depositCents), bold: false) }
                row("Balance due", Fmt.dollars(invoice.balanceCents), bold: true)
            }
            if !invoice.note.isEmpty { Text(invoice.note).font(.system(size: 10)) }
            Spacer()
            Text("Please make checks payable to \(company.name.isEmpty ? "us" : company.name). Thank you.")
                .font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }
        .foregroundStyle(Palette.ink)
        .padding(40)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(.white)
    }

    private func row(_ label: String, _ value: String, bold: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: bold ? 12 : 10.5, weight: bold ? .bold : .regular))
            Spacer()
            Text(value).font(bold ? .display(18) : .system(size: 10.5)).monospacedDigit()
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

@MainActor
enum InvoicePDF {
    static func render(_ page: InvoicePage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ProposalRenderer.RenderError.cantCreate }
        let renderer = ImageRenderer(content: page.environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: 612, height: 792)
        renderer.render { _, draw in
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }
}
