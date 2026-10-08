import Foundation
import MapKit
import CoreLocation
import AppKit

struct PlaceResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let detail: String
    let coordinate: Coordinate
}

/// Address search through Apple Maps. No API key needed.
enum Places {
    static func search(_ text: String, near: Coordinate? = nil) async -> [PlaceResult] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let near {
            request.region = MKCoordinateRegion(center: Geo.cl(near), latitudinalMeters: 120_000, longitudinalMeters: 120_000)
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.prefix(6).map { item in
            let mark = item.placemark
            let detail = [mark.thoroughfare.map { "\(mark.subThoroughfare.map { "\($0) " } ?? "")\($0)" }, mark.locality, mark.administrativeArea]
                .compactMap { $0 }.joined(separator: ", ")
            return PlaceResult(name: item.name ?? query, detail: detail, coordinate: Geo.coord(mark.coordinate))
        }
    }

    static func townName(for location: CLLocation) async -> String? {
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return [mark.locality, mark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One-shot location for "Use this Mac's location".
@MainActor
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func fetch() async throws -> CLLocation {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.continuation?.resume(returning: location)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

enum FilePicker {
    @MainActor
    static func chooseFolder(title: String, prompt: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseImages(multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.urls : []
    }
}
