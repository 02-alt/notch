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
            if isAdding { addForm }
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
        VStack(spacing: Spacing.sm) {
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
            HStack(spacing: Spacing.sm) {
                DatePicker("", selection: $newDate, displayedComponents: [.date, .hourAndMinute])
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
