import SwiftUI
import AppKit

private struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct EstimateView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    @State private var preview: PreviewFile?
    @State private var working = false
    @State private var errorText: String?

    private var estimate: Estimate { store.estimates[jobID] ?? Estimate() }
    private var job: Job? { store.job(jobID) }

    var body: some View {
        Group {
            if let option = estimate.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        optionTabs(option)
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 16) {
                                LineItemsCard(jobID: jobID, optionID: option.id).helpSpot("jobEstimate.lines")
                                scopeCard(option).helpSpot("jobEstimate.scope")
                            }
                            .frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 14) {
                                BidSummaryCard(jobID: jobID, optionID: option.id)
                                    .tourAnchor(.estimate)
                                    .helpSpot("jobEstimate.summary")
                                HStack(spacing: 8) {
                                    Button {
                                        Task { await makePreview() }
                                    } label: {
                                        Label("Preview", systemImage: "eye").frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(SecondaryButtonStyle(large: true))
                                    Button {
                                        Task { await emailProposal() }
                                    } label: {
                                        Label(working ? "Making PDF…" : "Email to customer", systemImage: "envelope").frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(PrimaryButtonStyle(large: true))
                                    .disabled(working)
                                }
                                .helpSpot("jobEstimate.send")
                                Text("Opens a Mail draft with the PDF attached. A copy goes in this job's docs folder.")
                                    .font(.ui(12)).foregroundStyle(Palette.tertiary)
                            }
                            .frame(width: 360)
                        }
                    }
                    .padding(EdgeInsets(top: 18, leading: 28, bottom: 32, trailing: 28))
                }
            } else {
                emptyState
            }
        }
        .sheet(item: $preview) { file in
            VStack(spacing: 0) {
                HStack {
                    Text("Proposal preview").font(.ui(15, weight: .bold))
                    Spacer()
                    Button("Open in Preview") { NSWorkspace.shared.open(file.url) }.buttonStyle(SecondaryButtonStyle())
                    Button("Done") { preview = nil }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
                .padding(14)
                Divider()
                PDFPreview(url: file.url)
            }
            .frame(width: 760, height: 880)
        }
        .alert("Couldn't make the proposal", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: Empty

    private var emptyState: some View {
        let hasTakeoff = !(store.takeoffs[jobID]?.shapes.isEmpty ?? true)
        return VStack(spacing: 16) {
            EmptyState(icon: "doc.text", title: "No estimate yet",
                       message: hasTakeoff ? "Build one from your measurements. Every line uses your rates, and you can change anything."
                                           : "Measure the lot first and the quantities fill in for you. Or start with a blank estimate.")
            HStack(spacing: 10) {
                if hasTakeoff {
                    Button {
                        buildFromTakeoff()
                    } label: {
                        Label("Build from measurements", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                } else {
                    Button {
                        store.jobTab = .measure
                    } label: {
                        Label("Measure the lot", systemImage: "ruler")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                }
                Button("Start blank") { addOption(blank: true) }.buttonStyle(SecondaryButtonStyle(large: true))
            }
        }
        .card(padding: 32)
        .padding(32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Options

    private func optionTabs(_ selected: EstimateOption) -> some View {
        HStack(spacing: 8) {
            optionButtons(selected).helpSpot("jobEstimate.options")
            Spacer()
        }
    }

    private func optionButtons(_ selected: EstimateOption) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(estimate.options.enumerated()), id: \.element.id) { index, option in
                let active = option.id == selected.id
                Button {
                    var updated = estimate
                    updated.selectedOptionID = option.id
                    store.estimateBinding(jobID).wrappedValue = updated
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Option \(String(UnicodeScalar(65 + index)!))").font(.ui(11.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                        Text("\(option.title) · \(Fmt.dollars(option.breakdown.priceCents))")
                            .font(.ui(13, weight: active ? .bold : .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(active ? Palette.surface : Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(active ? Palette.ink : Color(hex: 0xDCDCD7), lineWidth: active ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Duplicate") { duplicate(option) }
                    Button("Delete option", role: .destructive) { delete(option) }.disabled(estimate.options.count < 2)
                }
            }
            Menu {
                Button("Copy of this option") { duplicate(selected) }
                Button("Build from measurements") { addOption(blank: false) }
                    .disabled(store.takeoffs[jobID]?.shapes.isEmpty ?? true)
                Button("Blank option") { addOption(blank: true) }
            } label: {
                Label("Add option", systemImage: "plus").font(.ui(13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: 50)
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color(hex: 0xC9C9C3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }

    private func buildFromTakeoff() {
        let takeoff = store.takeoffs[jobID] ?? Takeoff()
        var updated = estimate
        let option = Estimator.option(title: MeasureModel.optionTitle(takeoff), takeoff: takeoff, rates: store.rates)
        updated.options = [option]
        updated.selectedOptionID = option.id
        store.estimateBinding(jobID).wrappedValue = updated
        if let job, job.stage == .lead || job.stage == .siteVisit { store.setStage(jobID, .estimating) }
    }

    private func addOption(blank: Bool) {
        var updated = estimate
        var option: EstimateOption
        if blank {
            option = EstimateOption()
            option.title = updated.options.isEmpty ? "Option A" : "Option \(String(UnicodeScalar(65 + updated.options.count)!))"
            option.overheadPct = store.rates.factors.overheadPct
            option.profitPct = store.rates.factors.profitPct
        } else {
            let takeoff = store.takeoffs[jobID] ?? Takeoff()
            option = Estimator.option(title: MeasureModel.optionTitle(takeoff), takeoff: takeoff, rates: store.rates)
        }
        updated.options.append(option)
        updated.selectedOptionID = option.id
        store.estimateBinding(jobID).wrappedValue = updated
    }

    private func duplicate(_ option: EstimateOption) {
        var copy = option
        copy.id = UUID()
        copy.title = option.title + " (copy)"
        copy.items = option.items.map { var item = $0; item.id = UUID(); return item }
        var updated = estimate
        updated.options.append(copy)
        updated.selectedOptionID = copy.id
        store.estimateBinding(jobID).wrappedValue = updated
    }

    private func delete(_ option: EstimateOption) {
        var updated = estimate
        updated.options.removeAll { $0.id == option.id }
        if updated.selectedOptionID == option.id { updated.selectedOptionID = updated.options.first?.id }
        store.estimateBinding(jobID).wrappedValue = updated
    }

    // MARK: Scope

    private func scopeCard(_ option: EstimateOption) -> some View {
        let binding = optionBinding(option.id)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Scope of work", subtitle: "One line per step. This is what the customer reads.") {
                Button("Rewrite from measurements") {
                    let takeoff = store.takeoffs[jobID] ?? Takeoff()
                    binding.wrappedValue.scope = Estimator.scope(Estimator.summary(takeoff, factors: store.rates.factors), takeoff: takeoff)
                }
                .buttonStyle(LinkButtonStyle())
            }
            TextEditor(text: binding.scope)
                .font(.ui(13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.control))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exclusions & terms").font(.ui(13, weight: .semibold))
                    Text("From your proposal template in Settings").font(.ui(12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("Edit") { store.selection = .settings }.buttonStyle(SmallButtonStyle())
            }
            .padding(12)
            .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 10))
        }
        .card(padding: 20)
    }

    private func optionBinding(_ id: UUID) -> Binding<EstimateOption> {
        Binding(
            get: { (store.estimates[jobID] ?? Estimate()).options.first { $0.id == id } ?? EstimateOption() },
            set: { new in
                var updated = store.estimates[jobID] ?? Estimate()
                guard let i = updated.options.firstIndex(where: { $0.id == id }) else { return }
                updated.options[i] = new
                store.estimateBinding(jobID).wrappedValue = updated
            })
    }

    // MARK: Proposal

    private func proposalContent() async -> ProposalContent? {
        guard let job else { return nil }
        var updated = estimate
        if updated.proposalNumber.isEmpty {
            updated.proposalNumber = store.nextProposalNumber()
            store.estimateBinding(jobID).wrappedValue = updated
        }
        var options = updated.options
        if let selected = updated.selected, let i = options.firstIndex(where: { $0.id == selected.id }), i != 0 {
            options.swapAt(0, i)
        }
        let map = await MapSnapshot.make(takeoff: store.takeoffs[jobID] ?? Takeoff())
        return ProposalContent(company: store.settings.company, logo: store.logoImage, customer: store.customer(job.customerID),
                               job: job, options: options, proposalNumber: updated.proposalNumber, date: .now,
                               template: store.settings.proposal, map: map)
    }

    private func makePreview() async {
        working = true
        defer { working = false }
        guard let content = await proposalContent() else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "Proposal-preview-\(UUID().uuidString).pdf")
        do {
            try ProposalRenderer.render(content, to: url)
            preview = PreviewFile(url: url)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func emailProposal() async {
        working = true
        defer { working = false }
        guard let job, let content = await proposalContent(), let docs = store.docsFolder(job) else { return }
        let safeName = job.name.replacingOccurrences(of: "/", with: "-")
        let url = docs.appending(path: "Proposal \(content.proposalNumber) - \(safeName).pdf")
        do {
            try ProposalRenderer.render(content, to: url)
        } catch {
            errorText = error.localizedDescription
            return
        }
        let customer = store.customer(job.customerID)
        let greeting = customer?.contact.isEmpty == false ? customer!.contact : "there"
        let price = content.options.first.map { Fmt.dollars($0.breakdown.priceCents) } ?? ""
        Mailer.compose(
            to: customer?.email,
            subject: "Paving proposal for \(job.name)",
            body: "Hi \(greeting),\n\nAttached is our proposal for \(job.name)\(price.isEmpty ? "" : " (\(price))"). It's good for \(store.settings.proposal.validDays) days. Let me know if you have any questions or want to walk the site.\n\nThanks,\n\(store.settings.company.name)\n\(store.settings.company.phone)",
            attachments: [url])
        if job.stage != .sent && job.stage != .won && job.stage != .lost {
            store.setStage(jobID, .sent)
        } else if job.sentOn == nil {
            var updatedJob = job
            updatedJob.sentOn = .now
            store.jobBinding(jobID).wrappedValue = updatedJob
        }
    }
}

// MARK: - Line items

private struct LineItemsCard: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    let optionID: UUID

    private var option: EstimateOption {
        (store.estimates[jobID] ?? Estimate()).options.first { $0.id == optionID } ?? EstimateOption()
    }

    var body: some View {
        let current = option
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("ITEM").frame(maxWidth: .infinity, alignment: .leading)
                Text("QTY").frame(width: 76, alignment: .trailing)
                Text("UNIT").frame(width: 56, alignment: .leading)
                Text("UNIT COST").frame(width: 112, alignment: .trailing)
                Text("TOTAL").frame(width: 100, alignment: .trailing)
                Color.clear.frame(width: 22)
            }
            .font(.eyebrow).tracking(0.7).foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 16).padding(.vertical, 10)

            ForEach(groups(current), id: \.self) { group in
                HStack {
                    Text(group).font(.ui(13, weight: .bold))
                    Spacer()
                    Text(Fmt.dollars(current.subtotal(group: group))).font(.ui(13, weight: .bold)).monospacedDigit()
                    Color.clear.frame(width: 22)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Palette.surfaceSunk)
                .overlay(alignment: .top) { Hairline() }
                ForEach(current.items.filter { $0.group == group }) { item in
                    LineItemRow(item: itemBinding(item.id), highlighted: store.assistantHighlights.contains(item.id)) { remove(item.id) }
                        .overlay(alignment: .top) { Hairline() }
                }
            }
            HStack {
                Text("Total cost").font(.ui(13, weight: .bold))
                Spacer()
                Text(Fmt.dollars(current.breakdown.costCents)).font(.display(19)).monospacedDigit()
                Color.clear.frame(width: 22)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: 2) }

            HStack(spacing: 14) {
                Menu {
                    ForEach(Rates.groups, id: \.self) { group in
                        Section(group) {
                            ForEach(store.rates.prices.filter { $0.group == group }) { price in
                                Button("\(price.name) · \(Fmt.dollars(price.cents))/\(price.unit)") { add(price) }
                            }
                        }
                    }
                    Divider()
                    ForEach(EstimateOption.groups, id: \.self) { group in
                        Button("Blank line in \(group)") { addBlank(group) }
                    }
                } label: {
                    Label("Add line item", systemImage: "plus").font(.ui(12.5, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    let takeoff = store.takeoffs[jobID] ?? Takeoff()
                    setOption(Estimator.refresh(option, takeoff: takeoff, rates: store.rates))
                } label: {
                    Label("Update from measurements", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(LinkButtonStyle())
                .help("Recalculates the measured quantities. Your own lines and any unit costs you changed stay put.")
                Spacer()
                Text("Unit costs come from Settings & rates. Changing one here only affects this job.")
                    .font(.ui(11.5)).foregroundStyle(Palette.tertiary).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Palette.surfaceSunk)
            .overlay(alignment: .top) { Hairline() }
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
    }

    private func groups(_ option: EstimateOption) -> [String] {
        let present = Set(option.items.map(\.group))
        let ordered = EstimateOption.groups.filter { present.contains($0) }
        return ordered + present.subtracting(ordered).sorted()
    }

    private func setOption(_ new: EstimateOption) {
        var updated = store.estimates[jobID] ?? Estimate()
        guard let i = updated.options.firstIndex(where: { $0.id == optionID }) else { return }
        updated.options[i] = new
        store.estimateBinding(jobID).wrappedValue = updated
    }

    private func itemBinding(_ id: UUID) -> Binding<LineItem> {
        Binding(
            get: { option.items.first { $0.id == id } ?? LineItem() },
            set: { new in
                var updated = option
                guard let i = updated.items.firstIndex(where: { $0.id == id }) else { return }
                updated.items[i] = new
                setOption(updated)
            })
    }

    private func remove(_ id: UUID) {
        var updated = option
        updated.items.removeAll { $0.id == id }
        setOption(updated)
    }

    private func add(_ price: PriceItem) {
        var item = LineItem()
        item.name = price.name
        item.unit = price.unit
        item.unitCents = price.cents
        item.qty = 1
        switch price.group {
        case "Materials": item.group = "Materials"
        case "Trucking": item.group = "Trucking & general"
        case "Labor & equipment": item.group = price.id == "crewLabor" ? "Labor" : (price.id == "mobilization" ? "Trucking & general" : "Equipment & subs")
        default: item.group = "Equipment & subs"
        }
        var updated = option
        updated.items.append(item)
        setOption(updated)
    }

    private func addBlank(_ group: String) {
        var item = LineItem()
        item.group = group
        item.name = "New item"
        var updated = option
        updated.items.append(item)
        setOption(updated)
    }
}

private struct LineItemRow: View {
    @Binding var item: LineItem
    var highlighted = false
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Item", text: $item.name).textFieldStyle(.plain).font(.ui(13))
                if item.fromTakeoff {
                    Label("takeoff", systemImage: "link")
                        .font(.ui(10.5, weight: .semibold))
                        .foregroundStyle(Palette.amberInk)
                        .padding(.horizontal, 6).frame(height: 19)
                        .background(Palette.watchBg, in: RoundedRectangle(cornerRadius: 5))
                        .fixedSize()
                        .help("This quantity comes from your measurements.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Qty", value: $item.qty, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(.ui(13)).monospacedDigit()
                .frame(width: 76)
            TextField("Unit", text: $item.unit).textFieldStyle(.plain).font(.ui(13)).foregroundStyle(Palette.secondary)
                .frame(width: 56)
            MoneyInput(cents: $item.unitCents, label: "\(item.name) unit cost", width: 112)
            Text(Fmt.dollars(item.totalCents)).font(.ui(13, weight: .semibold)).monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(hovering ? Palette.noGoInk : Palette.control)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .help("Remove line")
            .accessibilityLabel("Remove \(item.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(highlighted ? Palette.accentWash : (hovering ? Color(hex: 0xFAFAF8) : .clear))
        .overlay { if highlighted { Rectangle().strokeBorder(Palette.accent, lineWidth: 1.5) } }
        .animation(.easeOut(duration: 0.25), value: highlighted)
        .onHover { hovering = $0 }
    }
}

// MARK: - Summary

private struct BidSummaryCard: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    let optionID: UUID

    private var option: EstimateOption {
        (store.estimates[jobID] ?? Estimate()).options.first { $0.id == optionID } ?? EstimateOption()
    }

    var body: some View {
        let current = option
        let b = current.breakdown
        let summary = store.summary(for: jobID)
        let perSY = summary.billableSY > 0 ? Double(b.priceCents) / 100 / summary.billableSY : nil
        let range = benchmark(title: current.title)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bid summary").font(.ui(15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text(current.title).font(.ui(12)).foregroundStyle(Palette.onDarkMuted)
            }
            .padding(.bottom, 10)
            darkRow("Cost", Fmt.dollars(b.costCents))
            HStack {
                Text("Overhead").foregroundStyle(Palette.onDarkMuted)
                TextField("Overhead", value: binding(\.overheadPct), format: .number)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 30)
                    .foregroundStyle(.white).monospacedDigit()
                Text("%").foregroundStyle(Palette.onDarkMuted)
                Spacer()
                Text(Fmt.dollars(b.overheadCents)).foregroundStyle(.white).monospacedDigit()
            }
            .font(.ui(13))
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.asphaltActive).frame(height: 1) }
            VStack(spacing: 8) {
                HStack {
                    (Text("Profit · ").foregroundColor(Palette.onDarkMuted) + Text("\(Int(current.profitPct))%").bold().foregroundColor(.white))
                    Spacer()
                    Text(Fmt.dollars(b.profitCents)).foregroundStyle(.white).monospacedDigit()
                }
                .font(.ui(13))
                Slider(value: binding(\.profitPct), in: 0...40, step: 1)
                    .tint(Palette.accent)
                    .accessibilityLabel("Profit percent")
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.asphaltActive).frame(height: 1) }

            Text("Bid price").font(.ui(12)).foregroundStyle(Palette.onDarkMuted).padding(.top, 16)
            Text(Fmt.dollars(b.priceCents)).font(.display(44)).foregroundStyle(Palette.accent).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            HStack(spacing: 10) {
                tile("Per SY", perSY.map { String(format: "$%.2f", $0) } ?? "—",
                     summary.billableSY > 0 ? "\(Fmt.number(summary.billableSY)) SY" : "No area measured")
                tile("Over cost", Fmt.dollars(b.overCostCents, showCents: false), String(format: "%.1f%% gross margin", b.marginPct))
            }
            .padding(.top, 12)
            if let range, let perSY {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Your last \(range.count) \(current.title.lowercased()) jobs").foregroundStyle(Palette.onDarkMuted)
                        Spacer()
                        Text(perSY < range.low ? "Below your usual" : (perSY > range.high ? "Above your usual" : "In your usual range"))
                            .fontWeight(.semibold).foregroundStyle(.white)
                    }
                    .font(.ui(12))
                    GeometryReader { proxy in
                        let lo = range.low * 0.85, hi = range.high * 1.15
                        let span = max(hi - lo, 0.01)
                        let x = { (v: Double) in proxy.size.width * CGFloat(min(max((v - lo) / span, 0), 1)) }
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(hex: 0x2E3035)).frame(height: 8)
                            Capsule().fill(Color(hex: 0x4A4C52)).frame(width: x(range.high) - x(range.low), height: 8).offset(x: x(range.low))
                            RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 4, height: 18).offset(x: x(perSY) - 2)
                        }
                    }
                    .frame(height: 18)
                    HStack {
                        Text(String(format: "$%.2f", range.low))
                        Spacer()
                        Text(String(format: "$%.2f", range.high))
                    }
                    .font(.ui(11.5)).foregroundStyle(Palette.onDarkMuted).monospacedDigit()
                }
                .padding(.top, 16)
            }
            Text("Good until \(Fmt.dayYear(Date.now.adding(days: store.settings.proposal.validDays)))\(store.settings.proposal.escalationClause ? " · escalation clause on" : "")")
                .font(.ui(12)).foregroundStyle(Palette.onDarkMuted)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Palette.asphaltActive).frame(height: 1).offset(y: 6) }
        }
        .padding(20)
        .background(Palette.asphalt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func darkRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.onDarkMuted)
            Spacer()
            Text(value).foregroundStyle(.white).monospacedDigit()
        }
        .font(.ui(13))
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.asphaltActive).frame(height: 1) }
    }

    private func tile(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.ui(11.5)).foregroundStyle(Palette.onDarkMuted)
            Text(value).font(.display(22)).foregroundStyle(.white).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.ui(11.5)).foregroundStyle(Palette.onDarkMuted).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.asphaltField, in: RoundedRectangle(cornerRadius: 10))
    }

    private func binding(_ key: WritableKeyPath<EstimateOption, Double>) -> Binding<Double> {
        Binding(
            get: { option[keyPath: key] },
            set: { value in
                var updated = store.estimates[jobID] ?? Estimate()
                guard let i = updated.options.firstIndex(where: { $0.id == optionID }) else { return }
                updated.options[i][keyPath: key] = value
                store.estimateBinding(jobID).wrappedValue = updated
            })
    }

    /// Price per SY on recent won jobs with the same kind of option.
    private func benchmark(title: String) -> (low: Double, high: Double, count: Int)? {
        let values = store.realJobs
            .filter { $0.id != jobID && $0.stage == .won }
            .sorted { $0.stageChanged > $1.stageChanged }
            .compactMap { job -> Double? in
                guard let option = store.estimates[job.id]?.selected, option.title.lowercased() == title.lowercased() else { return nil }
                let sy = store.summary(for: job.id).billableSY
                return sy > 0 ? Double(option.breakdown.priceCents) / 100 / sy : nil
            }
            .prefix(6)
        guard values.count >= 2, let low = values.min(), let high = values.max() else { return nil }
        return (low, high, values.count)
    }
}
