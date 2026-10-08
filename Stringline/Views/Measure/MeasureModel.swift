import Foundation
import AppKit

/// Drawing state for one job's measure screen. Shapes themselves live in the store's takeoff.
@Observable @MainActor
final class MeasureModel {
    let jobID: UUID
    weak var store: AppStore?

    var tool: MeasureTool = .select
    var draft: [Coordinate] = []
    var selectedID: UUID?
    var areaType: WorkType = .millOverlay
    var lineType: WorkType = .striping
    var countKind: CountKind = .stall
    var flyTo: FlyTo?
    var message: String?

    @ObservationIgnored private var history: [Takeoff] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(jobID: UUID) { self.jobID = jobID }

    var takeoff: Takeoff { store?.takeoffs[jobID] ?? Takeoff() }
    var draftIsArea: Bool { tool == .area || tool == .cut }
    var canFinish: Bool { draftIsArea ? draft.count >= 3 : (tool == .line && draft.count >= 2) }

    var draftSummary: String? {
        guard !draft.isEmpty else { return nil }
        let n = draft.count
        let points = "\(n) point\(n == 1 ? "" : "s")"
        if draftIsArea, n >= 3 { return "\(points) · \(Fmt.number(Geo.areaSqFt(draft))) sq ft so far" }
        if tool == .line, n >= 2 { return "\(points) · \(Fmt.number(Geo.lengthFt(draft))) LF so far" }
        return points
    }

    private func commit(_ updated: Takeoff) {
        guard let store else { return }
        history.append(takeoff)
        if history.count > 60 { history.removeFirst() }
        store.takeoffBinding(jobID).wrappedValue = updated
    }

    func say(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Tools

    func setTool(_ newTool: MeasureTool) {
        tool = newTool
        draft = []
        if newTool != .select { selectedID = nil }
    }

    func click(_ coordinate: Coordinate) {
        switch tool {
        case .area, .line, .cut:
            draft.append(coordinate)
        case .count:
            var updated = takeoff
            var shape = TakeoffShape()
            shape.kind = .count
            shape.countKind = countKind
            shape.workType = .striping
            shape.points = [coordinate]
            shape.quantity = 1
            shape.name = countKind.label
            updated.shapes.append(shape)
            commit(updated)
        case .select:
            break
        }
    }

    func finish() {
        guard canFinish else { return }
        var updated = takeoff
        switch tool {
        case .area:
            var shape = TakeoffShape()
            shape.kind = .area
            shape.workType = areaType
            shape.depthInches = areaType.defaultDepth
            shape.points = draft
            shape.name = "Area \(updated.shapes.filter { $0.kind == .area }.count + 1)"
            updated.shapes.append(shape)
            commit(updated)
            selectedID = shape.id
            say("Added \(Fmt.number(Geo.areaSqFt(draft))) sq ft. Rename it on the right.")
        case .line:
            var shape = TakeoffShape()
            shape.kind = .line
            shape.workType = lineType
            shape.depthInches = 0
            shape.points = draft
            shape.name = "\(lineType.label) \(updated.shapes.filter { $0.kind == .line && $0.workType == lineType }.count + 1)"
            updated.shapes.append(shape)
            commit(updated)
            selectedID = shape.id
        case .cut:
            let center = Geo.centroid(draft)
            if let i = updated.shapes.firstIndex(where: { $0.kind == .area && Geo.contains($0.points, center) }) {
                updated.shapes[i].holes.append(draft)
                commit(updated)
                say("Cut \(Fmt.number(Geo.areaSqFt(draft))) sq ft out of \(updated.shapes[i].name).")
            } else {
                say("Draw the cut-out inside one of your areas.")
            }
        default:
            break
        }
        draft = []
    }

    func cancel() {
        if !draft.isEmpty { draft = [] } else { selectedID = nil }
    }

    func undo() {
        if !draft.isEmpty {
            draft.removeLast()
            return
        }
        guard let store, let previous = history.popLast() else { return }
        store.takeoffBinding(jobID).wrappedValue = previous
        if let id = selectedID, !previous.shapes.contains(where: { $0.id == id }) { selectedID = nil }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        var updated = takeoff
        updated.shapes.removeAll { $0.id == id }
        commit(updated)
        selectedID = nil
    }

    func removeCutOuts(_ id: UUID) {
        var updated = takeoff
        guard let i = updated.shapes.firstIndex(where: { $0.id == id }) else { return }
        updated.shapes[i].holes = []
        commit(updated)
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func moveVertex(_ shapeID: UUID, ring: Int, index: Int, to coordinate: Coordinate) {
        var updated = takeoff
        guard let i = updated.shapes.firstIndex(where: { $0.id == shapeID }) else { return }
        if ring == 0 {
            guard updated.shapes[i].points.indices.contains(index) else { return }
            updated.shapes[i].points[index] = coordinate
        } else {
            let hole = ring - 1
            guard updated.shapes[i].holes.indices.contains(hole), updated.shapes[i].holes[hole].indices.contains(index) else { return }
            updated.shapes[i].holes[hole][index] = coordinate
        }
        commit(updated)
    }

    func regionChanged(_ center: Coordinate, _ span: Double) {
        guard let store else { return }
        var updated = takeoff
        updated.center = center
        updated.spanMeters = span
        store.takeoffs[jobID] = updated
        store.markDirty(.takeoff(jobID))
    }

    // MARK: Estimate

    func sendToEstimate() {
        guard let store, let job = store.job(jobID) else { return }
        var estimate = store.estimates[jobID] ?? Estimate()
        let current = takeoff
        if estimate.options.isEmpty {
            let option = Estimator.option(title: Self.optionTitle(current), takeoff: current, rates: store.rates)
            estimate.options = [option]
            estimate.selectedOptionID = option.id
        } else if let selected = estimate.selected, let i = estimate.options.firstIndex(where: { $0.id == selected.id }) {
            estimate.options[i] = Estimator.refresh(selected, takeoff: current, rates: store.rates)
        }
        store.estimateBinding(jobID).wrappedValue = estimate
        if job.stage == .lead || job.stage == .siteVisit { store.setStage(jobID, .estimating) }
        store.jobTab = .estimate
    }

    static func optionTitle(_ takeoff: Takeoff) -> String {
        let types = Set(takeoff.shapes.map(\.workType))
        if types.contains(.millOverlay) { return "Mill & overlay" }
        if types.contains(.newPaving) { return "New paving" }
        if types.contains(.fullDepthPatch) { return "Patching" }
        if types.contains(.sealcoat) { return types.contains(.striping) ? "Sealcoat & stripe" : "Sealcoat" }
        if types.contains(.crackSeal) { return "Crack seal" }
        if types.contains(.striping) { return "Striping" }
        return "Option A"
    }

    // MARK: Keyboard

    func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
    }

    func removeKeys() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command && chars == "z" {
            undo()
            return true
        }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76:
            if canFinish { finish(); return true }
            return false
        case 53:
            if !draft.isEmpty || selectedID != nil { cancel(); return true }
            return false
        case 51, 117:
            if !draft.isEmpty { draft.removeLast(); return true }
            if selectedID != nil { deleteSelected(); return true }
            return false
        default:
            break
        }
        if let match = MeasureTool.allCases.first(where: { $0.key.lowercased() == chars }) {
            setTool(match)
            return true
        }
        return false
    }
}
