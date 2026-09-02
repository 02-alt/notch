import SwiftUI
import MapKit
import CoreLocation

/// A live Apple Map inside the notch. Compact mode shows the map with a search /
/// destination chip and an expand button; expanded (like the Mood board's "bigger
/// notch") it splits into the map plus a trip panel — travel time, distance and
/// arrival for the chosen transport mode, a destination card, and a compact
/// now-playing strip. With no destination it reads out where you are.
struct MapTabView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var location = LocationManager()

    /// Recently-routed destinations, persisted as JSON so they survive relaunches.
    @AppStorage("map.recents") private var recentsJSON = "[]"

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var query = ""
    @State private var destination: MKMapItem?
    @State private var route: MKRoute?
    @State private var searching = false
    @State private var routing = false
    @State private var travelMode: TravelMode = .drive
    /// Reverse-geocoded neighbourhood/city for the idle "You're near …" readout.
    @State private var nearby = ""

    private var expanded: Bool { vm.mapExpanded }

    /// Coarse location key (~100 m) so we only re-geocode when you actually move.
    private var coarseKey: String {
        guard let c = location.location?.coordinate else { return "none" }
        return String(format: "%.3f,%.3f", c.latitude, c.longitude)
    }

    var body: some View {
        Group {
            if expanded {
                HStack(spacing: 0) {
                    mapPane
                    dashboard
                        .frame(width: 300)
                }
            } else {
                mapPane
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .onAppear {
            location.request()
            location.start()
        }
        .onDisappear { location.stop() }
        .task(id: coarseKey) { await updateNearby() }
        // Re-route when you switch drive / walk / transit.
        .onChange(of: travelMode) { _, _ in
            if let destination { computeRoute(to: destination) }
        }
    }

    // MARK: - Map

    private var mapPane: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            if let destination {
                Marker(destination.name ?? "Destination",
                       coordinate: destination.placemark.coordinate)
                    .tint(settings.accent)
            }
            if let route {
                MapPolyline(route.polyline)
                    .stroke(settings.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControlVisibility(.hidden)
        .overlay(alignment: .bottom) { controlBar }
        .overlay(alignment: .topTrailing) { expandButton }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Search field + destination readout along the bottom, glass-styled.
    private var controlBar: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                TextField("Search a place…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .onSubmit(runSearch)
                if searching {
                    ThinkingOrb(size: 18)
                } else if destination != nil {
                    Button {
                        clearDestination()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white, Color.black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .notchHover(scale: 1.15)
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.sm)
            .background { Capsule(style: .continuous).fill(Color.black.opacity(0.55)) }
            .blackGlass(in: Capsule(style: .continuous))

            if let destination {
                Button { openInMaps(destination) } label: {
                    Text("Directions")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(settings.accent.readableForeground)
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, Spacing.sm)
                        .background { Capsule().fill(settings.accent) }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.04)
            }
        }
        .padding(Spacing.base)
    }

    private var expandButton: some View {
        GlassButton(shape: AnyShape(Circle()),
                    tint: expanded ? settings.accent.opacity(0.6) : nil,
                    action: {
                        withAnimation(Metrics.openSpring) { vm.mapExpanded.toggle() }
                    }) {
            Image(systemName: expanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
        }
        .padding(Spacing.base)
    }

    // MARK: - Dashboard (expanded)

    private var dashboard: some View {
        Group {
            if destination != nil {
                tripPanel
            } else {
                idlePanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }

    // MARK: Trip panel (destination set)

    private var tripPanel: some View {
        VStack(spacing: Spacing.lg) {
            if travelMode == .transit {
                transitHandoff
            } else if let route {
                HStack(spacing: 0) {
                    stat(title: "Time",
                         value: durationValue(route),
                         unit: durationUnit(route))
                    Divider().overlay(Color.white.opacity(0.12))
                    stat(title: "Distance",
                         value: distanceValue(route),
                         unit: "km")
                }
                Text("Arrive \(arrivalText(route))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            } else if routing {
                VStack(spacing: Spacing.sm) {
                    ThinkingOrb(size: 28)
                    Text("Finding route…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxHeight: .infinity)
            } else {
                Text("No \(travelMode.title.lowercased()) route available")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxHeight: .infinity)
            }

            transportToggle
            placeCard
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
    }

    private func stat(title: String, value: String, unit: String) -> some View {
        VStack(spacing: Spacing.s) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(.system(size: 48, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    /// Drive / walk / transit picker; switching recomputes the route.
    private var transportToggle: some View {
        HStack(spacing: Spacing.s) {
            ForEach(TravelMode.allCases) { mode in
                let on = travelMode == mode
                Button { travelMode = mode } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? settings.accent.readableForeground : Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            Capsule(style: .continuous)
                                .fill(on ? settings.accent : Color.white.opacity(0.08))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.04)
                .help(mode.title)
            }
        }
    }

    /// Transit isn't available through MapKit's routing API, so offer a hand-off to
    /// Apple Maps (which does have transit) instead of a dead "no route" message.
    private var transitHandoff: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tram.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(settings.accent)
            Text("Apple Maps has transit directions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                if let destination { openInMaps(destination) }
            } label: {
                Text("Open in Maps")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(settings.accent.readableForeground)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background { Capsule().fill(settings.accent) }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.04)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, Spacing.sm)
    }

    /// The destination as a card: name + address, with a category glyph.
    private var placeCard: some View {
        Group {
            if let d = destination {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(settings.accent)
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(d.name ?? "Destination")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let address = addressText(d) {
                            Text(address)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }
            }
        }
    }

    // MARK: Idle panel (no destination) — a "where to?" launcher

    private var idlePanel: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Where you are.
            HStack(spacing: Spacing.sm) {
                Image(systemName: "location.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(settings.accent)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("You're near")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Text(nearby.isEmpty ? "Locating…" : nearby)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // Nearby quick-search.
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("NEARBY")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .kerning(0.6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 3),
                          spacing: Spacing.sm) {
                    ForEach(NearbyCategory.allCases) { cat in
                        Button { searchCategory(cat) } label: {
                            VStack(spacing: Spacing.s) {
                                Image(systemName: cat.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                Text(cat.title)
                                    .font(.system(size: 9, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .notchHover(scale: 1.05)
                    }
                }
            }

            // Recent destinations.
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("RECENT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .kerning(0.6)
                    ForEach(recents.prefix(3)) { place in
                        Button { route(to: place) } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondaryText)
                                Text(place.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, Spacing.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .notchHover(scale: 1.02)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
    }

    // MARK: - Actions

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let here = location.location?.coordinate {
            request.region = MKCoordinateRegion(center: here,
                                                latitudinalMeters: 30_000,
                                                longitudinalMeters: 30_000)
        }
        MKLocalSearch(request: request).start { response, _ in
            Task { @MainActor in
                searching = false
                guard let item = response?.mapItems.first else { return }
                setDestination(item)
            }
        }
    }

    /// Runs a nearby category search (Coffee, Food, …) as a destination.
    private func searchCategory(_ category: NearbyCategory) {
        query = category.query
        runSearch()
    }

    /// Focuses the map on `item`, routes to it, and files it under Recents.
    private func setDestination(_ item: MKMapItem) {
        destination = item
        withAnimation { cameraPosition = .region(regionFraming(item)) }
        computeRoute(to: item)
        addRecent(item)
    }

    // MARK: - Recents

    private var recents: [RecentPlace] {
        (try? JSONDecoder().decode([RecentPlace].self, from: Data(recentsJSON.utf8))) ?? []
    }

    private func addRecent(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        let place = RecentPlace(name: item.name ?? "Place",
                                latitude: c.latitude, longitude: c.longitude)
        var list = recents.filter { $0.name != place.name }
        list.insert(place, at: 0)
        list = Array(list.prefix(6))
        if let data = try? JSONEncoder().encode(list) {
            recentsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    /// Re-routes to a stored recent place.
    private func route(to place: RecentPlace) {
        let coord = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = place.name
        query = place.name
        setDestination(item)
    }

    private func computeRoute(to item: MKMapItem) {
        // Apple's MKDirections API doesn't return transit routes at all — transit
        // directions are only available by launching Maps.app — so we don't even
        // try; the panel offers an "Open in Maps" hand-off instead.
        guard travelMode != .transit else { route = nil; routing = false; return }
        guard location.location != nil else { route = nil; return }
        route = nil
        routing = true
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = item
        request.transportType = travelMode.transportType
        MKDirections(request: request).calculate { response, _ in
            Task { @MainActor in
                routing = false
                route = response?.routes.first
            }
        }
    }

    // MARK: - Formatting

    private func durationValue(_ route: MKRoute) -> String {
        let minutes = route.expectedTravelTime / 60
        return minutes >= 60 ? String(format: "%.1f", minutes / 60) : String(Int(minutes.rounded()))
    }

    private func durationUnit(_ route: MKRoute) -> String {
        route.expectedTravelTime >= 3600 ? "hr" : "min"
    }

    /// Distance in km — one decimal up close, whole numbers once it's long, so the
    /// big number never needs more than three digits.
    private func distanceValue(_ route: MKRoute) -> String {
        let km = route.distance / 1000
        return km >= 100 ? String(Int(km.rounded())) : String(format: "%.1f", km)
    }

    /// Clock time you'd arrive if you left now.
    private func arrivalText(_ route: MKRoute) -> String {
        Date().addingTimeInterval(route.expectedTravelTime)
            .formatted(date: .omitted, time: .shortened)
    }

    /// A short address line for the destination card.
    private func addressText(_ item: MKMapItem) -> String? {
        let p = item.placemark
        let parts = [p.thoroughfare, p.locality].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return p.title
    }

    /// Reverse-geocode the current fix into a neighbourhood/city for the idle panel.
    private func updateNearby() async {
        guard let loc = location.location else { return }
        guard let place = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return }
        nearby = place.subLocality ?? place.locality ?? place.name ?? ""
    }

    /// A region that frames the user and the destination together, or just the
    /// destination if we don't have a location fix.
    private func regionFraming(_ item: MKMapItem) -> MKCoordinateRegion {
        let dest = item.placemark.coordinate
        guard let here = location.location?.coordinate else {
            return MKCoordinateRegion(center: dest,
                                      latitudinalMeters: 4_000, longitudinalMeters: 4_000)
        }
        let center = CLLocationCoordinate2D(latitude: (here.latitude + dest.latitude) / 2,
                                            longitude: (here.longitude + dest.longitude) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: abs(here.latitude - dest.latitude) * 1.6 + 0.02,
            longitudeDelta: abs(here.longitude - dest.longitude) * 1.6 + 0.02
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private func clearDestination() {
        query = ""
        destination = nil
        route = nil
        withAnimation { cameraPosition = .userLocation(fallback: .automatic) }
    }

    private func openInMaps(_ item: MKMapItem) {
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: travelMode.launchDirectionsMode
        ])
    }
}

/// A stored recent destination (name + coordinate), persisted as JSON.
struct RecentPlace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
}

/// Quick nearby-search categories shown on the idle map dashboard.
enum NearbyCategory: String, CaseIterable, Identifiable {
    case coffee, food, gas, bar, grocery, transit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coffee:  return "Coffee"
        case .food:    return "Food"
        case .gas:     return "Gas"
        case .bar:     return "Bars"
        case .grocery: return "Grocery"
        case .transit: return "Transit"
        }
    }

    var symbol: String {
        switch self {
        case .coffee:  return "cup.and.saucer.fill"
        case .food:    return "fork.knife"
        case .gas:     return "fuelpump.fill"
        case .bar:     return "wineglass.fill"
        case .grocery: return "cart.fill"
        case .transit: return "tram.fill"
        }
    }

    /// The natural-language query handed to `MKLocalSearch`.
    var query: String {
        switch self {
        case .coffee:  return "Coffee"
        case .food:    return "Restaurants"
        case .gas:     return "Gas station"
        case .bar:     return "Bar"
        case .grocery: return "Grocery store"
        case .transit: return "Transit station"
        }
    }
}

/// The three route kinds offered by the transport toggle.
enum TravelMode: String, CaseIterable, Identifiable {
    case drive, walk, transit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drive:   return "Drive"
        case .walk:    return "Walk"
        case .transit: return "Transit"
        }
    }

    var symbol: String {
        switch self {
        case .drive:   return "car.fill"
        case .walk:    return "figure.walk"
        case .transit: return "tram.fill"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .drive:   return .automobile
        case .walk:    return .walking
        case .transit: return .transit
        }
    }

    var launchDirectionsMode: String {
        switch self {
        case .drive:   return MKLaunchOptionsDirectionsModeDriving
        case .walk:    return MKLaunchOptionsDirectionsModeWalking
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        }
    }
}

/// Thin CoreLocation wrapper: authorization, the latest fix, and a live speed in
/// km/h derived from `CLLocation.speed`.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var location: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorization = manager.authorizationStatus
    }

    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() { manager.startUpdatingLocation() }
    func stop() { manager.stopUpdatingLocation() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorization = status
            if status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            location = loc
        }
    }
}
