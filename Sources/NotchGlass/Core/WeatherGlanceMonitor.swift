import Foundation
import Combine
import CoreLocation

/// Keeps `WeatherManager.shared.current` fresh in the background so the collapsed
/// pill's resting Weather glance (`CollapsedResting.weather`) has a temperature to
/// show even when the Weather tab has never been opened. It owns its own
/// `LocationManager` (the same one the Weather/Map tabs use), asks for location once
/// when started (gated by the setting, like Battery/Fuel), and refetches on a coarse
/// location change or a slow 15-minute cadence — weather drifts over tens of minutes,
/// and `WeatherManager.load` de-dupes redundant fetches, so this is a light touch on
/// the keyless Open-Meteo endpoint. The pill reads `WeatherManager.shared` directly;
/// this just drives the refresh.
@MainActor
final class WeatherGlanceMonitor: ObservableObject {
    private let location = LocationManager()
    private var locationSink: AnyCancellable?
    private var timer: Timer?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        location.request()
        location.start()
        // Refetch when the fix moves more than the coarse (~1 km) key.
        locationSink = location.$location
            .compactMap { $0?.coordinate }
            .removeDuplicates { Self.coarse($0) == Self.coarse($1) }
            .sink { [weak self] coord in self?.refresh(coord) }
        // …and on a slow heartbeat so conditions update even while you stay put.
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let c = self?.location.location?.coordinate { self?.refresh(c) }
            }
        }
    }

    func stop() {
        running = false
        location.stop()
        locationSink?.cancel()
        locationSink = nil
        timer?.invalidate()
        timer = nil
        // Leaves the last-loaded `WeatherManager.current` cached — harmless, and the
        // Weather tab still uses it.
    }

    private func refresh(_ coord: CLLocationCoordinate2D) {
        // Match the Weather tab's persisted unit so the pill and tab agree.
        let fahrenheit = UserDefaults.standard.object(forKey: "weather.fahrenheit") as? Bool
            ?? (Locale.current.region?.identifier == "US")
        Task {
            await WeatherManager.shared.load(latitude: coord.latitude,
                                             longitude: coord.longitude,
                                             fahrenheit: fahrenheit)
        }
    }

    private static func coarse(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }
}
