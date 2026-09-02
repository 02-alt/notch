import SwiftUI
import CoreLocation

/// A live local-weather tab. The left column is a hero readout — a big current
/// temperature under a colour weather glyph, the condition, where you are and the
/// day's high/low — while the right column stacks the next twelve hours (a
/// horizontal strip of icon + temp) over a several-day forecast (weekday, icon,
/// rain chance and hi/lo) and a small grid of the details that don't fit the hero
/// (feels-like, humidity, wind, UV).
///
/// Data comes from Open-Meteo, a free keyless forecast API. Only the coarse
/// coordinate is sent — no account, no tracking id — matching the app's habit of
/// not handing the user's data to more third parties than a feature needs. Location
/// is requested lazily; the tab shows a friendly prompt until it's granted.
struct WeatherTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var location = LocationManager()
    @ObservedObject private var weather = WeatherManager.shared

    /// Persisted so the tab reopens in the units you left it. Seeded from the
    /// region so a US install starts in Fahrenheit and everyone else in Celsius.
    @AppStorage("weather.fahrenheit") private var fahrenheit = WeatherTabView.defaultFahrenheit

    /// Persisted so the tab reopens on whichever face you left it.
    @AppStorage("weather.mode") private var modeRaw = WeatherMode.forecast.rawValue

    private var mode: WeatherMode {
        get { WeatherMode(rawValue: modeRaw) ?? .forecast }
        nonmutating set { modeRaw = newValue.rawValue }
    }

    /// Bumped by the refresh button to force the city board to re-fetch every tile.
    @State private var refreshNonce = 0

    /// Region default: Fahrenheit only where it's the everyday unit (chiefly the US).
    static let defaultFahrenheit = (Locale.current.region?.identifier == "US")

    /// Coarse location key (~1 km) so we only refetch when you've actually moved.
    private var coarseKey: String {
        guard let c = location.location?.coordinate else { return "none" }
        return String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    var body: some View {
        Group {
            if location.authorization == .denied || location.authorization == .restricted {
                deniedPrompt
            } else if let current = weather.current {
                forecast(current)
            } else if weather.errorText != nil && location.location != nil {
                errorState
            } else {
                loadingState
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            location.request()
            location.start()
        }
        .onDisappear { location.stop() }
        // Fetch whenever the fix meaningfully changes, and re-fetch on unit change.
        .task(id: coarseKey) { await refresh() }
        .onChange(of: fahrenheit) { _, _ in Task { await refresh(force: true) } }
    }

    private func refresh(force: Bool = false) async {
        guard let c = location.location?.coordinate else { return }
        await weather.load(latitude: c.latitude, longitude: c.longitude,
                           fahrenheit: fahrenheit, force: force)
    }

    // MARK: - Forecast

    private func forecast(_ current: CurrentWeather) -> some View {
        VStack(spacing: Spacing.md) {
            header
            modePills
            Group {
                switch mode {
                case .forecast: forecastPane(current)
                case .sunMoon:  sunMoonPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func forecastPane(_ current: CurrentWeather) -> some View {
        WeatherBoardView(fahrenheit: fahrenheit,
                         currentCoord: location.location?.coordinate,
                         refreshNonce: refreshNonce)
    }

    /// The Forecast / Sun & Moon switcher.
    private var modePills: some View {
        HStack(spacing: Spacing.s) {
            ForEach(WeatherMode.allCases) { m in
                let on = mode == m
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = m } } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: m.symbol).font(.system(size: 10, weight: .semibold))
                        Text(m.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(on ? settings.accent.readableForeground : Theme.secondaryText)
                    .padding(.horizontal, Spacing.base)
                    .frame(height: 24)
                    .background {
                        Capsule(style: .continuous)
                            .fill(on ? settings.accent : Color.white.opacity(0.08))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.04)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Sun & Moon

    /// The sun's path, the golden hour and the moon — all computed locally from the
    /// coordinate (no network). Recomputed each minute so the "now" markers glide.
    @ViewBuilder
    private var sunMoonPane: some View {
        if let lat = weather.latitude ?? location.location?.coordinate.latitude,
           let lon = weather.longitude ?? location.location?.coordinate.longitude {
            SunMoonBoardView(latitude: lat, longitude: lon, accent: settings.accent)
        } else {
            VStack(spacing: Spacing.md) {
                ThinkingOrb(size: 28)
                Text("Finding your location…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Location name on the left, a °C/°F toggle and a refresh button on the right.
    private var header: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "location.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(settings.accent)
            Text(weather.placeName.isEmpty ? "Your location" : weather.placeName)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
            if weather.loading {
                ThinkingOrb(size: 16)
            }
            Spacer(minLength: 0)
            unitToggle
            Button { refreshNonce += 1; Task { await refresh(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background { Circle().fill(Color.white.opacity(0.10)) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.08)
            .help("Refresh")
        }
    }

    private var unitToggle: some View {
        HStack(spacing: Spacing.hair) {
            ForEach([false, true], id: \.self) { f in
                let on = fahrenheit == f
                Button { fahrenheit = f } label: {
                    Text(f ? "°F" : "°C")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(on ? settings.accent.readableForeground : Theme.secondaryText)
                        .frame(width: 28, height: 22)
                        .background {
                            Capsule(style: .continuous)
                                .fill(on ? settings.accent : Color.clear)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.hair)
        .background { Capsule(style: .continuous).fill(Color.white.opacity(0.08)) }
    }

    // MARK: - Non-forecast states

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ThinkingOrb(size: 30)
            Text(location.location == nil ? "Finding your location…" : "Loading the forecast…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "cloud.slash.fill")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(weather.errorText ?? "Couldn't load the weather.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button { Task { await refresh(force: true) } } label: {
                Text("Try Again")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(settings.accent.readableForeground)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 30)
                    .background { Capsule().fill(settings.accent) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.05)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedPrompt: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(settings.accent)
            Text("Location access is off")
                .font(.system(size: 15, weight: .bold))
            Text("Turn it on in System Settings → Privacy & Security → Location Services to see your local weather.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button { Self.openLocationSettings() } label: {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(settings.accent.readableForeground)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 32)
                    .background { Capsule().fill(settings.accent) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.05)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Model

/// The two faces of the Weather tab.
enum WeatherMode: String, CaseIterable, Identifiable {
    case forecast, sunMoon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forecast: return "Forecast"
        case .sunMoon:  return "Sun & Moon"
        }
    }

    var symbol: String {
        switch self {
        case .forecast: return "cloud.sun.fill"
        case .sunMoon:  return "sunrise.fill"
        }
    }
}

/// The distilled "right now" readout the hero and details grid draw from.
struct CurrentWeather: Equatable {
    let temp: Int
    let code: Int
    let isDay: Bool
}

/// One hour in the horizontal strip.
struct HourEntry: Identifiable, Equatable {
    let id: Int
    let label: String
    let temp: Int
    let code: Int
    let isDay: Bool
}

/// One day in the forecast list.
struct DayEntry: Identifiable, Equatable {
    let id: Int
    let label: String
    let code: Int
    let hi: Int
    let lo: Int
}

// MARK: - Manager

/// Fetches and holds the forecast. A shared singleton so the last-loaded weather
/// survives tab switches (no refetch flash when you come back) and so a single
/// place owns the network + reverse-geocode work. Open-Meteo is keyless and free;
/// we send only the coarse coordinate.
@MainActor
final class WeatherManager: ObservableObject {
    static let shared = WeatherManager()

    @Published private(set) var current: CurrentWeather?
    @Published private(set) var placeName = ""
    @Published private(set) var loading = false
    @Published private(set) var errorText: String?
    /// The coordinate the current forecast was loaded for, so the Sun & Moon pane
    /// can keep drawing from a stable spot even if the live fix briefly drops.
    @Published private(set) var latitude: Double?
    @Published private(set) var longitude: Double?

    /// Guards against redundant refetches: the coarse coord + unit last loaded, and
    /// when. We refresh on a real move, a unit change, or once the data is ~15 min old.
    private var lastKey = ""
    private var lastFetch = Date.distantPast
    private let staleAfter: TimeInterval = 15 * 60

    private init() {}

    func load(latitude: Double, longitude: Double, fahrenheit: Bool, force: Bool = false) async {
        let key = String(format: "%.2f,%.2f,%@", latitude, longitude, fahrenheit ? "F" : "C")
        if !force, key == lastKey, Date().timeIntervalSince(lastFetch) < staleAfter, current != nil {
            return
        }
        loading = true
        defer { loading = false }

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
        ]

        do {
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            let r = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            apply(r, windUnit: fahrenheit ? "mph" : "km/h")
            self.latitude = latitude; self.longitude = longitude
            errorText = nil
            lastKey = key
            lastFetch = Date()
            await reverseGeocode(latitude: latitude, longitude: longitude)
        } catch {
            // Keep any previously-loaded forecast on screen; only surface the error
            // when we have nothing to show.
            if current == nil {
                errorText = "Couldn't reach the weather service."
            }
        }
    }

    private func apply(_ r: OpenMeteoResponse, windUnit: String) {
        current = CurrentWeather(
            temp: Int(r.current.temperature_2m.rounded()),
            code: r.current.weather_code,
            isDay: r.current.is_day == 1
        )
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async {
        let loc = CLLocation(latitude: latitude, longitude: longitude)
        guard let place = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return }
        placeName = place.locality ?? place.subAdministrativeArea ?? place.administrativeArea ?? place.name ?? ""
    }

    private static func formatter(_ format: String, tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = format
        return f
    }
}

/// Safe indexed access — the parallel Open-Meteo arrays should line up, but never
/// crash the panel if a series comes back short.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Open-Meteo wire format

struct OpenMeteoResponse: Decodable {
    let timezone: String?
    let current: Current
    let hourly: Hourly
    let daily: Daily

    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let relative_humidity_2m: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let is_day: Int
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double]
        let weather_code: [Int]
        let is_day: [Int]
    }

    struct Daily: Decodable {
        let time: [String]
        let weather_code: [Int]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int?]
        let uv_index_max: [Double]
    }
}

// MARK: - WMO weather codes

/// Maps Open-Meteo's WMO weather codes to an SF Symbol (day/night aware where it
/// matters) and a short human label. Grouped by the code bands in the WMO table.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0:            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1:            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2:            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:            return "cloud.fill"
        case 45, 48:       return "cloud.fog.fill"
        case 51, 53, 55:   return "cloud.drizzle.fill"
        case 56, 57:       return "cloud.sleet.fill"
        case 61, 63, 65:   return "cloud.rain.fill"
        case 66, 67:       return "cloud.sleet.fill"
        case 71, 73, 75:   return "cloud.snow.fill"
        case 77:           return "cloud.snow.fill"
        case 80, 81, 82:   return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 85, 86:       return "cloud.snow.fill"
        case 95:           return "cloud.bolt.rain.fill"
        case 96, 99:       return "cloud.bolt.rain.fill"
        default:           return "cloud.fill"
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0:            return "Clear"
        case 1:            return "Mainly Clear"
        case 2:            return "Partly Cloudy"
        case 3:            return "Overcast"
        case 45, 48:       return "Fog"
        case 51, 53, 55:   return "Drizzle"
        case 56, 57:       return "Freezing Drizzle"
        case 61, 63, 65:   return "Rain"
        case 66, 67:       return "Freezing Rain"
        case 71, 73, 75:   return "Snow"
        case 77:           return "Snow Grains"
        case 80, 81, 82:   return "Rain Showers"
        case 85, 86:       return "Snow Showers"
        case 95:           return "Thunderstorm"
        case 96, 99:       return "Thunderstorm & Hail"
        default:           return "—"
        }
    }

    /// A weather-coloured gradient so a tile reads its condition at a glance —
    /// sky-blue clear day, indigo clear night, slate overcast, deep-blue rain, pale
    /// snow, violet thunder — while staying dark enough (top-left) for white text.
    /// Grouped by the same WMO bands as `symbol`/`description`.
    static func gradient(_ code: Int, isDay: Bool) -> LinearGradient {
        let colors: [Color]
        switch code {
        case 0, 1:              // Clear / mainly clear
            colors = isDay ? [Color(red: 0.20, green: 0.45, blue: 0.74), Color(red: 0.08, green: 0.19, blue: 0.40)]
                           : [Color(red: 0.13, green: 0.15, blue: 0.36), Color(red: 0.04, green: 0.04, blue: 0.13)]
        case 2:                 // Partly cloudy
            colors = isDay ? [Color(red: 0.25, green: 0.37, blue: 0.55), Color(red: 0.10, green: 0.16, blue: 0.28)]
                           : [Color(red: 0.15, green: 0.17, blue: 0.32), Color(red: 0.05, green: 0.06, blue: 0.13)]
        case 3, 45, 48:         // Overcast / fog
            colors = [Color(red: 0.30, green: 0.33, blue: 0.39), Color(red: 0.12, green: 0.13, blue: 0.17)]
        case 51...67, 80...82:  // Drizzle / rain / showers
            colors = [Color(red: 0.16, green: 0.28, blue: 0.44), Color(red: 0.05, green: 0.10, blue: 0.19)]
        case 71...77, 85, 86:   // Snow
            colors = [Color(red: 0.36, green: 0.42, blue: 0.54), Color(red: 0.15, green: 0.18, blue: 0.27)]
        case 95...99:           // Thunderstorm
            colors = [Color(red: 0.29, green: 0.19, blue: 0.44), Color(red: 0.10, green: 0.06, blue: 0.18)]
        default:
            colors = [Color(red: 0.15, green: 0.17, blue: 0.22), Color(red: 0.05, green: 0.06, blue: 0.09)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
