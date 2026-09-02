import SwiftUI

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Perceived luminance (0 = black, 1 = white), sRGB weighted.
    var luminance: Double {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
    }

    /// Black or white — whichever reads better on top of this color. Used so text
    /// on an accent fill stays legible whatever accent the user picks.
    var readableForeground: Color {
        luminance > 0.6 ? .black : .white
    }
}
