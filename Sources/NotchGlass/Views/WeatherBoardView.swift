import SwiftUI
import MapKit
import CoreLocation

// MARK: - Board model

/// A saved spot on the weather board. `isCurrent` follows the device location (its
/// stored coordinate is ignored — the live fix is used); the rest are fixed cities.
struct SavedPlace: Codable, Equatable, Hashable {
    var name: String
    var latitude: Double
    var longitude: Double
    var isCurrent: Bool = false

    /// A coordinate key (~100 m) used to cache weather. `current` tiles resolve
    /// their coordinate live, so they share one slot.
    func coordKey(current: CLLocationCoordinate2D?) -> String {
        if isCurrent {
            guard let c = current else { return "current" }
            return String(format: "%.2f,%.2f", c.latitude, c.longitude)
        }
        return String(format: "%.2f,%.2f", latitude, longitude)
    }
}

/// One tile on the board: a place plus how many grid cells it spans. `span` is
/// columns (1…4), `rows` is 1…2 — resized by dragging the tile's corner grip.
struct WeatherTile: Codable, Identifiable, Equatable {
    var id = UUID()
    var place: SavedPlace
    var span: Int = 1
    var rows: Int = 1
}

/// A transient resize-in-progress, so the grid can reflow live under the drag
/// before the new size is committed to the model.
private struct ResizeDraft: Equatable { var id: UUID; var w: Int; var h: Int }

// MARK: - Board view

/// The default face of the Weather tab: a bento grid of city tiles. Each tile is a
/// destination's weather; drag its corner grip to grow it across 2–4 cells (and a
/// second row) and it unfolds from a compact glance into a full detail panel. Add
/// destinations with the "+" tile; right-click a tile to resize or remove it.
struct WeatherBoardView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var store = CityWeatherStore.shared

    let fahrenheit: Bool
    /// Live device coordinate, for tiles pinned to "current location".
    let currentCoord: CLLocationCoordinate2D?
    /// Bumped by the header refresh button to force a re-fetch of every tile.
    let refreshNonce: Int

    @AppStorage("weather.tiles") private var tilesJSON = WeatherBoardView.defaultTilesJSON

    /// The snapped size preview that drives how the *other* tiles reflow.
    @State private var draft: ResizeDraft?
    /// The dragged tile's live pixel size — it follows the cursor 1:1 (no spring)
    /// so the block feels glued to the pointer while everything else springs.
    @State private var dragPx: CGSize?
    @State private var adding = false
    /// The refresh nonce we've already acted on, so a bump forces exactly one refetch.
    @State private var appliedNonce = 0

    // Three chunkier blocks across (matching the AirDrop-tile proportions) reads
    // better than four cramped ones; span still tops out at the column count.
    private let columns = 3
    private let maxRows = 2
    private let gap: CGFloat = 10
    private let cellH: CGFloat = 148

    /// Resize/reflow feel: quick to start with a light, clean settle — snappy but
    /// smooth, no sloppy overshoot. Shared by the live drag-snap and the commit so
    /// the block moves the same way whether you drag it or pick a size from the menu.
    private static let resizeSpring: Animation = .snappy(duration: 0.26, extraBounce: 0.12)

    var body: some View {
        GeometryReader { geo in
            let cellW = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            // Pack the tiles (plus a phantom for the "+" cell) into the grid.
            let sized = tiles.map { (id: $0.id, w: previewW($0), h: previewH($0)) }
                + [(id: Self.addID, w: 1, h: 1)]
            let packed = Self.pack(sized, columns: columns)
            let totalRows = packed.values.map { $0.row + $0.h }.max() ?? 1

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    ForEach(tiles) { tile in
                        if let slot = packed[tile.id] {
                            let dragging = draft?.id == tile.id && dragPx != nil
                            let gridW = cellW * CGFloat(slot.w) + gap * CGFloat(slot.w - 1)
                            let gridH = cellH * CGFloat(slot.h) + gap * CGFloat(slot.h - 1)
                            tileView(tile, cellW: cellW)
                                // The dragged tile tracks the cursor continuously; the
                                // rest snap to the grid. Only the grid frame is spring-
                                // animated, so the dragged tile never lags behind.
                                .frame(width: dragging ? dragPx!.width : gridW,
                                       height: dragging ? dragPx!.height : gridH)
                                .animation(dragging ? nil : Self.resizeSpring, value: gridW)
                                .animation(dragging ? nil : Self.resizeSpring, value: gridH)
                                .offset(x: CGFloat(slot.col) * (cellW + gap),
                                        y: CGFloat(slot.row) * (cellH + gap))
                                .animation(Self.resizeSpring, value: slot.col)
                                .animation(Self.resizeSpring, value: slot.row)
                                .zIndex(draft?.id == tile.id ? 1 : 0)
                        }
                    }
                    if let slot = packed[Self.addID] {
                        addTile
                            .frame(width: cellW, height: cellH)
                            .offset(x: CGFloat(slot.col) * (cellW + gap),
                                    y: CGFloat(slot.row) * (cellH + gap))
                            .animation(Self.resizeSpring, value: slot.col)
                            .animation(Self.resizeSpring, value: slot.row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: cellH * CGFloat(totalRows) + gap * CGFloat(totalRows - 1),
                       alignment: .topLeading)
                .animation(Self.resizeSpring, value: totalRows)
            }
        }
        .overlay { if adding { addPanel } }
        // Fetch / refresh weather for every tile whenever the set, the units, the
        // location, or the refresh button changes.
        .task(id: fetchKey) { ensureAll() }
    }

    /// A signature that changes whenever we need to (re)check fetches. Resizes change
    /// `tilesJSON` too, but `ensure` no-ops on cached tiles so that's cheap.
    private var fetchKey: String {
        let coord = currentCoord.map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) } ?? "-"
        return "\(tilesJSON)|\(fahrenheit)|\(coord)|\(refreshNonce)"
    }

    private func ensureAll() {
        let force = refreshNonce != appliedNonce
        appliedNonce = refreshNonce
        for tile in tiles {
            let coord = tile.place.isCurrent ? currentCoord
                : CLLocationCoordinate2D(latitude: tile.place.latitude, longitude: tile.place.longitude)
            guard let coord else { continue }
            store.ensure(place: tile.place, coordinate: coord, fahrenheit: fahrenheit, force: force)
        }
    }

    // MARK: Tile

    private func tileView(_ tile: WeatherTile, cellW: CGFloat) -> some View {
        let key = store.key(for: tile.place, current: currentCoord, fahrenheit: fahrenheit)
        let snapshot = store.snapshots[key]
        return WeatherTileCard(tile: tile, span: previewW(tile), rows: previewH(tile),
                               snapshot: snapshot, accent: settings.accent,
                               isDraft: draft?.id == tile.id)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Corner grip: drag to resize across cells; snaps as you cross a cell.
            .overlay(alignment: .bottomTrailing) {
                resizeGrip(for: tile, cellW: cellW)
            }
            .contextMenu { tileMenu(tile) }
    }

    private func resizeGrip(for tile: WeatherTile, cellW: CGFloat) -> some View {
        // Drag to stretch across cells; tiles span 1…3 wide and 1…2 tall.
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 22, height: 22)
            .background { Circle().fill(Color.black.opacity(0.35)) }
            .padding(5)
            .contentShape(Rectangle())
            .notchHover(scale: 1.15, cursor: .grabIdle)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        let baseW = cellW * CGFloat(tile.span) + gap * CGFloat(tile.span - 1)
                        let baseH = cellH * CGFloat(tile.rows) + gap * CGFloat(tile.rows - 1)
                        let maxW = cellW * CGFloat(columns) + gap * CGFloat(columns - 1)
                        let maxH = cellH * CGFloat(maxRows) + gap * CGFloat(maxRows - 1)
                        // Continuous size, clamped to 1 cell … the board's max footprint.
                        let w = min(max(baseW + v.translation.width, cellW), maxW)
                        let h = min(max(baseH + v.translation.height, cellH), maxH)
                        dragPx = CGSize(width: w, height: h)
                        // Snap to the nearest cell count for how the others reflow.
                        let sw = min(max(Int(((w + gap) / (cellW + gap)).rounded()), 1), columns)
                        let sh = min(max(Int(((h + gap) / (cellH + gap)).rounded()), 1), maxRows)
                        if draft?.id != tile.id || draft?.w != sw || draft?.h != sh {
                            withAnimation(Self.resizeSpring) {
                                draft = ResizeDraft(id: tile.id, w: sw, h: sh)
                            }
                        }
                    }
                    .onEnded { _ in
                        let d = draft
                        // Commit the snapped size and drop the live overrides together,
                        // so the block springs cleanly from the cursor to its final cell.
                        withAnimation(Self.resizeSpring) {
                            if let d, d.id == tile.id { applyResize(tile, w: d.w, h: d.h) }
                            draft = nil
                            dragPx = nil
                        }
                    }
            )
    }

    @ViewBuilder
    private func tileMenu(_ tile: WeatherTile) -> some View {
        Button { resize(tile, w: 1, h: 1) } label: { Label("Small", systemImage: "square") }
        Button { resize(tile, w: 2, h: 1) } label: { Label("Wide", systemImage: "rectangle") }
        Button { resize(tile, w: 3, h: 1) } label: { Label("Extra wide", systemImage: "rectangle.grid.1x2") }
        Button { resize(tile, w: 1, h: 2) } label: { Label("Tall", systemImage: "rectangle.portrait") }
        Button { resize(tile, w: 2, h: 2) } label: { Label("Big", systemImage: "square.grid.2x2") }
        Button { resize(tile, w: 3, h: 2) } label: { Label("Large panel", systemImage: "rectangle.expand.vertical") }
        Divider()
        Button(role: .destructive) { remove(tile) } label: { Label("Remove", systemImage: "trash") }
    }

    // MARK: Add tile + panel

    private var addTile: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { adding = true } } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Text("Add city")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.line(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.02)
    }

    private var addPanel: some View {
        AddPlacePanel(currentCoord: currentCoord,
                      onPick: { place in add(place); withAnimation { adding = false } },
                      onClose: { withAnimation { adding = false } })
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // MARK: - Live-resize preview sizes

    private func previewW(_ tile: WeatherTile) -> Int {
        draft?.id == tile.id ? draft!.w : min(tile.span, columns)
    }
    private func previewH(_ tile: WeatherTile) -> Int {
        draft?.id == tile.id ? draft!.h : min(max(tile.rows, 1), maxRows)
    }

    // MARK: - Tile storage

    private var tiles: [WeatherTile] {
        (try? JSONDecoder().decode([WeatherTile].self, from: Data(tilesJSON.utf8))) ?? []
    }

    private func setTiles(_ list: [WeatherTile]) {
        if let data = try? JSONEncoder().encode(list) {
            tilesJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func add(_ place: SavedPlace) {
        guard !tiles.contains(where: { $0.place == place }) else { return }
        setTiles(tiles + [WeatherTile(place: place, span: 1, rows: 1)])
    }

    private func remove(_ tile: WeatherTile) {
        setTiles(tiles.filter { $0.id != tile.id })
    }

    /// Menu-driven resize: animates the change itself.
    private func resize(_ tile: WeatherTile, w: Int, h: Int) {
        withAnimation(Self.resizeSpring) { applyResize(tile, w: w, h: h) }
    }

    /// Writes the new size to the model without wrapping its own animation, so the
    /// drag-end path can batch it into one transaction with clearing `dragPx`/`draft`.
    private func applyResize(_ tile: WeatherTile, w: Int, h: Int) {
        var list = tiles
        guard let i = list.firstIndex(where: { $0.id == tile.id }) else { return }
        list[i].span = min(max(w, 1), columns)
        list[i].rows = min(max(h, 1), maxRows)
        setTiles(list)
    }

    // MARK: - Grid packing

    static let addID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000AD")!

    struct Slot { let col: Int; let row: Int; let w: Int; let h: Int }

    /// First-fit packing into a fixed-column grid that grows downward: scan cells
    /// row-major and drop each tile at the first spot its footprint fits.
    static func pack(_ items: [(id: UUID, w: Int, h: Int)], columns: Int) -> [UUID: Slot] {
        var occupied = Set<Int>()
        var out: [UUID: Slot] = [:]
        func cell(_ c: Int, _ r: Int) -> Int { r * columns + c }
        func fits(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> Bool {
            guard c + w <= columns else { return false }
            for rr in r..<(r + h) { for cc in c..<(c + w) where occupied.contains(cell(cc, rr)) { return false } }
            return true
        }
        for item in items {
            let w = min(max(item.w, 1), columns)
            let h = max(item.h, 1)
            var placed = false
            var r = 0
            while !placed {
                for c in 0...(columns - w) where fits(c, r, w, h) {
                    for rr in r..<(r + h) { for cc in c..<(c + w) { occupied.insert(cell(cc, rr)) } }
                    out[item.id] = Slot(col: c, row: r, w: w, h: h)
                    placed = true
                    break
                }
                r += 1
                if r > 512 { break }   // safety
            }
        }
        return out
    }

    /// Fresh boards start with a single wide "current location" tile.
    static let defaultTilesJSON = #"[{"id":"00000000-0000-0000-0000-000000000001","place":{"name":"My Location","latitude":0,"longitude":0,"isCurrent":true},"span":2,"rows":1}]"#
}

// MARK: - Tile card

/// One weather tile. The layout unfolds with size: a 1×1 shows the essentials, a
/// wide tile adds the condition and hi/lo, a 2×2 adds the hourly strip, and a large
/// panel (≥3 wide, 2 tall) shows the full breakdown — hourly, daily and details.
private struct WeatherTileCard: View {
    let tile: WeatherTile
    /// Live (preview) size while resizing, so the content unfolds with the drag.
    let span: Int
    let rows: Int
    let snapshot: CitySnapshot?
    let accent: Color
    let isDraft: Bool

    /// Layout tier the content is showing, so every distinct footprint crossfades
    /// instead of hard-popping. Encodes both width and height.
    private var tier: Int { min(span, 3) * 10 + min(rows, 2) }

    var body: some View {
        content
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Crossfade when the block crosses a size tier, instead of a hard pop.
            .id(tier)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: tier)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Self.gradient(code: snapshot?.code ?? 3, isDay: snapshot?.isDay ?? true))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isDraft ? accent : Color.white.opacity(0.08),
                                  lineWidth: isDraft ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if let s = snapshot {
            if rows >= 2 {
                if span >= 3 { large(s) }
                else if span >= 2 { big(s) }
                else { tall(s) }
            } else {
                if span >= 3 { xwide(s) }
                else if span >= 2 { wide(s) }
                else { small(s) }
            }
        } else {
            VStack(spacing: 6) {
                ThinkingOrb(size: 20)
                Text(tile.place.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // 1×1 — Apple's small-widget glance: location + glyph up top, a big temperature,
    // and the condition along the bottom.
    private func small(_ s: CitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                cityName(s)
                Spacer(minLength: 0)
                Image(systemName: WeatherCode.symbol(s.code, isDay: s.isDay))
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.multicolor)
            }
            Spacer(minLength: 4)
            Text("\(s.temp)°")
                .font(.system(size: 44, weight: .bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(WeatherCode.description(s.code))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // 2×1 — Apple's medium widget: location + big temp + hi/lo on the left, glyph and
    // condition on the right, over a short hourly strip.
    private func wide(_ s: CitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    cityName(s)
                    Text("\(s.temp)°")
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    hiLo(s)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: WeatherCode.symbol(s.code, isDay: s.isDay))
                        .font(.system(size: 26, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                    Text(WeatherCode.description(s.code))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            Spacer(minLength: 0)
            hourStrip(s, count: 5)
        }
        .padding(12)
    }

    // 3×1 — Apple's large widget: a hero on the left, then a 6-hour strip stacked
    // over daily rows with temperature-range bars.
    private func xwide(_ s: CitySnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                cityName(s)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(s.temp)°")
                        .font(.system(size: 42, weight: .bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Image(systemName: WeatherCode.symbol(s.code, isDay: s.isDay))
                        .font(.system(size: 22, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                }
                Text(WeatherCode.description(s.code))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                hiLo(s)
            }
            .frame(width: 148, alignment: .leading)

            Divider().overlay(Theme.line(0.10))

            VStack(spacing: 7) {
                hourStrip(s, count: 6)
                Divider().overlay(Theme.line(0.10))
                dailyRows(s, count: 3)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }

    // 1×2 — a slim two-row column: a compact hero over a stacked hourly list, the
    // extra height letting several hours read vertically.
    private func tall(_ s: CitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                cityName(s)
                Spacer(minLength: 0)
                Image(systemName: WeatherCode.symbol(s.code, isDay: s.isDay))
                    .font(.system(size: 18, weight: .medium))
                    .symbolRenderingMode(.multicolor)
            }
            Text("\(s.temp)°")
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(WeatherCode.description(s.code))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            hiLo(s)
            Divider().overlay(Theme.line(0.10)).padding(.vertical, 2)
            VStack(spacing: 9) {
                ForEach(s.hourly.prefix(6)) { hour in
                    HStack(spacing: 6) {
                        Text(hour.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 34, alignment: .leading)
                        Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                            .font(.system(size: 12, weight: .medium))
                            .symbolRenderingMode(.multicolor)
                        Spacer(minLength: 0)
                        Text("\(hour.temp)°")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // 2×2 — a header, an hourly strip and four daily range-bar rows in the taller
    // two-row footprint.
    private func big(_ s: CitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    cityName(s)
                    Text("\(s.temp)°")
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    hiLo(s)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: WeatherCode.symbol(s.code, isDay: s.isDay))
                        .font(.system(size: 30, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                    Text(WeatherCode.description(s.code))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            hourStrip(s, count: 6)
            Divider().overlay(Theme.line(0.10))
            dailyRows(s, count: 4)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // 3×2 — the full Apple large widget: a big hero on the left, then an 8-hour
    // strip stacked over six daily range-bar rows on the right.
    private func large(_ s: CitySnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                cityName(s, big: true)
                Image(systemName: WeatherCode.symbol(s.code, isDay: s.isDay))
                    .font(.system(size: 40, weight: .medium))
                    .symbolRenderingMode(.multicolor)
                    .padding(.vertical, 2)
                Text("\(s.temp)°")
                    .font(.system(size: 56, weight: .bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(WeatherCode.description(s.code))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                hiLo(s)
                Spacer(minLength: 0)
            }
            .frame(width: 178)

            Divider().overlay(Theme.line(0.10))

            VStack(spacing: 10) {
                hourStrip(s, count: 8)
                Divider().overlay(Theme.line(0.10))
                dailyRows(s, count: 6)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }

    /// Apple's daily rows: weekday · glyph · low · a colour range bar · high. The bar
    /// places each day's low→high span against the whole strip's coldest→warmest.
    private func dailyRows(_ s: CitySnapshot, count: Int) -> some View {
        let days = Array(s.daily.prefix(count))
        let scaleLo = days.map(\.lo).min() ?? 0
        let scaleHi = days.map(\.hi).max() ?? 1
        return VStack(spacing: 5) {
            ForEach(days) { day in
                HStack(spacing: 8) {
                    Text(day.label)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, alignment: .leading)
                    Image(systemName: WeatherCode.symbol(day.code, isDay: true))
                        .font(.system(size: 12, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 16)
                    Text("\(day.lo)°")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 26, alignment: .trailing)
                    TempRangeBar(lo: day.lo, hi: day.hi, scaleLo: scaleLo, scaleHi: scaleHi)
                    Text("\(day.hi)°")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
    }

    /// Apple-style ↑high ↓low readout.
    private func hiLo(_ s: CitySnapshot) -> some View {
        HStack(spacing: 6) {
            tempArrow("arrow.up", s.hi)
            tempArrow("arrow.down", s.lo)
        }
    }

    private func tempArrow(_ symbol: String, _ value: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text("\(value)°").font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(Theme.secondaryText)
    }

    // MARK: Pieces

    private func cityName(_ s: CitySnapshot, big: Bool = false) -> some View {
        HStack(spacing: 4) {
            if tile.place.isCurrent {
                Image(systemName: "location.fill").font(.system(size: big ? 11 : 9, weight: .bold))
                    .foregroundStyle(accent)
            }
            Text(s.placeName.isEmpty ? tile.place.name : s.placeName)
                .font(.system(size: big ? 16 : 13, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func hourStrip(_ s: CitySnapshot, count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(s.hourly.prefix(count)) { hour in
                VStack(spacing: 4) {
                    Text(hour.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                        .frame(height: 16)
                    Text("\(hour.temp)°")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// A subtle dark gradient tinted by conditions, so tiles read at a glance
    /// (clear-blue vs. stormy-slate vs. night-indigo) while staying legible.
    static func gradient(code: Int, isDay: Bool) -> LinearGradient {
        let colors: [Color]
        switch code {
        case 0, 1:
            colors = isDay ? [Color(red: 0.12, green: 0.28, blue: 0.48), Color(red: 0.06, green: 0.12, blue: 0.24)]
                           : [Color(red: 0.09, green: 0.10, blue: 0.22), Color(red: 0.03, green: 0.03, blue: 0.08)]
        case 2, 3, 45, 48:
            colors = [Color(red: 0.16, green: 0.19, blue: 0.24), Color(red: 0.07, green: 0.08, blue: 0.11)]
        case 51...67, 80...82:
            colors = [Color(red: 0.12, green: 0.18, blue: 0.26), Color(red: 0.05, green: 0.07, blue: 0.11)]
        case 71...77, 85, 86:
            colors = [Color(red: 0.20, green: 0.23, blue: 0.30), Color(red: 0.08, green: 0.09, blue: 0.13)]
        case 95...99:
            colors = [Color(red: 0.17, green: 0.13, blue: 0.24), Color(red: 0.06, green: 0.05, blue: 0.10)]
        default:
            colors = [Color(red: 0.13, green: 0.15, blue: 0.19), Color(red: 0.05, green: 0.06, blue: 0.09)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Temperature range bar

/// The little gradient bar Apple's daily forecast draws: a track with one coloured
/// segment showing where this day's low→high sits inside the week's cold→warm span.
/// The segment fades cool-blue (its low) to warm-orange (its high).
private struct TempRangeBar: View {
    let lo: Int
    let hi: Int
    let scaleLo: Int
    let scaleHi: Int

    var body: some View {
        GeometryReader { geo in
            let span = CGFloat(max(scaleHi - scaleLo, 1))
            let w = geo.size.width
            let x0 = CGFloat(lo - scaleLo) / span * w
            let x1 = CGFloat(hi - scaleLo) / span * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [color(lo), color(hi)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x1 - x0, 6))
                    .offset(x: x0)
            }
        }
        .frame(height: 4)
    }

    /// Cool-blue at the strip's coldest, warm-orange at its warmest.
    private func color(_ t: Int) -> Color {
        let f = Double(t - scaleLo) / Double(max(scaleHi - scaleLo, 1))
        let cool = (r: 0.35, g: 0.62, b: 0.95)
        let warm = (r: 0.98, g: 0.62, b: 0.28)
        return Color(red: cool.r + (warm.r - cool.r) * f,
                     green: cool.g + (warm.g - cool.g) * f,
                     blue: cool.b + (warm.b - cool.b) * f)
    }
}

// MARK: - Add-place panel

/// A small overlay for adding a destination: a "Current Location" shortcut and a
/// city search backed by MapKit.
private struct AddPlacePanel: View {
    let currentCoord: CLLocationCoordinate2D?
    let onPick: (SavedPlace) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var results: [SavedPlace] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Add a destination")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, Color.white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.1)
            }

            if currentCoord != nil {
                Button {
                    onPick(SavedPlace(name: "My Location", latitude: 0, longitude: 0, isCurrent: true))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill").font(.system(size: 12, weight: .bold))
                        Text("Current Location").font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.01)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                TextField("Search a city…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .onSubmit(runSearch)
                if searching { ThinkingOrb(size: 16) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background { Capsule().fill(Color.white.opacity(0.08)) }

            if !results.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(results, id: \.self) { place in
                            Button { onPick(place) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                                    Text(place.name).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).frame(height: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .notchHover(scale: 1.01)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 360, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.9))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        }
        .padding(.vertical, 6)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.resultTypes = .address
        MKLocalSearch(request: request).start { response, _ in
            Task { @MainActor in
                searching = false
                let items = response?.mapItems ?? []
                results = items.prefix(6).compactMap { item in
                    let p = item.placemark
                    let name = [p.locality ?? p.name, p.administrativeArea, p.country]
                        .compactMap { $0 }.first ?? (item.name ?? q)
                    let full = [p.locality ?? p.name, p.country].compactMap { $0 }.joined(separator: ", ")
                    return SavedPlace(name: full.isEmpty ? name : full,
                                      latitude: p.coordinate.latitude,
                                      longitude: p.coordinate.longitude)
                }
            }
        }
    }
}

// MARK: - Multi-city weather store

/// A distilled forecast for one place, sized for the board tiles.
struct CitySnapshot: Equatable {
    var placeName: String
    var temp: Int
    var feelsLike: Int
    var humidity: Int
    var wind: Int
    var windUnit: String
    var uv: Int
    var code: Int
    var isDay: Bool
    var hi: Int
    var lo: Int
    var hourly: [HourEntry]
    var daily: [DayEntry]
}

/// Fetches and caches weather for every place on the board, keyed by coarse
/// coordinate + unit so switching units or moving refetches cleanly and each city
/// is fetched once. Keyless Open-Meteo, coarse coordinate only — same privacy
/// posture as the single-location `WeatherManager`.
@MainActor
final class CityWeatherStore: ObservableObject {
    static let shared = CityWeatherStore()

    @Published private(set) var snapshots: [String: CitySnapshot] = [:]

    private var inFlight: Set<String> = []
    private var lastFetch: [String: Date] = [:]
    private let staleAfter: TimeInterval = 15 * 60

    private init() {}

    /// The cache key for a place under the given units.
    func key(for place: SavedPlace, current: CLLocationCoordinate2D?, fahrenheit: Bool) -> String {
        "\(place.coordKey(current: current))|\(fahrenheit ? "F" : "C")"
    }

    func ensure(place: SavedPlace, coordinate: CLLocationCoordinate2D, fahrenheit: Bool, force: Bool) {
        let key = "\(String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude))|\(fahrenheit ? "F" : "C")"
        if inFlight.contains(key) { return }
        if !force, let t = lastFetch[key], Date().timeIntervalSince(t) < staleAfter, snapshots[key] != nil {
            return
        }
        inFlight.insert(key)
        Task { await fetch(place: place, coordinate: coordinate, fahrenheit: fahrenheit, key: key) }
    }

    private func fetch(place: SavedPlace, coordinate: CLLocationCoordinate2D,
                       fahrenheit: Bool, key: String) async {
        defer { inFlight.remove(key) }

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data) else { return }

        var name = place.name
        if place.isCurrent {
            let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
                name = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? name
            }
        }

        snapshots[key] = Self.distill(r, placeName: name, windUnit: fahrenheit ? "mph" : "km/h")
        lastFetch[key] = Date()
    }

    /// Collapse an Open-Meteo response into the compact `CitySnapshot` tiles draw.
    private static func distill(_ r: OpenMeteoResponse, placeName: String, windUnit: String) -> CitySnapshot {
        let tz = TimeZone(identifier: r.timezone ?? "") ?? .current
        let hi = r.daily.temperature_2m_max.first ?? r.current.temperature_2m
        let lo = r.daily.temperature_2m_min.first ?? r.current.temperature_2m

        let now = Date()
        let hourFmt = fmt("yyyy-MM-dd'T'HH:mm", tz)
        let hourLbl = fmt("ha", tz)
        var hours: [HourEntry] = []
        for (i, t) in r.hourly.time.enumerated() {
            guard let date = hourFmt.date(from: t), date.timeIntervalSince(now) > -3600 else { continue }
            hours.append(HourEntry(id: i,
                                   label: hourLbl.string(from: date).lowercased(),
                                   temp: Int((r.hourly.temperature_2m[safe: i] ?? 0).rounded()),
                                   code: r.hourly.weather_code[safe: i] ?? 0,
                                   isDay: (r.hourly.is_day[safe: i] ?? 1) == 1))
            if hours.count >= 12 { break }
        }

        let dayFmt = fmt("yyyy-MM-dd", tz)
        let dayLbl = fmt("EEE", tz)
        let cal = Calendar.current
        var days: [DayEntry] = []
        for (i, t) in r.daily.time.enumerated() {
            guard let date = dayFmt.date(from: t), !cal.isDateInToday(date) else { continue }
            days.append(DayEntry(id: i,
                                 label: dayLbl.string(from: date),
                                 code: r.daily.weather_code[safe: i] ?? 0,
                                 hi: Int((r.daily.temperature_2m_max[safe: i] ?? 0).rounded()),
                                 lo: Int((r.daily.temperature_2m_min[safe: i] ?? 0).rounded()),
                                 precip: (r.daily.precipitation_probability_max[safe: i] ?? nil) ?? 0))
            if days.count >= 6 { break }
        }

        return CitySnapshot(
            placeName: placeName,
            temp: Int(r.current.temperature_2m.rounded()),
            feelsLike: Int(r.current.apparent_temperature.rounded()),
            humidity: Int(r.current.relative_humidity_2m.rounded()),
            wind: Int(r.current.wind_speed_10m.rounded()),
            windUnit: windUnit,
            uv: Int((r.daily.uv_index_max.first ?? 0).rounded()),
            code: r.current.weather_code,
            isDay: r.current.is_day == 1,
            hi: Int(hi.rounded()), lo: Int(lo.rounded()),
            hourly: hours, daily: days)
    }

    private static func fmt(_ format: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = format
        return f
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
