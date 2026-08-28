import SwiftUI

// MARK: - Real moon photos (NASA SVS "Dial-a-Moon")

/// Maps a moment to NASA's real hourly photograph of the Moon for that instant.
///
/// Every year the NASA Scientific Visualization Studio renders 8,760 hourly frames
/// (8,784 in a leap year) of the Moon's precise phase, libration and apparent size —
/// actual imagery, not a drawing. Frames are numbered 1…N by the hour of the year in
/// UTC, so we just count hours since Jan 1 00:00 UTC and clamp.
///
/// The catch: each year is a separate SVS product with its own id, so we keep a small
/// lookup table. A year we don't have an id for returns `nil`, and the UI falls back to
/// the locally-drawn `MoonDisc`. Add next year's id here when it publishes.
enum MoonPhoto {
    /// Calendar year → SVS product id. Folder path is derived from the id (verified
    /// against the live server for 2024–2026).
    /// See https://svs.gsfc.nasa.gov/gallery/moonphase/
    private static let productIDs: [Int: Int] = [
        2024: 5187,
        2025: 5415,
        2026: 5587,
    ]

    /// Frames are numbered by UTC hour-of-year, so all date math runs in a fixed
    /// UTC calendar — built once rather than per call.
    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// The hourly-frame photo URL for `date`, or `nil` if we don't have that year's
    /// render. Square (`1x1`) 730×730 frame — sized for a round phase disc.
    static func frameURL(for date: Date) -> URL? {
        let cal = utc
        let year = cal.component(.year, from: date)
        guard let id = productIDs[year],
              let startOfYear = cal.date(from: DateComponents(year: year, month: 1, day: 1, hour: 0))
        else { return nil }

        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let maxFrame = isLeap ? 8784 : 8760
        let hours = Int(date.timeIntervalSince(startOfYear) / 3600)
        let frame = min(max(hours + 1, 1), maxFrame)

        // e.g. id 5587 → /vis/a000000/a005500/a005587/frames/730x730_1x1_30p/moon.NNNN.jpg
        let mid = String(format: "a%06d", (id / 100) * 100)
        let inner = String(format: "a%06d", id)
        let name = String(format: "moon.%04d.jpg", frame)
        return URL(string: "https://svs.gsfc.nasa.gov/vis/a000000/\(mid)/\(inner)/frames/730x730_1x1_30p/\(name)")
    }
}

/// Disk-backed loader for moon frames. Fetches each frame at most once, then serves it
/// from Application Support forever — so after the first online load the photo is fully
/// offline. Any network failure returns `nil` (caller draws the disc instead).
actor MoonPhotoCache {
    static let shared = MoonPhotoCache()

    private let dir: URL
    private let session = URLSession(configuration: .ephemeral)
    private var memory: [URL: NSImage] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("NotchGlass/MoonPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = memory[url] { return cached }

        let file = dir.appendingPathComponent(url.path.dropFirst().replacingOccurrences(of: "/", with: "_"))
        if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            memory[url] = img
            return img
        }

        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data)
        else { return nil }

        try? data.write(to: file)
        memory[url] = img
        return img
    }
}

/// The Moon's current phase as a real NASA photograph, with the locally-drawn
/// `MoonDisc` shown while loading, when offline, or for years without a render.
struct MoonPhotoDisc: View {
    let date: Date
    let fraction: Double
    let waxing: Bool
    var size: CGFloat = 56
    var glow: Bool = true

    @State private var image: NSImage?

    private var url: URL? { MoonPhoto.frameURL(for: date) }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1) }
                    .shadow(color: .white.opacity(glow ? 0.22 : 0), radius: glow ? 8 : 0)
            } else {
                MoonDisc(fraction: fraction, waxing: waxing, size: size, glow: glow)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await MoonPhotoCache.shared.image(for: url)
        }
    }
}
