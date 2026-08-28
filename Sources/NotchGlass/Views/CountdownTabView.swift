import SwiftUI

/// The Countdown tab — pin the dates you're counting toward (a launch, a trip, a
/// birthday) and see the time left at a glance. The nearest upcoming date is the
/// hero; the rest stack below. Events persist as JSON in `@AppStorage`, and a
/// `TimelineView` keeps the numbers live. Panel-native (``Theme`` + `settings.accent`)
/// so it adapts to every panel surface.
struct CountdownTabView: View {
    @EnvironmentObject private var settings: SettingsStore

    @AppStorage("countdown.events") private var eventsJSON = "[]"
    @State private var isAdding = false
    @State private var newTitle = ""
    @State private var newDate = Date().addingTimeInterval(86_400)

    private var events: [CountdownEvent] {
        let list = (try? JSONDecoder().decode([CountdownEvent].self, from: Data(eventsJSON.utf8))) ?? []
        // Soonest upcoming first; past events sink to the bottom (still shown, as an
        // "elapsed" reminder until removed).
        return list.sorted { a, b in
            let now = Date()
            let aPast = a.date < now, bPast = b.date < now
            if aPast != bPast { return !aPast }
            return a.date < b.date
        }
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            header
            // The add form is static — keep it out of the ticking TimelineView so
            // the month grid isn't rebuilt (and its DatePicker re-diffed) every second.
            if isAdding { addForm }
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                content(now: context.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("COUNTDOWN")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .kerning(0.6)
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isAdding.toggle() }
            } label: {
                Image(systemName: isAdding ? "xmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 24, height: 24)
                    .background { Circle().fill(Theme.line(0.10)) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.08)
            .help("Add a countdown")
        }
    }

    private func content(now: Date) -> some View {
        VStack(spacing: Spacing.base) {
            let all = events
            if all.isEmpty && !isAdding {
                emptyState
            } else if let hero = all.first {
                heroCard(hero, now: now)
                if all.count > 1 {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: Spacing.sm) {
                            ForEach(all.dropFirst()) { event in
                                row(event, now: now)
                            }
                        }
                        .padding(.vertical, Spacing.hair)
                    }
                }
            }
        }
        // Pin to the top under the header — otherwise the enclosing full-height
        // frame centres the form/hero vertically, leaving a gap under the tab bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Hero

    private func heroCard(_ event: CountdownEvent, now: Date) -> some View {
        let parts = Self.breakdown(to: event.date, from: now)
        return VStack(spacing: Spacing.sm) {
            Text(event.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                heroUnit(parts.days, "days")
                heroUnit(parts.hours, "hrs")
                heroUnit(parts.minutes, "min")
            }
            Text(parts.past
                 ? "\(Self.longDate(event.date)) · elapsed"
                 : Self.longDate(event.date))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(parts.past ? settings.accent : Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.base)
        .padding(.horizontal, Spacing.base)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(settings.accent.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(settings.accent.opacity(0.35), lineWidth: 1)
                }
        }
        .contextMenu { removeButton(event) }
    }

    private func heroUnit(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .textCase(.uppercase)
        }
    }

    // MARK: List row

    private func row(_ event: CountdownEvent, now: Date) -> some View {
        let parts = Self.breakdown(to: event.date, from: now)
        return HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(Self.mediumDate(event.date))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            Text(parts.past ? "elapsed" : "\(parts.days)d \(parts.hours)h")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(parts.past ? Theme.tertiaryText : settings.accent)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: 44)
        .innerCard(cornerRadius: 12)
        .contextMenu { removeButton(event) }
    }

    private func removeButton(_ event: CountdownEvent) -> some View {
        Button(role: .destructive) { remove(event) } label: {
            Label("Remove \(event.title)", systemImage: "minus.circle")
        }
    }

    // MARK: Add form

    private var addForm: some View {
        VStack(spacing: Spacing.base) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                TextField("What are you counting down to?", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .tint(settings.accent)
                    .onSubmit(commit)
            }
            MonthCalendar(selection: $newDate, accent: settings.accent)
            HStack(spacing: Spacing.sm) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                DatePicker("", selection: $newDate, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(settings.accent)
                Spacer(minLength: 0)
                Button("Add", action: commit)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(settings.accent.readableForeground)
                    .padding(.horizontal, Spacing.base)
                    .frame(height: 28)
                    .background { Capsule().fill(settings.accent) }
                    .notchHover(scale: 1.05)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(newTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .padding(Spacing.base)
        .innerCard(cornerRadius: 14)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "hourglass")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Text("No countdowns yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text("Tap + to pin a date.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Storage

    private func setEvents(_ list: [CountdownEvent]) {
        if let data = try? JSONEncoder().encode(list) {
            eventsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func commit() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        setEvents(events + [CountdownEvent(title: title, date: newDate)])
        newTitle = ""
        newDate = Date().addingTimeInterval(86_400)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isAdding = false }
    }

    private func remove(_ event: CountdownEvent) {
        setEvents(events.filter { $0.id != event.id })
    }

    // MARK: Formatting

    /// Whole days / hours / minutes remaining (or elapsed, with `past = true`).
    static func breakdown(to date: Date, from now: Date) -> (days: Int, hours: Int, minutes: Int, past: Bool) {
        let interval = date.timeIntervalSince(now)
        let past = interval < 0
        let secs = Int(abs(interval))
        return (secs / 86_400, (secs % 86_400) / 3600, (secs % 3600) / 60, past)
    }

    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyyjmm")
        return f.string(from: date)
    }

    static func mediumDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EdMMMyyyy")
        return f.string(from: date)
    }
}

/// A single pinned countdown target.
struct CountdownEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
}

/// A compact month grid for picking the countdown's day — a simpler, more visual
/// stand-in for the system `DatePicker`'s date popover. Only the day changes here;
/// the selection's time-of-day is preserved so the sibling time picker owns it.
///
/// Laid out on the app's `Spacing` scale (a `Spacing.hair` gutter between cells,
/// matching the 2pt data-surface gap) and framed as an inset Liquid Glass panel —
/// the shared black glass, so it reads as one of the app's own surfaces. The accent
/// is reserved for the single selected day; `today` gets a hairline ring only.
private struct MonthCalendar: View {
    @Binding var selection: Date
    let accent: Color

    /// The month on show — starts on the selected date's month, then follows the
    /// chevrons independently of which day is picked.
    @State private var visibleMonth: Date

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.hair), count: 7)

    init(selection: Binding<Date>, accent: Color) {
        _selection = selection
        self.accent = accent
        _visibleMonth = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            monthBar
            weekdayRow
            LazyVGrid(columns: columns, spacing: Spacing.hair) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 30) }
                }
            }
        }
        .padding(Spacing.sm)
        .glassCard(cornerRadius: 12)
    }

    // MARK: Header

    private var monthBar: some View {
        HStack {
            chevron("chevron.left", by: -1)
            Spacer(minLength: 0)
            Text(Self.monthTitle.string(from: visibleMonth))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            chevron("chevron.right", by: 1)
        }
    }

    private func chevron(_ name: String, by delta: Int) -> some View {
        Button {
            if let m = cal.date(byAdding: .month, value: delta, to: visibleMonth) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { visibleMonth = m }
            }
        } label: {
            Image(systemName: name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 24, height: 24)
                .background { Circle().fill(Theme.line(0.10)) }
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.1)
    }

    private var weekdayRow: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    // MARK: Day cell

    private func dayCell(_ day: Date) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selection)
        let isToday = cal.isDateInToday(day)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { pick(day) }
        } label: {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 12, weight: isSelected ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isSelected ? accent.readableForeground
                                 : isToday ? accent : Theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background { shape.fill(isSelected ? accent : .clear) }
                .overlay {
                    if isToday && !isSelected {
                        shape.strokeBorder(accent.opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.06)
    }

    // MARK: Model

    /// Applies the tapped day to `selection` while preserving its time-of-day.
    private func pick(_ day: Date) {
        let time = cal.dateComponents([.hour, .minute], from: selection)
        var dc = cal.dateComponents([.year, .month, .day], from: day)
        dc.hour = time.hour
        dc.minute = time.minute
        if let merged = cal.date(from: dc) { selection = merged }
    }

    /// Leading blanks (to align the 1st under its weekday) followed by each day of
    /// the visible month; `nil` renders an empty slot.
    private var cells: [Date?] {
        let comps = cal.dateComponents([.year, .month], from: visibleMonth)
        guard let monthStart = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        let weekdayOfFirst = cal.component(.weekday, from: monthStart)
        let leading = (weekdayOfFirst - cal.firstWeekday + 7) % 7
        let days = range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: monthStart) }
        return Array(repeating: nil, count: leading) + days as [Date?]
    }

    /// Single-letter weekday headers, rotated to the locale's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortWeekdaySymbols
        return (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
    }

    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }()
}
