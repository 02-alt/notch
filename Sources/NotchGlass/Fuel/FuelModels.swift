import Foundation

/// Which AI's usage the Fuel tab is showing. The header title in the Fuel tab is a
/// picker over these — Claude reads Claude Code's OAuth usage + local transcripts,
/// ChatGPT reads the local Codex/ChatGPT login and its session transcripts.
enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case chatgpt

    var id: String { rawValue }

    /// Short display name for the picker ("Claude", "ChatGPT").
    var title: String {
        switch self {
        case .claude:  return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }

    /// The big monospaced header label ("CLAUDE FUEL", "CHATGPT FUEL").
    var headerTitle: String { "\(title.uppercased()) FUEL" }

    var symbol: String {
        switch self {
        case .claude:  return "sparkles"
        case .chatgpt: return "bubble.left.and.bubble.right.fill"
        }
    }
}

/// The stat readouts on the Fuel tab. The layout is a single ordered list: the first
/// block is drawn large as the headline gauge, the rest as a grid of small cards. The
/// user reorders them (drag) and picks which is the big one (drag it to the top slot),
/// adds blocks via the "+" tile and removes them with a right-click.
enum FuelBlock: String, CaseIterable, Identifiable {
    // The three live gauges — historically the always-on top row and the big meter.
    case sessionFuel
    case weeklyLeft
    case resetsIn
    // The token / detail readouts — historically the optional "+" blocks.
    case thisBlock
    case today
    case topModel
    case weeklyReset
    case sessionsToday
    case credits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionFuel:   return "Session fuel"
        case .weeklyLeft:    return "Weekly left"
        case .resetsIn:      return "Resets in"
        case .thisBlock:     return "This block"
        case .today:         return "Today"
        case .topModel:      return "Top model"
        case .weeklyReset:   return "Weekly resets"
        case .sessionsToday: return "Sessions today"
        case .credits:       return "Credits"
        }
    }

    var symbol: String {
        switch self {
        case .sessionFuel:   return "gauge.with.dots.needle.67percent"
        case .weeklyLeft:    return "calendar.badge.checkmark"
        case .resetsIn:      return "arrow.clockwise.circle"
        case .thisBlock:     return "cube.fill"
        case .today:         return "calendar"
        case .topModel:      return "cpu.fill"
        case .weeklyReset:   return "calendar.badge.clock"
        case .sessionsToday: return "clock.arrow.circlepath"
        case .credits:       return "creditcard.fill"
        }
    }

    /// What a fresh install shows: the session gauge featured, with weekly + resets
    /// alongside it — the same three readouts the tab always led with.
    static let defaultLayout: [FuelBlock] = [.sessionFuel, .weeklyLeft, .resetsIn]

    /// The live gauges that used to be the implicit top row. When migrating an older
    /// install (whose saved blocks were only the optional set) these are prepended so
    /// nothing the user was seeing disappears.
    static let liveDefaults: [FuelBlock] = [.sessionFuel, .weeklyLeft, .resetsIn]
}
