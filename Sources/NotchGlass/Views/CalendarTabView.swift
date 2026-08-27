import SwiftUI
import AppKit
import EventKit

/// An at-a-glance agenda of the days ahead, pulled from the system Calendar via
/// EventKit. A hero line up top counts down to the next thing on the schedule; a
/// scrolling list groups the coming events by day, each row showing its time, a
/// dot in its calendar's color, the title and any location. Clicking a row opens
/// it in Calendar.app.
///
/// Access is requested lazily — the tab shows a friendly prompt until the user
/// grants Calendar access, and a route to System Settings if they've said no.
struct CalendarTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var manager = CalendarManager.shared

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
        VStack(alignment: .leading, spacing: 12) {
            header
            if manager.days.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(manager.days, id: \.date) { day in
                            daySection(day.date, events: day.events)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    /// The hero row: the next event and how far off it is, plus a jump into
    /// Calendar.app for anything the compact agenda doesn't cover.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.nextEvent(after: context.date) == nil ? "SCHEDULE" : "UP NEXT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .kerning(0.6)
                    if let next = manager.nextEvent(after: context.date) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(color(for: next))
                                .frame(width: 8, height: 8)
                            Text(next.title ?? "Event")
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(1)
                            Text(Self.relative(next.startDate, from: context.date))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(settings.accent)
                        }
                    } else {
                        Text("Nothing coming up")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                Spacer(minLength: 0)
                Button { Self.openCalendarApp() } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(Color.white.opacity(0.10)) }
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.08)
                .help("Open Calendar")
            }
        }
    }

    private func daySection(_ date: Date, events: [EKEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.dayHeading(date))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
                .kerning(0.5)
            ForEach(events, id: \.eventIdentifier) { event in
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        Button { Self.open(event) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(Self.timeText(event))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 62, alignment: .leading)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: event))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 1) {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .innerCard(cornerRadius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.01)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text("No events in the next two weeks.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Permission states

    private var requestPrompt: some View {
        permissionCard(icon: "calendar.badge.clock",
                       title: "Show your calendar in the notch",
                       message: "Grant Calendar access to see the days ahead at a glance.",
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
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(settings.accent)
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
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background { Capsule().fill(settings.accent) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.05)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

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

    /// "All day", a single start time, or "start – end" for timed events.
    static func timeText(_ event: EKEvent) -> String {
        if event.isAllDay { return "All day" }
        guard let start = event.startDate else { return "" }
        return Self.time.string(from: start)
    }

    /// "Today" / "Tomorrow" / weekday + date for a day section header.
    static func dayHeading(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        return Self.dayLabel.string(from: date).uppercased()
    }

    /// A short "in 12m" / "in 3h" / "now" countdown for the hero line.
    static func relative(_ date: Date?, from now: Date) -> String {
        guard let date else { return "" }
        let delta = date.timeIntervalSince(now)
        if delta <= 60 { return "now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours)h \(minutes % 60)m" }
        return "in \(hours / 24)d"
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
        guard isAuthorized else { events = []; return }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: windowDays, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// The soonest event that hasn't started yet (or an ongoing one), for the hero.
    func nextEvent(after now: Date) -> EKEvent? {
        events.first { ($0.startDate ?? .distantPast) >= now }
            ?? events.first { $0.endDate > now && !$0.isAllDay }
    }

    /// The events grouped by calendar day, each day's list in time order.
    var days: [(date: Date, events: [EKEvent])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: events) { cal.startOfDay(for: $0.startDate ?? Date()) }
        return groups.keys.sorted().map { key in
            (key, groups[key]!.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) })
        }
    }
}
