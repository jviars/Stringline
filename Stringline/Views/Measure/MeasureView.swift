import SwiftUI

private struct LookAroundTarget: Identifiable {
    let id = UUID()
    let coordinate: Coordinate
}

struct MeasureView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    @State private var model: MeasureModel
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false
    @State private var lookAround: LookAroundTarget?
    @State private var visibleCenter: Coordinate?

    init(jobID: UUID) {
        self.jobID = jobID
        _model = State(initialValue: MeasureModel(jobID: jobID))
    }

    private var job: Job? { store.job(jobID) }

    private var startCenter: Coordinate? {
        if let c = store.takeoffs[jobID]?.center { return c }
        if let job, let lat = job.latitude, let lon = job.longitude { return Coordinate(lat: lat, lon: lon) }
        if let lat = store.settings.company.homeLatitude, let lon = store.settings.company.homeLongitude { return Coordinate(lat: lat, lon: lon) }
        return nil
    }

    private var startSpan: Double {
        if let span = store.takeoffs[jobID]?.spanMeters { return span }
        if let job, job.latitude != nil { return 250 }
        return 3000
    }

    var body: some View {
        let takeoff = store.takeoffs[jobID] ?? Takeoff()
        HStack(alignment: .top, spacing: 16) {
            mapPanel(takeoff)
            ScrollView {
                inspector(takeoff)
            }
            .frame(width: 340)
        }
        .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 20))
        .onAppear {
            model.store = store
            model.installKeys()
        }
        .onDisappear { model.removeKeys() }
        // When the assistant draws, bring its drawing into view so the owner can check it.
        .onChange(of: store.assistantPreview[jobID] ?? []) { _, preview in showPreview(preview) }
        .task { showPreview(store.assistantPreview[jobID] ?? []) }
        .sheet(item: $lookAround) { target in LookAroundSheet(coordinate: target.coordinate) }
    }

    private func showPreview(_ preview: [TakeoffShape]) {
        let points = preview.flatMap(\.points)
        guard let minLat = points.map(\.lat).min(), let maxLat = points.map(\.lat).max(),
              let minLon = points.map(\.lon).min(), let maxLon = points.map(\.lon).max() else { return }
        let center = Coordinate(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
        let tall = (maxLat - minLat) * 111_320
        let wide = (maxLon - minLon) * 111_320 * cos(center.lat * .pi / 180)
        model.flyTo = FlyTo(center: center, spanMeters: max(max(tall, wide) * 1.5, 80))
    }

    // MARK: Map panel

    private func mapPanel(_ takeoff: Takeoff) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                FieldBox {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.tertiary)
                    TextField("Find an address or business", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { AddressCompleter.unlessPicked(search) }
                        .addressSuggestions($query, near: visibleCenter ?? startCenter, places: true) { picked in
                            if let place = picked.place { go(to: place) }
                        }
                    if searching { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: 340)
                Spacer()
                Picker("Imagery", selection: store.takeoffBinding(jobID).imagery) {
                    Text("Apple").tag(Imagery.apple)
                    Text("Esri").tag(Imagery.esri)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("Photos are taken on different dates. If one looks old, try the other.")
                .helpSpot("jobMeasure.imagery")
                Button {
                    if let center = visibleCenter ?? startCenter { lookAround = LookAroundTarget(coordinate: center) }
                } label: {
                    Label("Look Around", systemImage: "binoculars")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(startCenter == nil && visibleCenter == nil)
                .helpSpot("jobMeasure.lookAround")
            }
            .padding(10)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Hairline() }

            ZStack(alignment: .topLeading) {
                MapCanvas(
                    takeoff: takeoff,
                    draft: model.draft,
                    draftIsArea: model.draftIsArea,
                    selectedID: model.selectedID,
                    tool: model.tool,
                    startCenter: startCenter,
                    startSpan: startSpan,
                    flyTo: model.flyTo,
                    preview: store.assistantPreview[jobID] ?? [],
                    onClick: { model.click($0) },
                    onSelect: { model.select($0) },
                    onMoveVertex: { id, ring, index, coordinate in model.moveVertex(id, ring: ring, index: index, to: coordinate) },
                    onRegionChange: { center, span in
                        visibleCenter = center
                        model.regionChanged(center, span)
                    }
                )

                toolPalette
                    .helpSpot("jobMeasure.tools")
                    .padding(14)
                    .tourAnchor(.measure)

                Text(model.tool.hint)
                    .font(.ui(12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Palette.asphalt.opacity(0.9), in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .allowsHitTesting(false)

                if !results.isEmpty {
                    searchResults.padding(.leading, 14).padding(.top, 2)
                }

                if !(store.assistantPreview[jobID] ?? []).isEmpty {
                    Label("Dashed white: the assistant's drawing. Apply or discard it in the assistant panel.", systemImage: "sparkles")
                        .font(.ui(12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Palette.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 58)
                        .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Text(takeoff.imagery == .apple ? "Imagery: Apple Maps" : "Imagery: Esri, Maxar, Earthstar Geographics")
                            .font(.ui(11.5))
                            .foregroundStyle(Color(hex: 0xE6E7E9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Palette.asphalt.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    .padding(14)
                }
                .allowsHitTesting(false)

                VStack {
                    Spacer()
                    if let summary = model.draftSummary {
                        draftBar(summary)
                    } else if let message = model.message {
                        Text(message)
                            .font(.ui(12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Palette.asphalt.opacity(0.92), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 44)

                if startCenter == nil && takeoff.shapes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
                        Text("Search an address to start").font(.ui(15, weight: .bold))
                        Text("Type it in the box above, then zoom in on the lot.").font(.ui(13)).foregroundStyle(Palette.onDarkMuted)
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(Palette.asphalt.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
    }

    private var toolPalette: some View {
        VStack(spacing: 4) {
            ForEach(MeasureTool.allCases) { tool in
                let active = model.tool == tool
                Button {
                    model.setTool(tool)
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(active ? Palette.ink : Palette.sidebarText)
                        .background(active ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.label) (\(tool.key))")
                .accessibilityLabel(tool.label)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Rectangle().fill(Palette.asphaltRule).frame(width: 32, height: 1).padding(.vertical, 2)
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.sidebarText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Undo (⌘Z)")
            .accessibilityLabel("Undo")
        }
        .padding(6)
        .background(Palette.asphalt.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
        .fixedSize()
    }

    private func draftBar(_ summary: String) -> some View {
        HStack(spacing: 10) {
            Text(summary).font(.ui(13, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
            Button("Cancel") { model.cancel() }
                .buttonStyle(SmallButtonStyle())
            Button {
                model.finish()
            } label: {
                Text(model.tool == .line ? "Finish line" : (model.tool == .cut ? "Cut it out" : "Close shape"))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canFinish)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.asphalt.opacity(0.94), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(results) { result in
                Button {
                    query = result.name
                    go(to: result)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin").foregroundStyle(Palette.tertiary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(result.name).font(.ui(13, weight: .semibold)).foregroundStyle(Palette.ink)
                            if !result.detail.isEmpty { Text(result.detail).font(.ui(12)).foregroundStyle(Palette.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            Button("Close") { results = [] }
                .buttonStyle(LinkButtonStyle())
                .padding(10)
        }
        .frame(width: 340)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
        .padding(.leading, 70)
    }

    /// Flies the map to a place, and gives the job that location if it didn't have one.
    private func go(to result: PlaceResult) {
        results = []
        model.flyTo = FlyTo(center: result.coordinate, spanMeters: 260)
        if var job, job.latitude == nil {
            job.latitude = result.coordinate.lat
            job.longitude = result.coordinate.lon
            if job.address.isEmpty { job.address = result.detail.isEmpty ? result.name : result.detail }
            store.jobBinding(jobID).wrappedValue = job
        }
    }

    private func search() {
        searching = true
        Task {
            results = await Places.search(query, near: visibleCenter ?? startCenter)
            searching = false
            if results.isEmpty { model.say("Couldn't find “\(query)”. Try adding the city.") }
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ takeoff: Takeoff) -> some View {
        let summary = Estimator.summary(takeoff, factors: store.rates.factors)
        VStack(alignment: .leading, spacing: 14) {
            toolOptions
            if let id = model.selectedID, takeoff.shapes.contains(where: { $0.id == id }) {
                ShapeEditor(shape: shapeBinding(id), model: model)
            }
            takeoffCard(takeoff, summary: summary)
            if !summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    CardHeader(title: "Materials") {
                        Text("From your rates · \(Fmt.plain(store.rates.factors.wastePct))% waste").font(.ui(11.5)).foregroundStyle(Palette.tertiary)
                    }
                    .padding(.bottom, 4)
                    ForEach(Estimator.materials(summary, store.rates.factors)) { line in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.name).font(.ui(13))
                                Text(line.detail).font(.ui(11.5)).foregroundStyle(Palette.tertiary)
                            }
                            Spacer()
                            Text(line.amount).font(.ui(13, weight: .bold)).monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        .overlay(alignment: .top) { Hairline() }
                    }
                }
                .card(padding: 16)
            }
            Button {
                model.sendToEstimate()
            } label: {
                Label("Send to estimate", systemImage: "arrow.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .disabled(summary.isEmpty)
            .helpSpot("jobMeasure.send")
            Text("Satellite numbers are good for bidding. On big jobs, check them on site with a wheel.")
                .font(.ui(12)).foregroundStyle(Palette.tertiary)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch model.tool {
        case .area:
            optionCard(title: "New areas are") {
                FlowLayout(spacing: 6) {
                    ForEach(WorkType.areaTypes) { type in
                        typeChip(type.label, color: type.hex, on: model.areaType == type) { model.areaType = type }
                    }
                }
            }
        case .line:
            optionCard(title: "New lines are") {
                FlowLayout(spacing: 6) {
                    ForEach(WorkType.lineTypes) { type in
                        typeChip(type.label, color: type.hex, on: model.lineType == type) { model.lineType = type }
                    }
                }
            }
        case .count:
            optionCard(title: "Markers count") {
                FlowLayout(spacing: 6) {
                    ForEach(CountKind.allCases) { kind in
                        typeChip(kind.label, color: 0xFFFFFF, on: model.countKind == kind) { model.countKind = kind }
                    }
                }
                Text("Counting a whole row? Drop one marker and set how many it stands for.")
                    .font(.ui(12)).foregroundStyle(Palette.secondary)
            }
        case .cut:
            optionCard(title: "Cut out") {
                Text("Outline an island, building or anything else inside an area that you won't pave. It's subtracted automatically.")
                    .font(.ui(12.5)).foregroundStyle(Palette.secondary)
            }
        case .select:
            EmptyView()
        }
    }

    private func optionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(13, weight: .bold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accentWash, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xF2DFA0)))
    }

    private func typeChip(_ label: String, color: UInt32, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: color)).frame(width: 11, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.2)))
                Text(label).font(.ui(12.5, weight: .semibold))
            }
            .foregroundStyle(on ? .white : Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(on ? Palette.ink : Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Palette.ink : Palette.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func takeoffCard(_ takeoff: Takeoff, summary: TakeoffSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Takeoff") {
                Text("Saved to takeoff.json").font(.ui(11.5)).foregroundStyle(Palette.tertiary)
            }
            .padding(.bottom, 10)
            if takeoff.shapes.isEmpty {
                Text("Nothing measured yet. Pick Area (A) and click the corners of the lot, then press Return.")
                    .font(.ui(13)).foregroundStyle(Palette.secondary)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Hairline() }
            }
            ForEach(WorkType.allCases) { type in
                let shapes = takeoff.shapes.filter { $0.workType == type && $0.kind != .count }
                if !shapes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: type.hex))
                                .frame(width: type.isArea ? 12 : 14, height: type.isArea ? 12 : 4)
                            Text(type.isArea && type.hasDepth ? "\(type.label) · \(Fmt.plain(shapes[0].depthInches))\"" : type.label)
                                .font(.ui(13, weight: .bold))
                            Spacer()
                            Text(type.isArea ? "\(Fmt.number(summary.areaSqFt[type] ?? 0)) sq ft" : "\(Fmt.number(summary.lineFt[type] ?? 0)) LF")
                                .font(.ui(13, weight: .bold)).monospacedDigit()
                        }
                        ForEach(shapes) { shape in
                            let selected = model.selectedID == shape.id
                            Button {
                                model.setTool(.select)
                                model.select(shape.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(shape.name.isEmpty ? type.label : shape.name)
                                        .font(.ui(13, weight: selected ? .semibold : .regular))
                                    if !shape.holes.isEmpty {
                                        Text("\(shape.holes.count) cut out").font(.ui(11.5)).foregroundStyle(Palette.tertiary)
                                    }
                                    Spacer()
                                    Text(shape.kind == .area ? Fmt.number(Geo.netAreaSqFt(shape)) : Fmt.number(Geo.lengthFt(shape.points)))
                                        .font(.ui(13)).monospacedDigit()
                                }
                                .padding(.vertical, 6)
                                .padding(.leading, 20)
                                .padding(.trailing, 8)
                                .background(selected ? Color(hex: 0xFFF6D6) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if type.isArea {
                            Text("\(Fmt.number(summary.sy(type))) SY")
                                .font(.ui(12)).foregroundStyle(Palette.secondary).monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 8)
                        }
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
            if !summary.counts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Counts").font(.ui(13, weight: .bold))
                    HStack(spacing: 8) {
                        ForEach(CountKind.allCases.filter { (summary.counts[$0] ?? 0) > 0 }) { kind in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(summary.counts[kind] ?? 0)").font(.display(20)).monospacedDigit()
                                Text(kind.label).font(.ui(11.5)).foregroundStyle(Palette.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surfaceSunk, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .card(padding: 16)
    }

    private func shapeBinding(_ id: UUID) -> Binding<TakeoffShape> {
        Binding(
            get: { (store.takeoffs[jobID] ?? Takeoff()).shapes.first { $0.id == id } ?? TakeoffShape() },
            set: { new in
                var takeoff = store.takeoffs[jobID] ?? Takeoff()
                guard let i = takeoff.shapes.firstIndex(where: { $0.id == id }) else { return }
                takeoff.shapes[i] = new
                store.takeoffBinding(jobID).wrappedValue = takeoff
            })
    }
}

private struct ShapeEditor: View {
    @Binding var shape: TakeoffShape
    let model: MeasureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected").font(.eyebrow).tracking(0.9).foregroundStyle(Palette.tertiary)
                Spacer()
                Text(measurement).font(.ui(13, weight: .bold)).monospacedDigit()
            }
            TextBox(label: "Name", text: $shape.name, placeholder: "Main lot, entrance drive…")
            switch shape.kind {
            case .area:
                LabeledField(label: "Work") {
                    Picker("Work", selection: $shape.workType) {
                        ForEach(WorkType.areaTypes) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                if shape.workType.hasDepth {
                    NumberBox(label: "Depth", value: $shape.depthInches, unit: "inches", decimals: 1)
                }
                if !shape.holes.isEmpty {
                    HStack {
                        Text("\(shape.holes.count) cut-out\(shape.holes.count == 1 ? "" : "s") · \(Fmt.number(shape.holes.map(Geo.areaSqFt).reduce(0, +))) sq ft")
                            .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Button("Remove") { model.removeCutOuts(shape.id) }.buttonStyle(SmallButtonStyle())
                    }
                }
            case .line:
                LabeledField(label: "Work") {
                    Picker("Work", selection: $shape.workType) {
                        ForEach(WorkType.lineTypes) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            case .count:
                LabeledField(label: "Counts") {
                    Picker("Counts", selection: $shape.countKind) {
                        ForEach(CountKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                Stepper(value: $shape.quantity, in: 1...999) {
                    Text("Stands for \(shape.quantity)").font(.ui(13, weight: .semibold))
                }
            }
            Button(role: .destructive) {
                model.deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(SmallButtonStyle())
        }
        .card(padding: 16)
    }

    private var measurement: String {
        switch shape.kind {
        case .area: "\(Fmt.number(Geo.netAreaSqFt(shape))) sq ft"
        case .line: "\(Fmt.number(Geo.lengthFt(shape.points))) LF"
        case .count: "×\(shape.quantity)"
        }
    }
}
