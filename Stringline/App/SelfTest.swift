#if DEBUG
import SwiftUI
import AppKit
import MapKit
import PDFKit

/// End-to-end check of the real app, run with `-StringlineSelfTest`.
/// Uses a throwaway PavingData folder and never touches the real app's preferences.
@MainActor
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-StringlineSelfTest") }

    /// A store that keeps its history, backups and lock identity inside the test folder.
    static func makeStore() -> AppStore {
        // A stand-in iCloud Drive, so setup's iCloud choice never touches the real one.
        try? FileManager.default.createDirectory(at: fakeICloud, withIntermediateDirectories: true)
        AppStore.testICloudDrive = fakeICloud
        SafeFile.testSyncFolders = [fakeICloud.standardizedFileURL.path]
        return AppStore(isolated: true, localRoot: outputFolder.appending(path: "Local", directoryHint: .isDirectory),
                 machineID: "selftest-this-mac", machineName: "Test Mac")
    }
    static var outputFolder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["STRINGLINE_TEST_OUT"] ?? NSTemporaryDirectory().appending("StringlineSelfTest"), isDirectory: true)
    }

    static var lines: [String] = []
    private static var passed = 0
    private static var failed = 0
    static var shot = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        lines.append("[\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    static func note(_ text: String) { lines.append("       \(text)") }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
    }

    static func snapshot(_ name: String) {
        guard let view = window?.contentView else { return }
        shot += 1
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = outputFolder.appending(path: "screens", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: String(format: "%02d-%@.png", shot, name)))
    }

    private static func findMap(_ view: NSView?) -> MKMapView? {
        guard let view else { return nil }
        if let map = view as? MKMapView { return map }
        for sub in view.subviews { if let map = findMap(sub) { return map } }
        return nil
    }

    static func click(_ point: NSPoint, in window: NSWindow) {
        let time = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    static func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = [], in window: NSWindow) {
        if !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func clickMap(_ map: MKMapView, _ window: NSWindow, fx: CGFloat, fy: CGFloat) {
        let local = NSPoint(x: map.bounds.width * fx, y: map.bounds.height * fy)
        click(map.convert(local, to: nil), in: window)
    }

    static func json<T: Encodable>(_ value: T) -> Data { (try? JSONFile.encoder.encode(value)) ?? Data() }

    // MARK: - Run

    static func run(store: AppStore, assistant: Assistant) async {
        let fm = FileManager.default
        let out = outputFolder
        try? fm.removeItem(at: out.appending(path: "screens"))
        let folder = out.appending(path: "PavingData", directoryHint: .isDirectory)
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: out.appending(path: "Local"))
        try? fm.removeItem(at: out.appending(path: "PavingData copy"))
        lines = ["Stringline self-test · \(Date.now.formatted())", ""]
        if ProcessInfo.processInfo.environment["STRINGLINE_TEST_ONLY"] == "assistant" {
            await runAssistantOnly(store: store, assistant: assistant, folder: folder)
            return
        }
        if ProcessInfo.processInfo.environment["STRINGLINE_TEST_ONLY"] == "mappicture" {
            await saveMapPicture()
            finish(store)
            return
        }
        if ProcessInfo.processInfo.environment["STRINGLINE_TEST_ONLY"] == "liveaddress" {
            await runLiveAddress()
            finish(store)
            return
        }
        if ProcessInfo.processInfo.environment["STRINGLINE_TEST_ONLY"] == "address" {
            await runZohoOnly(store: store, folder: folder, then: { await runAddressSuggestions(store: store) })
            return
        }
        if ProcessInfo.processInfo.environment["STRINGLINE_TEST_ONLY"] == "zoho" {
            await runZohoOnly(store: store, folder: folder)
            return
        }
        if ProcessInfo.processInfo.environment["STRINGLINE_TEST_ONLY"] == "sync" {
            await runSyncOnly(store: store, folder: folder)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        await pause(2)
        window?.setContentSize(NSSize(width: 1440, height: 920))
        window?.makeKeyAndOrderFront(nil)
        await pause(1)

        // Onboarding screens
        check("App opens on the welcome screen when there's no data folder", store.needsOnboarding)
        snapshot("onboarding-welcome")
        await runStuckICloudSetup(store: store)
        for (step, name) in [(1, "company"), (2, "data-folder"), (3, "rates"), (4, "ready")] {
            store.onboardingStepRequest = step
            await pause(0.8)
            snapshot("onboarding-\(name)")
        }

        // Setup data, as onboarding does
        store.settings.company.name = "Test Paving Co"
        store.settings.company.phone = "555-0100"
        store.settings.company.email = "office@example.com"
        store.settings.company.address = "100 Test Way, Columbus, OH"
        store.settings.company.homeBase = "Columbus, OH"
        store.settings.company.homeLatitude = 39.9612
        store.settings.company.homeLongitude = -82.9988
        if let logo = ProcessInfo.processInfo.environment["STRINGLINE_TEST_LOGO"] {
            check("Logo can be added before the folder exists", store.setLogo(from: URL(fileURLWithPath: logo)))
        }
        do {
            try store.createDataFolder(at: folder)
            store.savePendingLogo()
            let expected = ["settings.json", "rates.json", "customers", "jobs", "backups", "logo.png"]
            let missing = expected.filter { !fm.fileExists(atPath: folder.appending(path: $0).path) }
            check("Create the PavingData folder", missing.isEmpty, missing.isEmpty ? folder.path : "missing \(missing)")
        } catch {
            check("Create the PavingData folder", false, error.localizedDescription)
        }
        store.settings.onboardingComplete = true
        store.markDirty(.settings)
        store.flush()
        await pause(1.2)
        check("Finishing setup opens the main app", !store.needsOnboarding)
        snapshot("today-first-day")

        // Weather (live network call)
        await store.weather.refresh(lat: 39.9612, lon: -82.9988, force: true)
        check("Forecast loads from Open-Meteo", store.weather.days.count >= 14, "\(store.weather.days.count) days\(store.weather.error.map { " · \($0)" } ?? "")")
        if let today = store.weather.forecast(for: .now) {
            let call = WeatherJudge.general(today, store.settings.weather)
            note("Today: \(Int(today.high))°/\(Int(today.low))°, \(today.rainChance)% rain → \(call.short)")
            check("Today's forecast has hourly temperatures", today.hourlyTemp.count == 24, "\(today.hourlyTemp.count) hours")
        }

        // Customer and job
        let customer = store.createCustomer(name: "Ridge Property Group")
        var c = customer
        c.contact = "Dana Whitfield"
        c.email = "dana@example.com"
        c.address = "2200 Maple Ridge Rd"
        store.customerBinding(customer.id).wrappedValue = c
        let job = store.createJob(name: "Maple Ridge Plaza", customerID: customer.id, address: "2200 Maple Ridge Rd, Columbus, OH",
                                  type: .commercial, services: [.millOverlay, .patching, .striping],
                                  coordinate: Coordinate(lat: 39.9612, lon: -82.9988))
        var takeoff = Takeoff()
        takeoff.center = Coordinate(lat: 39.9612, lon: -82.9988)
        takeoff.spanMeters = 250
        store.takeoffBinding(job.id).wrappedValue = takeoff
        store.flush()
        let jobDir = store.jobFolder(job)!
        let jobFiles = ["job.json", "takeoff.json", "estimate.json", "logs.json", "photos", "docs"].filter { !fm.fileExists(atPath: jobDir.appending(path: $0).path) }
        check("New job gets its own folder and files", jobFiles.isEmpty, jobFiles.isEmpty ? jobDir.lastPathComponent : "missing \(jobFiles)")
        check("Job numbers follow the year", job.number.hasPrefix("\(Calendar.current.component(.year, from: .now))-"), job.number)
        check("Customer saved as its own file", fm.fileExists(atPath: folder.appending(path: "customers/\(customer.id.uuidString).json").path))

        // Measure with real clicks and keys
        store.openJob(job.id, tab: .measure)
        await pause(3)
        guard let window, let map = findMap(window.contentView) else {
            check("Measure screen shows the map", false, "no MKMapView found")
            finish(store)
            return
        }
        check("Measure screen shows the map", true)
        window.makeKeyAndOrderFront(nil)
        let responder = window.firstResponder
        if responder is NSText { note("A text field had keyboard focus when Measure opened; clearing it like a click on the map would.") }
        window.makeFirstResponder(nil)

        key("a", 0, in: window)
        await pause(0.4)
        for (fx, fy) in [(0.30, 0.30), (0.70, 0.30), (0.70, 0.70), (0.30, 0.70)] {
            clickMap(map, window, fx: fx, fy: fy)
            await pause(0.35)
        }
        snapshot("measure-drawing")
        key("\r", 36, in: window)
        await pause(0.8)
        var t = store.takeoffs[job.id] ?? Takeoff()
        let gross = t.shapes.first.map { Geo.areaSqFt($0.points) } ?? 0
        check("Draw an area: A, click four corners, Return", t.shapes.count == 1 && t.shapes.first?.points.count == 4 && gross > 100,
              "\(t.shapes.count) shape(s), \(Fmt.number(gross)) sq ft")

        key("x", 7, in: window)
        await pause(0.4)
        for (fx, fy) in [(0.45, 0.45), (0.55, 0.45), (0.55, 0.55), (0.45, 0.55)] {
            clickMap(map, window, fx: fx, fy: fy)
            await pause(0.3)
        }
        key("\r", 36, in: window)
        await pause(0.8)
        t = store.takeoffs[job.id] ?? Takeoff()
        let net = t.shapes.first.map(Geo.netAreaSqFt) ?? 0
        check("Cut out an island: X, outline it, Return", t.shapes.first?.holes.count == 1 && net < gross && net > 0,
              "\(Fmt.number(gross)) → \(Fmt.number(net)) sq ft")

        key("l", 37, in: window)
        await pause(0.4)
        clickMap(map, window, fx: 0.25, fy: 0.85)
        await pause(0.3)
        clickMap(map, window, fx: 0.75, fy: 0.85)
        await pause(0.3)
        key("\r", 36, in: window)
        await pause(0.8)
        t = store.takeoffs[job.id] ?? Takeoff()
        let line = t.shapes.first { $0.kind == .line }
        check("Draw a striping line: L, two clicks, Return", line != nil && Geo.lengthFt(line!.points) > 10,
              line.map { "\(Fmt.number(Geo.lengthFt($0.points))) LF" } ?? "no line")

        key("c", 8, in: window)
        await pause(0.4)
        clickMap(map, window, fx: 0.5, fy: 0.2)
        await pause(0.8)
        t = store.takeoffs[job.id] ?? Takeoff()
        check("Drop a count marker: C, click", t.shapes.contains { $0.kind == .count }, "\(t.shapes.count) shapes")

        key("z", 6, .command, in: window)
        await pause(0.8)
        t = store.takeoffs[job.id] ?? Takeoff()
        check("⌘Z undoes the last change", !t.shapes.contains { $0.kind == .count }, "\(t.shapes.count) shapes")

        key("v", 9, in: window)
        await pause(0.4)
        clickMap(map, window, fx: 0.35, fy: 0.62)
        await pause(1.0)
        snapshot("measure-selected")

        func onMap(_ view: NSView) -> Bool {
            !view.isHidden && view.alphaValue > 0 && view.window != nil && map.bounds.intersects(view.convert(view.bounds, to: map))
        }
        let labels = map.annotations.compactMap { $0 as? LabelAnnotation }
        let shownLabels = labels.compactMap { map.view(for: $0) }.filter { onMap($0) && $0.image != nil }
        check("Shape labels show on the map", labels.count >= 2 && shownLabels.count == labels.count,
              "\(shownLabels.count) of \(labels.count) on screen: \(labels.map(\.text).joined(separator: ", "))")
        let vertices = map.annotations.compactMap { $0 as? VertexAnnotation }
        let shownVertices = vertices.compactMap { map.view(for: $0) }.filter { onMap($0) && $0 is VertexView }
        check("Clicking an area selects it and shows draggable corners", vertices.count == 8 && shownVertices.count == 8,
              "\(shownVertices.count) of \(vertices.count) corner handles on screen")
        if vertices.contains(where: { $0.ring == 0 && $0.index == 0 }) {
            let before = store.takeoffs[job.id]?.shapes.first { $0.kind == .area }?.points.first
            var after = before
            var tries = 0
            // Synthesized drags can miss the 12-point handle while the map is still settling, so try up to three times.
            while after == before && tries < 3 {
                tries += 1
                await pause(0.8)
                window.makeKeyAndOrderFront(nil)
                guard let corner = map.annotations.compactMap({ $0 as? VertexAnnotation }).first(where: { $0.ring == 0 && $0.index == 0 }),
                      let handle = map.view(for: corner) else { break }
                let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
                let time = ProcessInfo.processInfo.systemUptime
                func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                mouse(.leftMouseDown, start)
                for step in 1...10 { mouse(.leftMouseDragged, NSPoint(x: start.x - CGFloat(step) * 4, y: start.y + CGFloat(step) * 3)) }
                mouse(.leftMouseUp, NSPoint(x: start.x - 40, y: start.y + 30))
                await pause(1.2)
                after = store.takeoffs[job.id]?.shapes.first { $0.kind == .area }?.points.first
            }
            check("Dragging a corner reshapes the area", before != nil && after != nil && after != before,
                  before == after ? "corner didn't move after \(tries) tries" : "corner moved (try \(tries))")
        }

        // Name the shapes the way the owner would, then check the numbers
        if var current = store.takeoffs[job.id], let i = current.shapes.firstIndex(where: { $0.kind == .area }) {
            current.shapes[i].name = "Main lot"
            store.takeoffBinding(job.id).wrappedValue = current
        }
        await pause(0.5)
        snapshot("measure")

        // Send to estimate (the same model the button calls)
        let model = MeasureModel(jobID: job.id)
        model.store = store
        model.sendToEstimate()
        await pause(1.5)
        let estimate = store.estimates[job.id] ?? Estimate()
        let option = estimate.selected
        check("Send to estimate builds Option A from the takeoff", estimate.options.count == 1 && (option?.items.count ?? 0) >= 5,
              "\(option?.items.count ?? 0) lines, \(option.map { Fmt.dollars($0.breakdown.priceCents) } ?? "—")")
        check("Job moves to Estimating", store.job(job.id)?.stage == .estimating)
        check("Scope is written from the measurements", option?.scope.contains("Mill the existing asphalt") ?? false)
        snapshot("estimate")

        // Worked example from the design: 44,850 sq ft mill & overlay, 1,350 sq ft patch, 2,860 LF striping
        var summary = TakeoffSummary()
        summary.areaSqFt[.millOverlay] = 44_850
        summary.areaSqFt[.fullDepthPatch] = 1_350
        summary.lineFt[.striping] = 2_860
        summary.surfaceTons = 44_850.0 / 9 * 2 * 110 / 2000
        summary.baseTons = 1_350.0 / 9 * 4 * 110 / 2000
        var example = EstimateOption()
        example.items = Estimator.buildItems(summary, takeoff: Takeoff(), rates: Rates())
        let b = example.breakdown
        check("Estimate math matches the worked example", b.costCents == 7_554_995 && b.priceCents == 9_557_069,
              "cost \(Fmt.dollars(b.costCents)), price \(Fmt.dollars(b.priceCents))")

        // Refresh keeps the owner's edits
        if var edited = store.estimates[job.id], var opt = edited.selected, let i = edited.options.firstIndex(where: { $0.id == opt.id }) {
            if let mix = opt.items.firstIndex(where: { $0.key == "surfaceMix" }) { opt.items[mix].unitCents = 8100 }
            var manual = LineItem(); manual.name = "Traffic control"; manual.group = "Trucking & general"; manual.qty = 1; manual.unitCents = 50000
            opt.items.append(manual)
            edited.options[i] = Estimator.refresh(opt, takeoff: store.takeoffs[job.id] ?? Takeoff(), rates: store.rates)
            let refreshed = edited.options[i]
            check("Update from measurements keeps changed prices and added lines",
                  refreshed.items.first { $0.key == "surfaceMix" }?.unitCents == 8100 && refreshed.items.contains { $0.name == "Traffic control" })
            store.estimateBinding(job.id).wrappedValue = edited
        }

        // Proposal PDF
        if let current = store.job(job.id), let est = store.estimates[job.id], let docs = store.docsFolder(current) {
            let snapshotImage = await MapSnapshot.make(takeoff: store.takeoffs[job.id] ?? Takeoff())
            check("Satellite snapshot for the proposal", snapshotImage != nil)
            let number = store.nextProposalNumber()
            let content = ProposalContent(company: store.settings.company, logo: store.logoImage, customer: store.customer(current.customerID),
                                          job: current, options: est.options, proposalNumber: number, date: .now,
                                          template: store.settings.proposal, map: snapshotImage)
            let url = docs.appending(path: "Proposal \(number) - \(current.name).pdf")
            do {
                try ProposalRenderer.render(content, to: url)
                let doc = PDFDocument(url: url)
                let text = doc?.string ?? ""
                let price = Fmt.dollars(est.options[0].breakdown.priceCents)
                check("Proposal PDF has two pages with the job, customer and price",
                      doc?.pageCount == 2 && text.contains("Maple Ridge Plaza") && text.contains("Ridge Property Group") && text.contains(price),
                      "\(doc?.pageCount ?? 0) pages, \(price)")
                savePages(doc, prefix: "proposal")
            } catch {
                check("Proposal PDF renders", false, error.localizedDescription)
            }
        }

        // Pipeline and follow-ups
        store.setStage(job.id, .sent)
        check("Moving to Sent records the date", store.job(job.id)?.sentOn != nil)
        var sentJob = store.job(job.id)!
        sentJob.sentOn = Date.now.adding(days: -8)
        store.jobBinding(job.id).wrappedValue = sentJob
        check("A bid quiet for a week shows a follow-up", Attention.items(store).contains { $0.kind == .followUp })
        let lead = store.createJob(name: "Hillcrest Apartments", type: .commercial, services: [.sealcoat, .striping])
        _ = store.createJob(name: "Riverbend Elementary", type: .publicBid, services: [.millOverlay])
        store.selection = .pipeline
        await pause(1.5)
        snapshot("pipeline")

        // Won, scheduled, weather conflicts, 811
        store.setStage(job.id, .won)
        var won = store.job(job.id)!
        let crewA = store.settings.crews.first?.id
        let today = Date().startOfDay
        won.schedule = [ScheduleEntry(day: today, crewID: crewA, startTime: "7:00 AM", note: "Mill day"),
                        ScheduleEntry(day: today.adding(days: 1), crewID: crewA, startTime: "7:00 AM", note: "Pave day")]
        won.ticket.number = "2610-04417"
        won.ticket.goodUntil = today.adding(days: 1)
        won.plantNote = "310 tn surface confirmed"
        store.jobBinding(job.id).wrappedValue = won
        var sealJob = store.job(lead.id)!
        sealJob.stage = .won
        sealJob.schedule = [ScheduleEntry(day: today.adding(days: 1), crewID: store.settings.crews.dropFirst().first?.id, startTime: "8:00 AM")]
        sealJob.ticket.notNeeded = true
        store.jobBinding(lead.id).wrappedValue = sealJob

        let realDays = store.weather.days
        if let tomorrow = store.weather.forecast(for: today.adding(days: 1)) {
            let rainy = DayForecast(day: tomorrow.day, high: tomorrow.high, low: tomorrow.low, rainChance: 80, code: 63,
                                    hourlyTemp: tomorrow.hourlyTemp, hourlyRain: tomorrow.hourlyRain)
            store.weather.days = realDays.map { $0.day == rainy.day ? rainy : $0 }
        }
        let attention = Attention.items(store)
        check("Rain on a booked job day is flagged", attention.contains { $0.kind == .rain }, attention.map(\.title).joined(separator: " | "))
        check("An 811 ticket expiring tomorrow is flagged", attention.contains { $0.kind == .ticket && $0.title.contains("tomorrow") })
        let items = store.realJobs.flatMap { j in j.schedule.map { (job: j, entry: $0, crew: store.crew($0.crewID)) } }
        let ics = CalendarExport.ics(items)
        check("Calendar export has one event per crew day", ics.components(separatedBy: "BEGIN:VEVENT").count - 1 == 3)
        store.selection = .schedule
        await pause(1.5)
        snapshot("schedule")
        store.selection = .today
        await pause(1.2)
        snapshot("today")

        // Invoice
        store.createInvoice(for: job.id)
        var invoice = store.invoices[job.id]
        check("Invoice gets the next number and the bid price", invoice?.number == "1001" && invoice?.amountCents == store.priceCents(for: job.id),
              "\(invoice?.number ?? "—") · \(invoice.map { Fmt.dollars($0.amountCents) } ?? "—")")
        invoice?.issued = today.adding(days: -45)
        invoice?.depositCents = 500_000
        store.invoiceBinding(job.id).wrappedValue = invoice
        check("A late invoice is flagged", Attention.items(store).contains { $0.kind == .invoice })
        if let invoice, let current = store.job(job.id), let docs = store.docsFolder(current) {
            let url = docs.appending(path: "Invoice \(invoice.number).pdf")
            do {
                try InvoicePDF.render(InvoicePage(company: store.settings.company, logo: store.logoImage, customer: store.customer(current.customerID),
                                                  job: current, invoice: invoice, lines: ["Mill & overlay"]), to: url)
                let doc = PDFDocument(url: url)
                check("Invoice PDF shows the balance", doc?.pageCount == 1 && (doc?.string ?? "").contains(Fmt.dollars(invoice.balanceCents)),
                      Fmt.dollars(invoice.balanceCents))
                savePages(doc, prefix: "invoice")
            } catch {
                check("Invoice PDF renders", false, error.localizedDescription)
            }
        }
        store.selection = .invoices
        await pause(1.2)
        snapshot("invoices")
        store.openJob(job.id, tab: .invoice)
        await pause(1)
        snapshot("job-invoice")

        // Logs and photos
        var logs = store.logs[job.id] ?? JobLogs()
        logs.entries = [DailyLog(day: today, crewID: crewA, tons: 296, hours: 70, weather: "Sunny, 64°", notes: "Milled main lot")]
        store.logsBinding(job.id).wrappedValue = logs
        store.openJob(job.id, tab: .logs)
        await pause(1)
        snapshot("job-logs")
        if let logo = ProcessInfo.processInfo.environment["STRINGLINE_TEST_LOGO"], let photos = store.photosFolder(store.job(job.id)!) {
            try? fm.copyItem(at: URL(fileURLWithPath: logo), to: photos.appending(path: "before.png"))
        }
        store.openJob(job.id, tab: .photos)
        await pause(1.5)
        snapshot("job-photos")
        store.openJob(job.id, tab: .schedule)
        await pause(1)
        snapshot("job-schedule")
        store.openJob(job.id, tab: .overview)
        await pause(1)
        snapshot("job-overview")

        // Other screens
        for (item, name) in [(SidebarItem.jobs, "jobs"), (.customers, "customers"), (.measure, "measure-home"),
                             (.settings, "settings-rates"), (.crew, "settings-crews"), (.learn, "learn"), (.equipment, "equipment")] {
            store.selection = item
            await pause(1.2)
            snapshot(name)
            if name == "learn" || name == "settings-rates" { dumpScrollViews(name) }
        }
        store.selection = .today
        await pause(1.2)
        dumpScrollViews("today")

        // AI assistant, against a pretend OpenAI on this Mac
        await runAssistant(store: store, assistant: assistant, jobID: job.id)

        // Practice job
        let practice = store.ensurePracticeJob()
        var practiceTakeoff = store.takeoffs[practice.id] ?? Takeoff()
        var square = TakeoffShape()
        square.points = [Coordinate(lat: 39.96, lon: -83.0), Coordinate(lat: 39.96, lon: -82.999), Coordinate(lat: 39.961, lon: -82.999)]
        practiceTakeoff.shapes = [square]
        store.takeoffBinding(practice.id).wrappedValue = practiceTakeoff
        store.resetPracticeJob()
        check("Practice job resets to empty", store.practiceJob.map { store.takeoffs[$0.id]?.shapes.isEmpty ?? false } ?? false
              && store.realJobs.count == 3)

        // Tour
        store.startTour()
        for stop in TourStop.allCases {
            store.goTo(stop)
            await pause(1.6)
            snapshot("tour-\(stop.number)")
            if stop == .estimate, let practice = store.practiceJob {
                check("Tour's estimate stop has a sample estimate to show", !(store.estimates[practice.id]?.selected?.items.isEmpty ?? true))
            }
        }
        store.endTour(completed: true)
        check("Finishing the tour is remembered", store.settings.tourCompleted)
        store.weather.days = realDays

        // Backup
        store.flush()
        do {
            let zip = try Backup.make(of: folder)
            let listing = Process()
            listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            listing.arguments = ["-l", zip.path]
            let pipe = Pipe()
            listing.standardOutput = pipe
            try listing.run()
            listing.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            check("Backup zip holds the job files", text.contains("job.json") && text.contains("estimate.json") && !text.contains(".png"),
                  zip.lastPathComponent)
        } catch {
            check("Backup zip", false, error.localizedDescription)
        }

        // Reload everything from disk
        store.flush()
        let reloaded = makeStore()
        reloaded.openFolder(folder)
        let sortJobs = { (list: [Job]) in list.sorted { $0.id.uuidString < $1.id.uuidString } }
        let sameJobs = json(sortJobs(reloaded.jobs)) == json(sortJobs(store.jobs))
        let sameTakeoffs = store.jobs.allSatisfy { json(reloaded.takeoffs[$0.id]) == json(store.takeoffs[$0.id]) }
        let sameEstimates = store.jobs.allSatisfy { json(reloaded.estimates[$0.id]) == json(store.estimates[$0.id]) }
        let sameInvoices = store.jobs.allSatisfy { json(reloaded.invoices[$0.id]) == json(store.invoices[$0.id]) }
        let sameLogs = store.jobs.allSatisfy { json(reloaded.logs[$0.id]) == json(store.logs[$0.id]) }
        let sameRest = json(reloaded.customers) == json(store.customers) && json(reloaded.rates) == json(store.rates)
            && json(reloaded.settings) == json(store.settings) && reloaded.logoImage != nil
        check("Quit and reopen: every job, takeoff, estimate, invoice and log comes back the same",
              sameJobs && sameTakeoffs && sameEstimates && sameInvoices && sameLogs && sameRest,
              "jobs \(sameJobs) takeoffs \(sameTakeoffs) estimates \(sameEstimates) invoices \(sameInvoices) logs \(sameLogs) other \(sameRest)")
        reloaded.closeFolder(releaseLock: false)

        // Files from an older version still open
        let old = out.appending(path: "old-settings.json")
        try? Data(#"{"schemaVersion":1,"company":{"name":"Old Co"},"onboardingComplete":true}"#.utf8).write(to: old)
        let merged = JSONFile.read(AppSettings.self, from: old)
        check("Older files with missing fields still open", merged?.company.name == "Old Co" && merged?.crews.count == 2 && merged?.weather.pavingMinF == 50)

        await runSafety(store: store, folder: folder)
        await runStuckSync(store: store, folder: folder)
        await runZohoImport(store: store)
        await runAddressSuggestions(store: store)
        finish(store)
    }

    /// Writes every scroll view's geometry, to tell real layout problems from capture artifacts.
    private static func dumpScrollViews(_ name: String) {
        guard let root = window?.contentView else { return }
        var out: [String] = ["== \(name) · window content \(root.frame.size)"]
        func walk(_ view: NSView, depth: Int) {
            if let scroll = view as? NSScrollView {
                let doc = scroll.documentView
                out.append("\(String(repeating: "  ", count: depth))NSScrollView frame=\(scroll.frame) visible=\(scroll.documentVisibleRect) doc=\(doc.map { "\(type(of: $0)) \($0.frame)" } ?? "nil") insets=\(scroll.contentInsets) layer=\(scroll.wantsLayer)")
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(root, depth: 0)
        let url = outputFolder.appending(path: "scrollviews.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + out.joined(separator: "\n") + "\n\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func savePages(_ doc: PDFDocument?, prefix: String) {
        guard let doc else { return }
        let folder = outputFolder.appending(path: "screens", directoryHint: .isDirectory)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let image = page.thumbnail(of: NSSize(width: 918, height: 1188), for: .mediaBox)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(prefix)-page\(i + 1).png"))
            }
        }
    }

    static func finish(_ store: AppStore) {
        store.flush()
        lines.append("")
        lines.append("\(passed) passed, \(failed) failed")
        let report = lines.joined(separator: "\n")
        try? report.write(to: outputFolder.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
#endif
