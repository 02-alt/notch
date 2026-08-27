import AppKit

/// On-disk store for note photos. Images live under Application Support so notes
/// stay small (they only carry a filename) and the bytes survive relaunches.
enum NoteImageStore {
    /// `~/Library/Application Support/NotchGlass/NoteImages`.
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("NotchGlass/NoteImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for image: NoteImage) -> URL {
        directory.appendingPathComponent(image.filename)
    }

    /// Copies an image file into the store, keeping its extension.
    static func importImage(from source: URL) -> NoteImage? {
        let needsAccess = source.startAccessingSecurityScopedResource()
        defer { if needsAccess { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let filename = UUID().uuidString + "." + ext
        let dest = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return NoteImage(filename: filename)
        } catch {
            // Fall back to re-encoding (e.g. cross-volume or sandbox quirks).
            if let image = NSImage(contentsOf: source) { return importImage(nsImage: image) }
            return nil
        }
    }

    /// Writes a raw `NSImage` (e.g. dropped/pasted, not backed by a file) as PNG.
    static func importImage(nsImage: NSImage) -> NoteImage? {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let filename = UUID().uuidString + ".png"
        let dest = directory.appendingPathComponent(filename)
        do {
            try png.write(to: dest)
            return NoteImage(filename: filename)
        } catch {
            return nil
        }
    }

    static func load(_ image: NoteImage) -> NSImage? {
        NSImage(contentsOf: url(for: image))
    }

    static func delete(_ image: NoteImage) {
        deleteFile(named: image.filename)
    }

    static func deleteFile(named filename: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }
}
