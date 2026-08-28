import SwiftUI
import AppKit
import Combine
import EventKit
import MapKit
import CoreLocation

/// A calendar you can browse, pulled from the system Calendar via EventKit. A hero
/// line up top counts down to the next thing on the schedule — live to the second
/// in the final minute, flipping to a "happening now" state while an event is under
/// way, offering a one-tap Join for video calls and a "leave by" nudge when the
/// event has a location. Below it a compact month grid (dots on days with events)
/// lets you pick any day, and the selected day's events list underneath, each row
/// showing its time, a colour dot, the title, any location and a Join button.
/// Clicking a row opens it in Calendar.app; the "+" adds an event by typing plain
/// language like "Lunch tomorrow 1pm".
///
/// Access is requested lazily — the tab shows a friendly prompt until the user
/// grants Calendar access, and a route to System Settings if they've said no.
struct CalendarTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var manager = CalendarManager.shared

    @State private var draft = ""
    @State private var showingAdd = false
    @FocusState private var addFocused: Bool

    var body: some View {
        Group {
            if manager.isAuthorized {
                agenda
            } else if manager.status == .denied || manager.status == .restricted {
                deniedPrompt
            } else {
                requestPrompt
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { manager.refreshStatusAndLoad() }
    }

    // MARK: - Agenda

    private var agenda: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            monthGrid
            if showingAdd { quickAddBar }
            selectedDaySection
        }
    }

    // MARK: - Month grid

    /// A compact month calendar for browsing any day: prev/next arrows, an add
    /// button, a weekday row and six weeks of day cells. Days with events carry a
    /// dot; today is ringed; the selected day is filled. Tapping a cell selects
    /// that day (and pages the month if it belongs to a neighbour).
    private var monthGrid: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(Self.monthTitle.string(from: manager.visibleMonth))
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: 0)
                monthArrow("chevron.left", "Previous month") { manager.changeMonth(by: -1) }
                monthArrow("chevron.right", "Next month") { manager.changeMonth(by: 1) }
                Button {
                    showingAdd.toggle()
                    if showingAdd { addFocused = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(settings.accent.readableForeground)
                        .frame(width: 26, height: 26)
                        .background { Circle().fill(settings.accent) }
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.08)
                .accessibilityLabel(showingAdd ? "Close add event" : "Add event")
                .help("Add event")
            }
            HStack(spacing: 0) {
                ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: Spacing.hair) {
                ForEach(manager.gridDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .padding(Spacing.md)
        .innerCard(cornerRadius: 12)
    }

    private func monthArrow(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background { Circle().fill(Theme.line(0.10)) }
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.08)
        .accessibilityLabel(label)
        .help(label)
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let inMonth = cal.isDate(day, equalTo: manager.visibleMonth, toGranularity: .month)
        let isSelected = cal.isDate(day, inSameDayAs: manager.selectedDay)
        let isToday = cal.isDateInToday(day)
        let hasEvents = manager.hasEvents(on: day)
        return Button { manager.select(day) } label: {
            VStack(spacing: 1) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(inMonth ? .white : Theme.tertiaryText)
                Circle()
                    .fill(hasEvents ? settings.accent : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(settings.accent.opacity(0.30))
                }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(settings.accent, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .accessibilityLabel(Self.cellAccessibilityLabel(day, hasEvents: hasEvents))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Quick add

    /// Inline natural-language add — "Lunch tomorrow 1pm". Parsing lives in the
    /// manager; here we just collect the text and hand it over.
    private var quickAddBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            TextField("Add event — e.g. “Lunch tomorrow 1pm”", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .tint(settings.accent)
                .focused($addFocused)
                .onSubmit(commitAdd)
                .accessibilityLabel("New event description")
            Button("Add", action: commitAdd)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(settings.accent.readableForeground)
                .padding(.horizontal, Spacing.md)
                .frame(height: 26)
                .background { Capsule().fill(settings.accent) }
                .notchHover(scale: 1.05)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .innerCard(cornerRadius: 10)
    }

    private func commitAdd() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        manager.addEvent(naturalText: text)
        draft = ""
        showingAdd = false
        addFocused = false
    }

    // MARK: - Selected day

    private var selectedDaySection: some View {
        let events = manager.events(on: manager.selectedDay)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(Self.dayHeading(manager.selectedDay))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
                .kerning(0.5)
            if events.isEmpty {
                emptyDay
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(events, id: \.eventIdentifier) { eventRow($0) }
                    }
                    .padding(.bottom, Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyDay: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "calendar")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text("Nothing on this day.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The hero row: the next (or in-progress) event and how far off it is, a Join
    /// button for video calls, a "leave by" nudge for events with a location, plus
    /// a jump into Calendar.app for anything the compact agenda doesn't cover.
    ///
    /// The timeline ticks once a second so the countdown runs down live and rolls
    /// straight to the next event as one ends.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let now = context.date
            let next = manager.nextEvent(after: now)
            HStack(alignment: .center, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(Self.heroLabel(next, now))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .kerning(0.6)
                    if let next {
                        HStack(spacing: Spacing.sm) {
                            Circle()
                                .fill(color(for: next))
                                .frame(width: 8, height: 8)
                            Text(next.title ?? "Event")
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(1)
                            Text(Self.heroCountdown(next, now))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(settings.accent)
                        }
                        if let leaveBy = manager.travelNudge(for: next) {
                            leaveChip(leaveBy.timeIntervalSince(now), title: next.title)
                        }
                    } else {
                        Text("Nothing coming up")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if let next, let url = next.meetingURL {
                    joinButton(url, title: next.title, compact: false)
                }
                Button { Self.openCalendarApp() } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(Theme.line(0.10)) }
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.08)
                .accessibilityLabel("Open Calendar")
                .help("Open Calendar")
            }
        }
    }

    /// A row is two side-by-side buttons rather than one nested inside another: the
    /// content opens the event, the trailing Join opens the call. Keeping them as
    /// separate native buttons means both are keyboard-focusable with no ambiguous
    /// nested hit-testing.
    private func eventRow(_ event: EKEvent) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Button { Self.open(event) } label: {
                HStack(alignment: .top, spacing: Spacing.md) {
                    Text(Self.timeText(event))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 62, alignment: .leading)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: event))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(event.title ?? "Event")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let loc = event.location, !loc.isEmpty {
                            Label(loc, systemImage: "mappin.and.ellipse")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.rowAccessibilityLabel(event))
            .accessibilityHint("Opens in Calendar")

            if let url = event.meetingURL {
                joinButton(url, title: event.title, compact: true)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .innerCard(cornerRadius: 10)
        .notchHover(scale: 1.01)
    }

    /// One-tap Join for the detected video call. `compact` is the small circular
    /// icon used on list rows; the wide pill is used on the hero. Both clear the
    /// 24×24 minimum target size.
    private func joinButton(_ url: URL, title: String?, compact: Bool) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Group {
                if compact {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(Self.joinGreen) }
                } else {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("Join")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, Spacing.md)
                    .frame(height: 30)
                    .background { Capsule().fill(Self.joinGreen) }
                }
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.06)
        .accessibilityLabel("Join \(title ?? "meeting")")
        .help("Join meeting")
    }

    /// A "leave by" nudge, turning solid when it's time to go. Informational, so it
    /// isn't a control — just an accessible readout.
    private func leaveChip(_ seconds: TimeInterval, title: String?) -> some View {
        let leaveNow = seconds <= 0
        let minutes = max(0, Int(seconds / 60))
        let text = leaveNow ? "Leave now" : "Leave in \(minutes)m"
        let spoken = leaveNow
            ? "Leave now for \(title ?? "your next event")"
            : "Leave in \(minutes) minutes for \(title ?? "your next event")"
        return Label(text, systemImage: "figure.walk")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(leaveNow ? .white : Theme.secondaryText)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.hair)
            .background { Capsule().fill(leaveNow ? Self.leaveNowOrange : Color.white.opacity(0.10)) }
            .padding(.top, Spacing.hair)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
    }

    // MARK: - Permission states

    private var requestPrompt: some View {
        permissionCard(icon: "calendar.badge.clock",
                       title: "Show your calendar in the notch",
                       message: "Grant Calendar access to browse your month and add events from the notch.",
                       button: "Grant Access") {
            manager.requestAccess()
        }
    }

    private var deniedPrompt: some View {
        permissionCard(icon: "calendar.badge.exclamationmark",
                       title: "Calendar access is off",
                       message: "Turn it on in System Settings → Privacy & Security → Calendars.",
                       button: "Open Settings") {
            Self.openPrivacySettings()
        }
    }

    private func permissionCard(icon: String, title: String, message: String,
                                button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(settings.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .bold))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button(action: action) {
                Text(button)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(settings.accent.readableForeground)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 32)
                    .background { Capsule().fill(settings.accent) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.05)
            .padding(.top, Spacing.hair)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    // System green / orange (matching the app's `Color(hex:)` convention), so the
    // Join and "leave now" affordances read as standard action colors, not theme.
    private static let joinGreen = Color(hex: "34C759") ?? .green
    private static let leaveNowOrange = Color(hex: "FF9F0A") ?? .orange

    private func color(for event: EKEvent) -> Color {
        if let cg = event.calendar?.cgColor { return Color(cgColor: cg) }
        return settings.accent
    }

    static func open(_ event: EKEvent) {
        // Prefer the event's own deep link; otherwise just bring Calendar forward.
        if let id = event.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else {
            openCalendarApp()
        }
    }

    static func openCalendarApp() {
        if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A single spoken line for VoiceOver, e.g. "3:30 PM, Standup, at Room B".
    static func rowAccessibilityLabel(_ event: EKEvent) -> String {
        var parts = [timeText(event), event.title ?? "Event"]
        if let loc = event.location, !loc.isEmpty { parts.append("at \(loc)") }
        return parts.joined(separator: ", ")
    }

    /// "All day", a single start time, or "start – end" for timed events.
    static func timeText(_ event: EKEvent) -> String {
        if event.isAllDay { return "All day" }
        guard let start = event.startDate else { return "" }
        return Self.time.string(from: start)
    }

    /// Localized weekday initials, rotated so the first column matches the user's
    /// `Calendar.firstWeekday`.
    static let weekdaySymbols: [String] = {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }()

    /// A spoken label for a grid cell, e.g. "Monday, August 3, 2 events".
    static func cellAccessibilityLabel(_ day: Date, hasEvents: Bool) -> String {
        var label = fullDay.string(from: day)
        if Calendar.current.isDateInToday(day) { label = "Today, " + label }
        if hasEvents { label += ", has events" }
        return label
    }

    /// "Today" / "Tomorrow" / weekday + date for a day section header.
    static func dayHeading(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        return Self.dayLabel.string(from: date).uppercased()
    }

    /// The kicker over the hero title.
    static func heroLabel(_ event: EKEvent?, _ now: Date) -> String {
        guard let event else { return "SCHEDULE" }
        if isOngoing(event, now) { return "HAPPENING NOW" }
        return "UP NEXT"
    }

    /// The hero countdown: to the start for an upcoming event, or to the end for
    /// one already in progress.
    static func heroCountdown(_ event: EKEvent, _ now: Date) -> String {
        // isOngoing() excludes all-day events, so this only fires for timed ones.
        if isOngoing(event, now) {
            return relative(event.endDate, from: now, prefix: "ends ")
        }
        return relative(event.startDate, from: now, prefix: "")
    }

    private static func isOngoing(_ event: EKEvent, _ now: Date) -> Bool {
        guard let start = event.startDate, let end = event.endDate else { return false }
        return start <= now && now < end && !event.isAllDay
    }

    /// A short countdown — seconds inside the final minute so it ticks, then
    /// "in 12m" / "in 3h 5m" / "in 2d". `prefix` lets callers say "ends in …".
    static func relative(_ date: Date?, from now: Date, prefix: String = "") -> String {
        guard let date else { return "" }
        let delta = date.timeIntervalSince(now)
        let body: String
        if delta <= 5 { body = "now" }
        else if delta < 60 { body = "in \(Int(delta))s" }
        else {
            let minutes = Int(delta / 60)
            if minutes < 60 { body = "in \(minutes)m" }
            else if minutes < 24 * 60 { body = "in \(minutes / 60)h \(minutes % 60)m" }
            else { body = "in \(minutes / 60 / 24)d" }
        }
        return prefix + body
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return f
    }()

    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        return f
    }()

    /// Full spoken date for accessibility (weekday, month, day).
    static let fullDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f
    }()
}

/// Finds a video-conferencing link on an event — the dedicated `url` field if it
/// points at a known provider, otherwise the first provider link scanned out of
/// the location or notes.
extension EKEvent {
    var meetingURL: URL? {
        if let u = url, let host = u.host?.lowercased(),
           ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"]
               .contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return u
        }
        let text = [location, notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for regex in Self.meetingPatterns {
            if let match = regex.firstMatch(in: text, range: whole) {
                return URL(string: ns.substring(with: match.range))
            }
        }
        return nil
    }

    /// Conferencing-link patterns, compiled once rather than on every render.
    private static let meetingPatterns: [NSRegularExpression] = [
        #"https://[\w.-]*zoom\.us/[^\s<>"']+"#,
        #"https://meet\.google\.com/[^\s<>"']+"#,
        #"https://teams\.microsoft\.com/[^\s<>"']+"#,
        #"https://[\w.-]*teams\.live\.com/[^\s<>"']+"#,
        #"https://[\w.-]*webex\.com/[^\s<>"']+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

extension Calendar {
    /// Midnight on the first day of the month containing `date`.
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

/// Loads and watches the system calendar. A shared singleton so the authorization
/// state and the fetched events survive tab switches, and so a single EventKit
/// store handles the change notifications for the whole app.
@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    private let store = EKEventStore()

    /// How far ahead the agenda looks.
    private let windowDays = 14

    @Published var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [EKEvent] = []

    /// The month shown in the grid (any first-of-month date) and the day whose
    /// events the list below shows. Both default to now. Moving the month reloads
    /// its events automatically, so the dots can never drift out of sync.
    @Published private(set) var visibleMonth: Date = Calendar.current.startOfMonth(for: Date()) {
        didSet { loadMonth() }
    }
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// Every event across the visible grid (the month plus its leading/trailing
    /// days), for the dots and the selected-day list.
    @Published private(set) var monthEvents: [EKEvent] = []

    /// The six weeks (42 days) drawn for `visibleMonth`, and the set of in-view
    /// days that hold at least one event — recomputed once per month load so the
    /// grid never rescans events per cell per render.
    @Published private(set) var gridDays: [Date] = []
    @Published private(set) var eventDays: Set<Date> = []

    /// When to leave for a specific event, once travel time is estimated. Tied to
    /// the event so the hero never shows one event's nudge against another.
    struct TravelNudge { let eventID: String; let leaveBy: Date }
    @Published private(set) var travel: TravelNudge?

    // Travel estimation reuses the map tab's CoreLocation wrapper. We only request
    // location — and only keep GPS running — while an upcoming event actually has a
    // location to route to, refreshed on a slow timer.
    private let locator = LocationManager()
    private var travelTimer: Timer?
    private var travelEventID: String?
    private var travelComputedAt: Date?
    private var locationSink: AnyCancellable?

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                               object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    var isAuthorized: Bool { status == .fullAccess }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
            reload()
        }
    }

    /// Re-checks the live authorization status (it can change in System Settings
    /// while we're backgrounded) and reloads if we're allowed in.
    func refreshStatusAndLoad() {
        status = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized { reload() }
    }

    func reload() {
        reloadEvents()
        loadMonth()
    }

    /// The forward window that feeds the hero + travel nudge (independent of the
    /// browsed month).
    private func reloadEvents() {
        guard isAuthorized else { events = []; travel = nil; locator.stop(); return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: windowDays, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        startTravelTimer()
        refreshTravel()
    }

    /// The soonest event that hasn't started yet (or an ongoing one), for the hero.
    func nextEvent(after now: Date) -> EKEvent? {
        events.first { ($0.startDate ?? .distantPast) >= now }
            ?? events.first { $0.endDate > now && !$0.isAllDay }
    }

    // MARK: - Month grid

    /// The 42 days (six weeks) for `month`, starting on the user's first weekday
    /// and spilling into the neighbouring months to fill the grid.
    static func gridDays(for month: Date) -> [Date] {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: month)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -offset, to: month) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    func hasEvents(on day: Date) -> Bool {
        eventDays.contains(Calendar.current.startOfDay(for: day))
    }

    func events(on day: Date) -> [EKEvent] {
        let cal = Calendar.current
        return monthEvents.filter { cal.isDate($0.startDate ?? .distantPast, inSameDayAs: day) }
    }

    /// Select a day, paging the visible month if it belongs to a neighbour
    /// (which reloads that month's events via `visibleMonth`'s `didSet`).
    func select(_ day: Date) {
        let cal = Calendar.current
        selectedDay = cal.startOfDay(for: day)
        if !cal.isDate(day, equalTo: visibleMonth, toGranularity: .month) {
            visibleMonth = cal.startOfMonth(for: day)
        }
    }

    func changeMonth(by delta: Int) {
        let cal = Calendar.current
        guard let month = cal.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        let newMonth = cal.startOfMonth(for: month)
        // Move the selection into the new month so the day list stays in sync —
        // today if it falls in view, otherwise the first of the month.
        selectedDay = cal.isDate(Date(), equalTo: newMonth, toGranularity: .month)
            ? cal.startOfDay(for: Date())
            : newMonth
        visibleMonth = newMonth
    }

    private func loadMonth() {
        let days = Self.gridDays(for: visibleMonth)
        gridDays = days
        guard isAuthorized, let first = days.first, let last = days.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else {
            monthEvents = []; eventDays = []; return
        }
        let cal = Calendar.current
        let predicate = store.predicateForEvents(withStart: first, end: end, calendars: nil)
        let loaded = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        monthEvents = loaded
        eventDays = Set(loaded.compactMap { $0.startDate.map { cal.startOfDay(for: $0) } })
    }

    /// Parse a natural-language line ("Lunch tomorrow 1pm") into an event and save
    /// it to the default calendar. A date/time in the text wins; otherwise the
    /// event lands on the selected day at the next hour. Reloads and jumps the grid
    /// to the new event.
    func addEvent(naturalText raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAuthorized, !trimmed.isEmpty, let calendar = store.defaultCalendarForNewEvents else { return }
        let cal = Calendar.current

        var title = trimmed
        var start: Date
        var duration: TimeInterval = 3600

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let matchDate = match.date {
            if let range = Range(match.range, in: trimmed) { title.removeSubrange(range) }
            start = matchDate
            // A bare time ("3pm") resolves to today; if the user is browsing another
            // day, honor that day and keep the parsed time.
            if cal.isDateInToday(matchDate) && !cal.isDateInToday(selectedDay) {
                let hm = cal.dateComponents([.hour, .minute], from: matchDate)
                start = cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0,
                                 second: 0, of: selectedDay) ?? matchDate
            }
            if match.duration > 0 { duration = match.duration }
        } else if cal.isDateInToday(selectedDay) {
            // No date given, today selected: the next top of the hour.
            start = cal.nextDate(after: Date(), matching: DateComponents(minute: 0),
                                 matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        } else {
            // No date given, another day selected: a sensible 9 AM default.
            start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = EKEvent(eventStore: store)
        event.title = title.isEmpty ? "New Event" : title
        event.startDate = start
        event.endDate = start.addingTimeInterval(duration)
        event.calendar = calendar
        guard (try? store.save(event, span: .thisEvent)) != nil else { return }

        // Jump the grid to the new event; setting visibleMonth reloads its month
        // via didSet. Refresh the hero window separately.
        selectedDay = cal.startOfDay(for: start)
        visibleMonth = cal.startOfMonth(for: start)
        reloadEvents()
    }

    // MARK: - Travel time

    /// The leave-by time for `event`, but only if the current estimate belongs to
    /// it — so the hero never attributes a stale nudge to the wrong event.
    func travelNudge(for event: EKEvent) -> Date? {
        guard let travel, travel.eventID == Self.travelKey(for: event) else { return nil }
        return travel.leaveBy
    }

    private static func travelKey(for event: EKEvent) -> String {
        event.eventIdentifier ?? event.location ?? ""
    }

    private func startTravelTimer() {
        guard travelTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTravel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        travelTimer = timer
        // Recompute as soon as the first fix lands, rather than waiting for the
        // next 60s tick. `refreshTravel`'s freshness gate keeps this from
        // re-routing on every GPS update.
        locationSink = locator.$location
            .compactMap { $0 }
            .sink { [weak self] _ in Task { @MainActor in self?.refreshTravel() } }
    }

    /// Estimate driving time to the next located event that starts within three
    /// hours, and derive when the user should leave. Location is requested — and
    /// GPS kept running — only while such an event exists; otherwise we stop
    /// updates and clear the nudge.
    private func refreshTravel() {
        let now = Date()
        guard let event = nextEvent(after: now),
              let location = event.location, !location.isEmpty,
              let start = event.startDate, start > now,
              start.timeIntervalSince(now) <= 3 * 3600 else {
            locator.stop()
            travel = nil
            travelEventID = nil
            travelComputedAt = nil
            return
        }
        // There's somewhere to be — now it's worth asking for location.
        locator.request()
        locator.start()
        guard let here = locator.location else { return }   // the location sink retries once a fix arrives
        let id = Self.travelKey(for: event)
        // Skip if we already have a fresh estimate for this event, so the location
        // sink doesn't re-route on every GPS update.
        let fresh = travelEventID == id && travelComputedAt.map { now.timeIntervalSince($0) < 300 } == true
        guard !fresh else { return }
        travelEventID = id
        travelComputedAt = now
        Task { await computeTravel(to: location, from: here, start: start, id: id) }
    }

    private func computeTravel(to locationText: String, from here: CLLocation,
                               start: Date, id: String) async {
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = locationText
        search.region = MKCoordinateRegion(center: here.coordinate,
                                           latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        guard let destination = try? await MKLocalSearch(request: search).start().mapItems.first
        else { return }

        let directions = MKDirections.Request()
        directions.source = .forCurrentLocation()
        directions.destination = destination
        directions.transportType = .automobile
        guard let eta = try? await MKDirections(request: directions).calculateETA() else { return }

        // Bail if the hero event moved on while we were geocoding.
        guard travelEventID == id else { return }
        travel = TravelNudge(eventID: id, leaveBy: start.addingTimeInterval(-eta.expectedTravelTime))
    }
}
