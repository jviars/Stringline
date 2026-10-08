import SwiftUI
import MapKit

/// A place picked from the suggestions: the full address, written out, and where it is.
struct PickedAddress: Hashable {
    var text: String
    var name: String?
    var coordinate: Coordinate?

    /// As a search result, for the screens that list those.
    var place: PlaceResult? {
        coordinate.map { PlaceResult(name: name ?? text, detail: text, coordinate: $0) }
    }
}

/// As-you-type address suggestions from Apple Maps (MKLocalSearchCompleter), the same ones Maps shows.
/// No account and no key: typing goes to Apple only, and without internet the field simply stays a text field.
@Observable @MainActor
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Hashable {
        let title: String
        let subtitle: String
        var id: String { completionText }
        /// What the field shows once it's picked, before the full address comes back.
        var completionText: String { subtitle.isEmpty ? title : "\(title), \(subtitle)" }
    }

    private(set) var suggestions: [Suggestion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [String: MKLocalSearchCompletion] = [:]
    @ObservationIgnored private var pause: Task<Void, Never>?

    #if DEBUG
    /// The self-test's stand-in for Apple Maps.
    static var testPlaces: [PickedAddress]?
    #endif

    /// When a suggestion was last picked. Return both picks a suggestion and submits the field,
    /// so a field's own Return action goes through `unlessPicked` and stands down after a pick.
    static var lastPick = Date.distantPast

    static func unlessPicked(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Date().timeIntervalSince(lastPick) > 1 { action() }
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    /// Addresses only, or businesses and landmarks too. Suggestions lean toward `near` (usually the home base).
    func configure(near: Coordinate?, places: Bool) {
        completer.resultTypes = places ? [.address, .pointOfInterest] : .address
        if let near {
            completer.region = MKCoordinateRegion(center: Geo.cl(near), latitudinalMeters: 160_000, longitudinalMeters: 160_000)
        }
    }

    /// Asks Apple after a short pause in typing, so it isn't asked on every keystroke.
    func update(_ text: String) {
        pause?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            clear()
            return
        }
        pause = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            #if DEBUG
            if let places = Self.testPlaces {
                self.suggestions = places.filter { $0.text.localizedCaseInsensitiveContains(query) }.prefix(6).map { place in
                    let parts = place.text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return Suggestion(title: parts.first ?? place.text, subtitle: parts.count > 1 ? parts[1] : "")
                }
                return
            }
            #endif
            self.completer.queryFragment = query
        }
    }

    func clear() {
        pause?.cancel()
        suggestions = []
        completions = [:]
    }

    /// The full address and map location for a suggestion.
    func resolve(_ suggestion: Suggestion) async -> PickedAddress? {
        #if DEBUG
        if let places = Self.testPlaces {
            return places.first { $0.text.localizedCaseInsensitiveContains(suggestion.title) }
        }
        #endif
        guard let completion = completions[suggestion.id] else { return nil }
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first else {
            return PickedAddress(text: suggestion.completionText)
        }
        return PickedAddress(text: Self.format(item, fallback: suggestion.completionText), name: item.name, coordinate: Geo.coord(item.placemark.coordinate))
    }

    /// One line, the way an address is written on a proposal: "2200 Maple Ridge Rd, Columbus, OH 43215".
    /// A business keeps its name in front.
    static func format(_ item: MKMapItem, fallback: String) -> String {
        let mark = item.placemark
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let region = [mark.administrativeArea, mark.postalCode].compactMap { $0 }.joined(separator: " ")
        let parts = [street, mark.locality ?? "", region].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return fallback }
        if let name = item.name, !name.isEmpty, item.pointOfInterestCategory != nil, name != street {
            return ([name] + parts).joined(separator: ", ")
        }
        return parts.joined(separator: ", ")
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            var found: [Suggestion] = []
            var map: [String: MKLocalSearchCompletion] = [:]
            for result in completer.results.prefix(6) {
                let suggestion = Suggestion(title: result.title, subtitle: result.subtitle)
                guard map[suggestion.id] == nil else { continue }
                found.append(suggestion)
                map[suggestion.id] = result
            }
            suggestions = found
            completions = map
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}

extension View {
    /// Apple Maps suggestions under an address field as you type (macOS 15 and later; a plain field before that).
    /// Picking one fills in the full address and hands back where it is.
    func addressSuggestions(_ text: Binding<String>, near: Coordinate? = nil, places: Bool = false, enabled: Bool = true,
                            onPick: @escaping (PickedAddress) -> Void = { _ in }) -> some View {
        modifier(AddressSuggestions(text: text, near: near, places: places, enabled: enabled, onPick: onPick))
    }
}

struct AddressSuggestions: ViewModifier {
    @Binding var text: String
    let near: Coordinate?
    let places: Bool
    let enabled: Bool
    let onPick: (PickedAddress) -> Void
    @Environment(AppStore.self) private var store: AppStore?
    @State private var completer = AddressCompleter()
    @State private var settled: String?
    @FocusState private var focused: Bool

    /// Where suggestions should lean: the place given, or the home base.
    private var center: Coordinate? {
        near ?? store.flatMap { s in s.settings.company.homeLatitude.flatMap { lat in s.settings.company.homeLongitude.map { Coordinate(lat: lat, lon: $0) } } }
    }

    func body(content: Content) -> some View {
        if enabled {
            if #available(macOS 15, *) {
                suggesting(content)
            } else {
                content
            }
        } else {
            content
        }
    }

    @available(macOS 15, *)
    private func suggesting(_ content: Content) -> some View {
        content
            .focused($focused)
            .textInputSuggestions {
                ForEach(completer.suggestions) { suggestion in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title)
                            if !suggestion.subtitle.isEmpty { Text(suggestion.subtitle).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: "mappin.circle")
                    }
                    .textInputCompletion(suggestion.completionText)
                }
            }
            .onAppear { completer.configure(near: center, places: places) }
            .onChange(of: text) { _, new in changed(new) }
            .onChange(of: focused) { _, isFocused in if !isFocused { completer.clear() } }
    }

    private func changed(_ new: String) {
        if let suggestion = completer.suggestions.first(where: { $0.completionText == new }) {
            // Picked from the list: fetch the full address and where it is.
            AddressCompleter.lastPick = Date()
            completer.clear()
            Task {
                guard let picked = await completer.resolve(suggestion) else { return }
                if text == new, picked.text != new {
                    settled = picked.text
                    text = picked.text
                }
                onPick(picked)
            }
            return
        }
        if new == settled { return }
        settled = nil
        if focused { completer.update(new) }
    }
}
