#if DEBUG
import AppKit

/// Address suggestions: typing in a real address field, picking a suggestion with the keyboard,
/// and the job ending up with the full address and its place on the map.
extension SelfTest {
    private static func textField(placeholder: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        for sub in view.subviews { if let found = textField(placeholder: placeholder, in: sub) { return found } }
        return nil
    }

    private static func type(_ text: String, in window: NSWindow) async {
        for character in text {
            key(String(character), 0, in: window)
            await pause(0.04)
        }
    }

    static func runAddressSuggestions(store: AppStore) async {
        lines.append("")
        lines.append("-- Address suggestions")
        let lot = PickedAddress(text: "2200 Maple Ridge Rd, Columbus, OH 43215", name: "2200 Maple Ridge Rd", coordinate: Coordinate(lat: 39.9871, lon: -82.9412))
        AddressCompleter.testPlaces = [lot, PickedAddress(text: "2210 Maple Ave, Zanesville, OH 43701", coordinate: Coordinate(lat: 39.94, lon: -82.01))]
        defer { AddressCompleter.testPlaces = nil }

        let completer = AddressCompleter()
        completer.update("2200 Maple")
        _ = await waitUntilSuggestions(completer)
        let first = completer.suggestions.first
        var resolved: PickedAddress?
        if let first { resolved = await completer.resolve(first) }
        check("Typing part of an address brings up suggestions, and a picked one comes back with its full address and place on the map",
              first?.title == "2200 Maple Ridge Rd" && resolved?.text == lot.text && resolved?.coordinate == lot.coordinate,
              completer.suggestions.map(\.completionText).joined(separator: " | "))
        completer.update("22")
        try? await Task.sleep(nanoseconds: 400_000_000)
        check("Fewer than three letters asks nothing", completer.suggestions.isEmpty)

        // The real thing: a job's address field on its Overview tab, typed into and picked from with the keyboard.
        guard #available(macOS 15, *) else {
            note("Suggestion lists need macOS 15; skipped the typing check")
            return
        }
        let job = store.createJob(name: "Suggestion test lot")
        store.openJob(job.id, tab: .overview)
        await pause(1.2)
        guard let window, let field = textField(placeholder: "Street, city", in: window.contentView) else {
            check("The job's address field is there to type in", false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        await pause(0.3)
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        await type("2200 Maple", in: window)
        // Wait for the suggestion list itself to be on screen before pressing ↓ (it's a small window of its own).
        let listShown = await waitUntil(5) { NSApp.windows.contains { !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible } }
        note("Suggestion list window: " + NSApp.windows.filter { !windowsBefore.contains(ObjectIdentifier($0)) }.map { String(describing: Swift.type(of: $0)) }.joined(separator: ", "))
        check("Suggestions appear under the field as you type", listShown)
        await pause(0.3)
        snapshot("address-suggestions")
        key("", 125, in: window)          // ↓ to the first suggestion
        await pause(0.3)
        key("\r", 36, in: window)         // Return picks it
        let placed = await waitUntil(4) { store.job(job.id)?.latitude != nil }
        await pause(1.5)   // long enough for a stray second lookup to land, if Return had started one
        let picked = store.job(job.id)
        check("Picking a suggestion with ↓ and Return fills in the full address and puts the job on the map",
              placed && picked?.address == lot.text && picked?.latitude == lot.coordinate?.lat && picked?.longitude == lot.coordinate?.lon
                && store.takeoffs[job.id]?.center == lot.coordinate,
              "address “\(picked?.address ?? "")”, on map \(placed) at \(picked?.latitude ?? 0), \(picked?.longitude ?? 0)")
        await pause(0.6)
        snapshot("address-picked")
        store.deleteJob(job.id)
        await pause(0.5)
    }

    private static func waitUntilSuggestions(_ completer: AddressCompleter) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while completer.suggestions.isEmpty, Date() < deadline { await pause(0.1) }
        return !completer.suggestions.isEmpty
    }

    /// Real Apple Maps suggestions for a real address (STRINGLINE_TEST_ONLY=liveaddress; needs internet).
    static func runLiveAddress() async {
        let completer = AddressCompleter()
        completer.configure(near: Coordinate(lat: 39.9612, lon: -82.9988), places: false)
        completer.update("4000 Easton Station")
        let found = await waitUntilSuggestions(completer)
        note("Apple's suggestions: " + completer.suggestions.map(\.completionText).joined(separator: " | "))
        var picked: PickedAddress?
        if let first = completer.suggestions.first { picked = await completer.resolve(first) }
        note("Picked: \(picked?.text ?? "nothing") at \(picked?.coordinate.map { "\($0.lat), \($0.lon)" } ?? "no location")")
        check("Apple Maps suggests real addresses as you type, and a pick comes back with its full address and location",
              found && picked?.coordinate != nil && (picked?.text.contains("Columbus") ?? false))
    }
}
#endif
