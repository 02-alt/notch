import SwiftUI
import AppKit

/// A clock + kitchen-timer tab. Two modes swap in place via a small pill selector:
///
/// - **Clock** — a big live local time on the left, and a column of world clocks on
///   the right (each showing the city's current time and its offset from you). Cities
///   are added from a menu of common zones and removed on hover; the chosen set is
///   persisted as JSON so it survives relaunches.
/// - **Timer** — a countdown with a progress ring and a grid of one-tap presets
///   (soft/hard egg, the common pasta shapes with their box cook times, tea, coffee,
///   a steak rest). The countdown lives in a shared ``CountdownTimer`` so it keeps
///   running — and still chimes — while you're on another tab or the panel is closed.
struct ClockTabView: View {
    @EnvironmentObject private var settings: SettingsStore

    /// Persisted so the tab reopens in whichever mode you left it.
    @AppStorage("clock.mode") private var modeRaw = ClockMode.clock.rawValue
    /// The chosen world-clock cities, stored as a JSON array of TZ identifiers.
    @AppStorage("clock.zones") private var zonesJSON = ClockTabView.defaultZonesJSON
    /// The user's own timers, stored as a JSON array of ``CustomTimer``.
    @AppStorage("clock.customTimers") private var customTimersJSON = "[]"
    /// The timer category currently shown in the preset grid.
    @AppStorage("clock.timerCategory") private var timerCategoryRaw = TimerCategory.eggs.rawValue

    /// Whether the inline "add a timer" form is showing.
    @State private var isAddingTimer = false
    @State private var newTimerName = ""
    @State private var newTimerMinutes = ""
    @State private var newTimerSeconds = ""

    @ObservedObject private var timer = CountdownTimer.shared
    @ObservedObject private var pomodoro = PomodoroTimer.shared

    private var mode: ClockMode {
        get { ClockMode(rawValue: modeRaw) ?? .clock }
        nonmutating set { modeRaw = newValue.rawValue }
    }

    private var timerCategory: TimerCategory {
        get { TimerCategory(rawValue: timerCategoryRaw) ?? .eggs }
        nonmutating set { timerCategoryRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            modePills
            Group {
                switch mode {
                case .clock:    clockPane
                case .timer:    timerPane
                case .pomodoro: pomodoroPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Mode selector

    private var modePills: some View {
        HStack(spacing: Spacing.s) {
            ForEach(ClockMode.allCases) { m in
                let on = mode == m
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = m } } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: m.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(m.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(on ? settings.accent.readableForeground : Theme.secondaryText)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 28)
                    .background {
                        Capsule(style: .continuous)
                            .fill(on ? settings.accent : Color.white.opacity(0.08))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.04)
            }
            Spacer(minLength: 0)
            // A running timer stays visible from the Clock mode as a small chip, so
            // you can see the countdown without switching back.
            if mode == .clock && timer.isActive {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Button { withAnimation { mode = .timer } } label: {
                        HStack(spacing: Spacing.s) {
                            Image(systemName: timer.finished ? "bell.fill" : "timer")
                                .font(.system(size: 11, weight: .semibold))
                            Text(timer.finished ? "Done" : Self.clockString(timer.remaining))
                                .font(.system(size: 12, weight: .bold).monospacedDigit())
                        }
                        .foregroundStyle(timer.finished ? settings.accent : .white)
                        .padding(.horizontal, Spacing.base)
                        .frame(height: 28)
                        .background { Capsule().fill(Color.white.opacity(0.08)) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .notchHover(scale: 1.04)
                }
            }
            // Likewise a running Focus session stays glanceable from the Clock face.
            if mode == .clock && pomodoro.isActive {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let tint = pomodoro.phase.isBreak ? Self.breakGreen : settings.accent
                    Button { withAnimation { mode = .pomodoro } } label: {
                        HStack(spacing: Spacing.s) {
                            Image(systemName: pomodoro.phase.symbol)
                                .font(.system(size: 11, weight: .semibold))
                            Text(Self.clockString(pomodoro.remaining))
                                .font(.system(size: 12, weight: .bold).monospacedDigit())
                        }
                        .foregroundStyle(tint)
                        .padding(.horizontal, Spacing.base)
                        .frame(height: 28)
                        .background { Capsule().fill(Color.white.opacity(0.08)) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .notchHover(scale: 1.04)
                }
            }
        }
    }

    // MARK: - Clock mode

    private var clockPane: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            HStack(alignment: .top, spacing: Spacing.lg) {
                localClock(now: context.date)
                    .frame(width: 220)
                Divider().overlay(Color.white.opacity(0.10))
                worldClocks(now: context.date)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The hero local clock: a large analog face (matching the world dials) over a
    /// clean digital time, the weekday + date, and your city — centered so the left
    /// column reads as one deliberate block rather than a lone oversized number.
    private func localClock(now: Date) -> some View {
        let a = Self.handAngles(now, tz: .current)
        return VStack(spacing: Spacing.base) {
            Spacer(minLength: 0)
            ClockFace(hour: a.hour, minute: a.minute, second: a.second,
                      accent: settings.accent, size: 132)
            VStack(spacing: Spacing.xs) {
                Text(Self.timeString(now, tz: .current))
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(Self.dateString(now, tz: .current))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: Spacing.s) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(settings.accent)
                    Text(Self.cityName(for: .current))
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.top, Spacing.hair)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func worldClocks(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("WORLD")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .kerning(0.6)
                Spacer(minLength: 0)
                addCityMenu
            }
            if zones.isEmpty {
                Text("Add a city to compare time zones.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.md), count: 3),
                              spacing: Spacing.base) {
                        ForEach(zones, id: \.self) { id in
                            worldCell(id: id, now: now)
                        }
                    }
                    .padding(.vertical, Spacing.hair)
                }
            }
        }
    }

    /// One world clock: a live analog face with the city name, its digital time and
    /// the day/offset stacked underneath. Right-click to remove it.
    private func worldCell(id: String, now: Date) -> some View {
        let tz = TimeZone(identifier: id) ?? .current
        let a = Self.handAngles(now, tz: tz)
        return VStack(spacing: Spacing.s) {
            ClockFace(hour: a.hour, minute: a.minute, second: a.second,
                      accent: settings.accent, size: 58)
            VStack(spacing: 0) {
                Text(Self.cityName(for: tz))
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.timeString(now, tz: tz))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                if let day = Self.dayLabel(for: tz, now: now) {
                    Text(day)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(day == "Yesterday" ? Color.orange : settings.accent)
                } else {
                    Text(Self.offsetLabel(for: tz, now: now))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { removeZone(id) } label: {
                Label("Remove \(Self.cityName(for: tz))", systemImage: "minus.circle")
            }
        }
    }

    private var addCityMenu: some View {
        Menu {
            ForEach(Self.cityCatalog, id: \.id) { city in
                Button {
                    addZone(city.id)
                } label: {
                    if zones.contains(city.id) { Label(city.name, systemImage: "checkmark") }
                    else { Text(city.name) }
                }
                .disabled(zones.contains(city.id))
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background { Circle().fill(Color.white.opacity(0.10)) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a city")
    }

    // MARK: - Timer mode

    private var timerPane: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            countdown
                .frame(width: 250)
            Divider().overlay(Color.white.opacity(0.10))
            presetGrid
                .frame(maxWidth: .infinity)
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let active = timer.isActive
            let progress = timer.progress
            VStack(spacing: Spacing.base) {
                Spacer(minLength: 0)
                TimerDial(progress: progress,
                          tint: timer.finished ? Color.green : settings.accent) {
                    VStack(spacing: Spacing.hair) {
                        Text(timer.finished ? "Done" : Self.clockString(timer.remaining))
                            .font(.system(size: timer.finished ? 30 : 38, weight: .light).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if !timer.label.isEmpty {
                            Text(timer.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(Spacing.xl)
                }

                controls(active: active)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func controls(active: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            if timer.finished {
                capsuleButton(title: "Dismiss", symbol: "checkmark", filled: true) {
                    timer.stop()
                }
            } else if active {
                capsuleButton(title: timer.paused ? "Resume" : "Pause",
                              symbol: timer.paused ? "play.fill" : "pause.fill",
                              filled: timer.paused) {
                    timer.paused ? timer.resume() : timer.pause()
                }
                capsuleButton(title: "Stop", symbol: "stop.fill", filled: false) {
                    timer.stop()
                }
            } else {
                Text("Pick a preset →")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(height: 30)
            }
        }
    }

    private func capsuleButton(title: String, symbol: String, filled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(filled ? settings.accent.readableForeground : .white)
            .padding(.horizontal, Spacing.base)
            .frame(height: 30)
            .background {
                Capsule().fill(filled ? settings.accent : Color.white.opacity(0.10))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.04)
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            categoryRow
            if isAddingTimer { addTimerForm }
            if timerCategory == .custom && customTimers.isEmpty && !isAddingTimer {
                Text("Tap + to add your own timer.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.md), count: 3),
                              spacing: Spacing.base) {
                        ForEach(presetsInCategory) { preset in
                            presetCell(preset)
                        }
                    }
                    .padding(.vertical, Spacing.hair)
                }
            }
            if timerCategory != .custom {
                Text("Cook times are from the box — taste as you go.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// The presets shown for the selected category — built-ins, or the user's own
    /// timers in the Custom bucket.
    private var presetsInCategory: [TimerPreset] {
        timerCategory == .custom
            ? customTimers.map(TimerPreset.init(custom:))
            : TimerPreset.all.filter { $0.category == timerCategory }
    }

    /// The category selector: a scrolling row of pills, with a trailing "+" that
    /// jumps to the Custom bucket and opens the add-a-timer form.
    private var categoryRow: some View {
        HStack(spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(TimerCategory.allCases) { c in
                        categoryPill(c)
                    }
                }
                .padding(.vertical, Spacing.hair)
            }
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    timerCategory = .custom
                    isAddingTimer.toggle()
                }
            } label: {
                Image(systemName: isAddingTimer ? "xmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background { Circle().fill(Color.white.opacity(0.10)) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.08)
            .help("Add your own timer")
        }
    }

    private func categoryPill(_ c: TimerCategory) -> some View {
        let on = timerCategory == c
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { timerCategory = c }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: c.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(c.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(on ? settings.accent.readableForeground : Theme.secondaryText)
            .padding(.horizontal, Spacing.md)
            .frame(height: 24)
            .background {
                Capsule(style: .continuous)
                    .fill(on ? settings.accent : Color.white.opacity(0.08))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.04)
    }

    /// One preset tile. Custom timers add a right-click "Remove".
    private func presetCell(_ preset: TimerPreset) -> some View {
        let on = timer.label == preset.name && timer.isActive
        return Button { timer.start(duration: preset.seconds, label: preset.name) } label: {
            VStack(spacing: Spacing.s) {
                ClockFace(hour: preset.hourAngle, minute: preset.minuteAngle,
                          light: on, accent: settings.accent, size: 58)
                VStack(spacing: 0) {
                    Text(preset.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(on ? settings.accent : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(preset.durationLabel)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.06)
        .contextMenu {
            if let id = preset.customID {
                Button(role: .destructive) { removeCustomTimer(id) } label: {
                    Label("Remove \(preset.name)", systemImage: "minus.circle")
                }
            }
        }
    }

    /// Inline form to name and time a custom timer.
    private var addTimerForm: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "timer")
                .foregroundStyle(Theme.secondaryText)
            TextField("Name", text: $newTimerName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .onSubmit(commitCustomTimer)
            HStack(spacing: Spacing.xs) {
                TextField("00", text: $newTimerMinutes)
                    .textFieldStyle(.plain)
                    .frame(width: 26)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitCustomTimer)
                Text("m").foregroundStyle(Theme.tertiaryText)
                TextField("00", text: $newTimerSeconds)
                    .textFieldStyle(.plain)
                    .frame(width: 26)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitCustomTimer)
                Text("s").foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            Button("Add", action: commitCustomTimer)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(settings.accent)
                .notchHover(scale: 1.08)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.sm)
        .innerCard(cornerRadius: 12)
    }

    private func commitCustomTimer() {
        let name = newTimerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = TimeInterval((Int(newTimerMinutes) ?? 0) * 60 + (Int(newTimerSeconds) ?? 0))
        guard !name.isEmpty, total > 0 else { return }
        addCustomTimer(name: name, seconds: total)
        newTimerName = ""; newTimerMinutes = ""; newTimerSeconds = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isAddingTimer = false }
    }

    // MARK: - Pomodoro (Focus) mode

    /// The green used for break phases and the focus tally, so a glance tells work
    /// (accent) from rest (green) apart even before reading the label.
    static let breakGreen = Color(red: 0.40, green: 0.80, blue: 0.52)

    /// A focus dial on the left (same ring language as the kitchen timer) with the
    /// current phase, its countdown and the cycle progress dots; a compact settings
    /// column on the right tunes the focus/break lengths and the long-break cadence.
    private var pomodoroPane: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            pomodoroDial
                .frame(width: 250)
            Divider().overlay(Color.white.opacity(0.10))
            pomodoroSettings
                .frame(maxWidth: .infinity)
        }
    }

    private var pomodoroDial: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let tint = pomodoro.phase.isBreak ? Self.breakGreen : settings.accent
            let progress = pomodoro.progress
            VStack(spacing: Spacing.base) {
                Spacer(minLength: 0)
                TimerDial(progress: progress, tint: tint) {
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: pomodoro.phase.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(Self.clockString(pomodoro.remaining))
                            .font(.system(size: 36, weight: .light).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(pomodoro.phase.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(Spacing.xl)
                }

                cycleDots(tint: tint)
                pomodoroControls
                Spacer(minLength: 0)
            }
        }
    }

    /// One dot per focus session in the run up to a long break; filled as each
    /// session completes, so you can see how far you are into the cycle.
    private func cycleDots(tint: Color) -> some View {
        HStack(spacing: Spacing.s) {
            ForEach(0..<max(1, pomodoro.focusRounds), id: \.self) { i in
                Circle()
                    .fill(i < pomodoro.completedFocus ? tint : Color.white.opacity(0.15))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var pomodoroControls: some View {
        HStack(spacing: Spacing.sm) {
            capsuleButton(title: pomodoro.isRunning ? "Pause" : (pomodoro.paused ? "Resume" : "Start"),
                          symbol: pomodoro.isRunning ? "pause.fill" : "play.fill",
                          filled: !pomodoro.isRunning) {
                pomodoro.toggle()
            }
            if pomodoro.isActive {
                capsuleButton(title: "Stop", symbol: "stop.fill", filled: false) {
                    pomodoro.stop()
                }
            }
            capsuleButton(title: "Skip", symbol: "forward.fill", filled: false) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pomodoro.skip() }
            }
        }
    }

    private var pomodoroSettings: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("SESSION")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .kerning(0.6)
                Spacer(minLength: 0)
                Label("\(pomodoro.totalFocus)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Self.breakGreen)
                    .help("Focus sessions finished this run")
            }
            stepperRow("Focus", value: pomodoro.focusMinutes, unit: "m", range: 5...90, step: 5) {
                pomodoro.focusMinutes = $0
            }
            stepperRow("Short break", value: pomodoro.shortBreakMinutes, unit: "m", range: 1...30) {
                pomodoro.shortBreakMinutes = $0
            }
            stepperRow("Long break", value: pomodoro.longBreakMinutes, unit: "m", range: 5...45, step: 5) {
                pomodoro.longBreakMinutes = $0
            }
            stepperRow("Rounds", value: pomodoro.focusRounds, unit: "", range: 2...8) {
                pomodoro.focusRounds = $0
            }
            Toggle(isOn: Binding(get: { pomodoro.autoContinue },
                                 set: { pomodoro.autoContinue = $0 })) {
                Text("Auto-start next")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(settings.accent)
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.hair)
            Spacer(minLength: 0)
        }
    }

    /// A labeled −/＋ stepper row, styled like the rest of the tab's inner cards.
    private func stepperRow(_ title: String, value: Int, unit: String,
                            range: ClosedRange<Int>, step: Int = 1,
                            set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            stepButton("minus") { if value - step >= range.lowerBound { set(value - step) } }
            Text("\(value)\(unit)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 30)
            stepButton("plus") { if value + step <= range.upperBound { set(value + step) } }
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: 32)
        .innerCard(cornerRadius: 12)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background { Circle().fill(Color.white.opacity(0.10)) }
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.1)
    }

    // MARK: - World-clock storage

    private var zones: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(zonesJSON.utf8))) ?? []
    }

    private func setZones(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) {
            zonesJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func addZone(_ id: String) {
        guard !zones.contains(id) else { return }
        setZones(zones + [id])
    }

    private func removeZone(_ id: String) {
        setZones(zones.filter { $0 != id })
    }

    // MARK: - Custom-timer storage

    private var customTimers: [CustomTimer] {
        (try? JSONDecoder().decode([CustomTimer].self, from: Data(customTimersJSON.utf8))) ?? []
    }

    private func setCustomTimers(_ list: [CustomTimer]) {
        if let data = try? JSONEncoder().encode(list) {
            customTimersJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func addCustomTimer(name: String, seconds: TimeInterval) {
        setCustomTimers(customTimers + [CustomTimer(name: name, seconds: seconds)])
    }

    private func removeCustomTimer(_ id: UUID) {
        setCustomTimers(customTimers.filter { $0.id != id })
    }
}

// MARK: - Formatting & catalog

extension ClockTabView {
    static let defaultZonesJSON = #"["America/New_York","Europe/London","Asia/Tokyo"]"#

    /// A city label + its time-zone identifier, for the "add city" menu.
    struct City { let name: String; let id: String }

    /// A curated list of common world cities offered in the add menu.
    static let cityCatalog: [City] = [
        City(name: "Honolulu", id: "Pacific/Honolulu"),
        City(name: "Los Angeles", id: "America/Los_Angeles"),
        City(name: "Denver", id: "America/Denver"),
        City(name: "Chicago", id: "America/Chicago"),
        City(name: "New York", id: "America/New_York"),
        City(name: "São Paulo", id: "America/Sao_Paulo"),
        City(name: "London", id: "Europe/London"),
        City(name: "Paris", id: "Europe/Paris"),
        City(name: "Berlin", id: "Europe/Berlin"),
        City(name: "Moscow", id: "Europe/Moscow"),
        City(name: "Dubai", id: "Asia/Dubai"),
        City(name: "Mumbai", id: "Asia/Kolkata"),
        City(name: "Singapore", id: "Asia/Singapore"),
        City(name: "Hong Kong", id: "Asia/Hong_Kong"),
        City(name: "Tokyo", id: "Asia/Tokyo"),
        City(name: "Sydney", id: "Australia/Sydney"),
        City(name: "Auckland", id: "Pacific/Auckland"),
    ]

    /// City name from a zone: the identifier's last path component, de-underscored,
    /// preferring our catalog's nicer labels when it's a zone we know.
    static func cityName(for tz: TimeZone) -> String {
        if let known = cityCatalog.first(where: { $0.id == tz.identifier }) { return known.name }
        return tz.identifier
            .split(separator: "/").last
            .map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
    }

    static func timeString(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }


    static func dateString(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: date)
    }

    /// The whole-day boundary each zone is on, as a day index since the epoch, so we
    /// can label a city "Tomorrow" / "Yesterday" when it's crossed midnight vs. you.
    private static func dayIndex(for tz: TimeZone, now: Date) -> Int {
        let shifted = now.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: now))
        return Int(floor(shifted / 86_400))
    }

    static func dayLabel(for tz: TimeZone, now: Date) -> String? {
        let delta = dayIndex(for: tz, now: now) - dayIndex(for: .current, now: now)
        switch delta {
        case 0:            return nil
        case 1:            return "Tomorrow"
        case -1:           return "Yesterday"
        case let d where d > 1:  return "+\(d) days"
        default:           return "\(delta) days"
        }
    }

    /// Signed hour offset from the user's own zone, e.g. "+5h", "−3½h", "Same time".
    static func offsetLabel(for tz: TimeZone, now: Date) -> String {
        let diff = tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        if diff == 0 { return "Same time" }
        let sign = diff > 0 ? "+" : "−"
        let hours = Double(abs(diff)) / 3600
        let whole = Int(hours)
        let hasHalf = abs(hours - Double(whole)) > 0.01
        return "\(sign)\(whole)\(hasHalf ? "½" : "")h"
    }

    /// mm:ss, or h:mm:ss once past an hour. Ceils so a fresh 9:00 timer reads 9:00,
    /// not 8:59.
    static func clockString(_ t: TimeInterval) -> String {
        let s = max(0, Int(ceil(t)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }

    /// Analog hand angles (degrees clockwise from 12) for `date` read in `tz`.
    static func handAngles(_ date: Date, tz: TimeZone) -> (hour: Double, minute: Double, second: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let h = Double(c.hour ?? 0), m = Double(c.minute ?? 0), s = Double(c.second ?? 0)
        let minute = m + s / 60
        let hour = h.truncatingRemainder(dividingBy: 12) + minute / 60
        return (hour / 12 * 360, minute / 60 * 360, s / 60 * 360)
    }
}

/// A round clock face: a tick-ringed disc with hour/minute hands (and an optional
/// second hand). Used both for the world clocks — hands pointing to each city's live
/// time — and the timer presets, where the hands point to the cook duration. Pass
/// `light: true` to invert it to a white face (the running / selected preset), the
/// way the reference "duration" selector highlights its active choice.
private struct ClockFace: View {
    /// Hand angles in degrees clockwise from 12 o'clock.
    let hour: Double
    let minute: Double
    var second: Double? = nil
    var light = false
    var accent: Color
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            Circle().fill(light ? Color.white : Color.white.opacity(0.06))
            DialTicks(major: light ? Color.black.opacity(0.30) : Color.white.opacity(0.28),
                      minor: light ? Color.black.opacity(0.15) : Color.white.opacity(0.12))
                .padding(Spacing.xs)
            hand(length: size * 0.24, width: 3, angle: hour,
                 color: light ? .black : .white)
            hand(length: size * 0.36, width: 2.4, angle: minute,
                 color: light ? .black : .white)
            if let second {
                hand(length: size * 0.38, width: 1, angle: second, color: accent)
            }
            Circle()
                .fill(accent)
                .frame(width: 4.5, height: 4.5)
        }
        .frame(width: size, height: size)
    }

    /// A single hand, pivoting at the face's center (the offset+rotate pattern used
    /// for the ticks, so the hand's base sits on the middle dot).
    private func hand(length: CGFloat, width: CGFloat, angle: Double, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
    }
}

/// A ring of clock tick marks around the edge of its container — every 4th tick is
/// longer/heavier (the "hour" marks) so it reads as a dial. Used by both the preset
/// dials and the main countdown ring.
private struct DialTicks: View {
    let major: Color
    let minor: Color
    var count = 48

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let isMajor = i % 4 == 0
                    Capsule()
                        .fill(isMajor ? major : minor)
                        .frame(width: isMajor ? 2 : 1.4, height: isMajor ? 7 : 4)
                        .offset(y: -(radius - (isMajor ? 6 : 5)))
                        .rotationEffect(.degrees(Double(i) / Double(count) * 360))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The countdown face shared by the Timer and Focus modes: a big, thin digital time
/// centered inside a full ring of fine graduated tick marks — the Apple Watch dial
/// look — where the ring fills clockwise with the tint as the run elapses.
private struct TimerDial<Center: View>: View {
    /// Fraction elapsed, 0…1.
    let progress: Double
    let tint: Color
    var size: CGFloat = 150
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.03))
            GraduatedTicks(progress: progress, tint: tint)
                .padding(Spacing.s)
            center()
        }
        .frame(width: size, height: size)
    }
}

/// A dense ring of tick marks (an "hour" mark every fifth, longer/heavier), where
/// ticks swept past by `progress` glow in the tint — so the dial reads as a filling
/// radial ruler rather than a solid arc.
private struct GraduatedTicks: View {
    var progress: Double
    var tint: Color
    var count = 60

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let major = i % 5 == 0
                    let frac = Double(i) / Double(count)
                    let reached = frac <= max(0.0001, progress)
                    Capsule()
                        .fill(reached ? tint
                                      : Color.white.opacity(major ? 0.28 : 0.13))
                        .frame(width: major ? 2.2 : 1.4, height: major ? 12 : 7)
                        .offset(y: -(radius - (major ? 9 : 6)))
                        .rotationEffect(.degrees(frac * 360))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The three faces of the Clock tab.
enum ClockMode: String, CaseIterable, Identifiable {
    case clock, timer, pomodoro
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock:    return "Clock"
        case .timer:    return "Timer"
        case .pomodoro: return "Focus"
        }
    }
    var symbol: String {
        switch self {
        case .clock:    return "globe.americas.fill"
        case .timer:    return "timer"
        case .pomodoro: return "brain.head.profile"
        }
    }
}

/// The buckets the timer presets are filed under. `custom` holds the user's own
/// timers (added with the "+"); the rest group the built-in kitchen presets so the
/// grid isn't one long undifferentiated list.
enum TimerCategory: String, CaseIterable, Identifiable {
    case eggs, pasta, drinks, meat, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .eggs:   return "Eggs"
        case .pasta:  return "Pasta"
        case .drinks: return "Drinks"
        case .meat:   return "Meat"
        case .custom: return "Mine"
        }
    }

    var symbol: String {
        switch self {
        case .eggs:   return "oval.fill"
        case .pasta:  return "fork.knife"
        case .drinks: return "cup.and.saucer.fill"
        case .meat:   return "flame.fill"
        case .custom: return "star.fill"
        }
    }
}

/// A user-defined timer, persisted as JSON alongside the world-clock zones. Its
/// `id` keeps preset rows stable even if two share a name.
struct CustomTimer: Codable, Identifiable {
    var id = UUID()
    var name: String
    var seconds: TimeInterval
}

/// A one-tap kitchen timer. Box cook times for the pasta shapes; the rest are the
/// usual kitchen staples. `customID` is set only for user-added timers, which lets
/// the tile offer a "Remove" action and keeps the row id unique.
struct TimerPreset: Identifiable {
    let name: String
    let symbol: String
    let seconds: TimeInterval
    var category: TimerCategory = .meat
    var customID: UUID? = nil
    /// User timers key off their stable UUID; built-ins off their (unique) name.
    var id: String { customID?.uuidString ?? name }

    var durationLabel: String {
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return s == 0 ? "\(m) min" : String(format: "%d:%02d", m, s)
    }

    /// The whole-minute count for the dial label.
    var minutesText: String { "\(Int(seconds) / 60)" }

    /// Clock-hand angles that point the preset's dial at its cook time — the minute
    /// hand to the minutes, the hour hand creeping round as the minutes mount — so
    /// each preset's face reads differently at a glance.
    var minuteAngle: Double {
        let minutes = seconds / 60
        return minutes.truncatingRemainder(dividingBy: 60) / 60 * 360
    }
    var hourAngle: Double {
        let hours = seconds / 3600
        return hours.truncatingRemainder(dividingBy: 12) / 12 * 360
    }

    static let all: [TimerPreset] = [
        TimerPreset(name: "Soft Egg",   symbol: "oval.fill",            seconds: 6 * 60,  category: .eggs),
        TimerPreset(name: "Hard Egg",   symbol: "oval.fill",            seconds: 10 * 60, category: .eggs),
        TimerPreset(name: "Spaghetti",  symbol: "fork.knife",           seconds: 9 * 60,  category: .pasta),
        TimerPreset(name: "Penne",      symbol: "fork.knife",           seconds: 11 * 60, category: .pasta),
        TimerPreset(name: "Fusilli",    symbol: "fork.knife",           seconds: 11 * 60, category: .pasta),
        TimerPreset(name: "Farfalle",   symbol: "fork.knife",           seconds: 12 * 60, category: .pasta),
        TimerPreset(name: "Macaroni",   symbol: "fork.knife",           seconds: 8 * 60,  category: .pasta),
        TimerPreset(name: "Lasagne",    symbol: "fork.knife",           seconds: 15 * 60, category: .pasta),
        TimerPreset(name: "Rice",       symbol: "fork.knife",           seconds: 12 * 60, category: .pasta),
        TimerPreset(name: "Green Tea",  symbol: "cup.and.saucer.fill",  seconds: 3 * 60,  category: .drinks),
        TimerPreset(name: "Black Tea",  symbol: "cup.and.saucer.fill",  seconds: 4 * 60,  category: .drinks),
        TimerPreset(name: "French Press", symbol: "cup.and.saucer.fill", seconds: 4 * 60, category: .drinks),
        TimerPreset(name: "Steak Rest", symbol: "flame.fill",           seconds: 5 * 60,  category: .meat),
    ]
}

extension TimerPreset {
    /// Builds a preset from a stored custom timer so it renders in the grid.
    /// Declared in an extension so the memberwise initializer stays available.
    init(custom: CustomTimer) {
        self.init(name: custom.name, symbol: "timer", seconds: custom.seconds,
                  category: .custom, customID: custom.id)
    }
}

/// A single shared countdown so a running timer survives tab switches and panel
/// closes — the view's `@State` would be torn down when you leave the tab, but this
/// lives for the app's lifetime and drives its own completion off a scheduled
/// `Timer`, so the chime fires even when the Clock tab isn't on screen.
@MainActor
final class CountdownTimer: ObservableObject {
    static let shared = CountdownTimer()

    /// When the current run ends. `nil` when idle or paused.
    @Published private(set) var endDate: Date?
    @Published private(set) var label = ""
    /// Whole run length, kept so the ring can show elapsed fraction.
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var paused = false
    /// Frozen remaining time while paused.
    @Published private(set) var pausedRemaining: TimeInterval = 0
    /// True from the moment a run reaches zero until it's dismissed/reset.
    @Published private(set) var finished = false

    private var completion: Timer?

    private init() {}

    var isActive: Bool { endDate != nil || paused || finished }

    var remaining: TimeInterval {
        if finished { return 0 }
        if paused { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSinceNow)
    }

    /// Ring fill: fraction of time already elapsed (0 at start, 1 at completion).
    var progress: Double {
        if finished { return 1 }
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    func start(duration: TimeInterval, label: String) {
        self.label = label
        total = duration
        finished = false
        paused = false
        endDate = Date().addingTimeInterval(duration)
        scheduleCompletion(after: duration)
    }

    func pause() {
        guard let endDate, !paused, !finished else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        paused = true
        self.endDate = nil
        completion?.invalidate()
        completion = nil
    }

    func resume() {
        guard paused else { return }
        paused = false
        endDate = Date().addingTimeInterval(pausedRemaining)
        scheduleCompletion(after: pausedRemaining)
    }

    func stop() {
        completion?.invalidate()
        completion = nil
        endDate = nil
        paused = false
        finished = false
        pausedRemaining = 0
        total = 0
        label = ""
    }

    private func scheduleCompletion(after interval: TimeInterval) {
        completion?.invalidate()
        completion = Timer.scheduledTimer(withTimeInterval: max(0.05, interval),
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in self?.complete() }
        }
    }

    private func complete() {
        completion?.invalidate()
        completion = nil
        endDate = nil
        paused = false
        finished = true
        NSSound(named: "Glass")?.play()
    }
}

/// A shared Pomodoro engine that survives tab switches and panel closes the same
/// way ``CountdownTimer`` does, so a focus run keeps ticking — and auto-advances
/// through its focus/break phases — while you're elsewhere in the app. It cycles
/// `focusRounds` focus sessions, slipping in a short break after each and a long
/// break once the round of focus sessions is done, then starts the cycle over.
@MainActor
final class PomodoroTimer: ObservableObject {
    static let shared = PomodoroTimer()

    enum Phase: String {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus:      return "Focus"
            case .shortBreak: return "Short Break"
            case .longBreak:  return "Long Break"
            }
        }

        var symbol: String {
            switch self {
            case .focus:      return "brain.head.profile"
            case .shortBreak: return "cup.and.saucer.fill"
            case .longBreak:  return "figure.walk"
            }
        }

        var isBreak: Bool { self != .focus }
    }

    @Published private(set) var phase: Phase = .focus
    /// When the current run ends. `nil` when idle or paused.
    @Published private(set) var endDate: Date?
    @Published private(set) var paused = false
    /// Frozen remaining time while paused.
    @Published private(set) var pausedRemaining: TimeInterval = 0
    /// The length of the run in progress, captured at start so the ring stays
    /// stable even if the phase's configured length is edited mid-run.
    @Published private(set) var runTotal: TimeInterval = 0
    /// Focus sessions finished in the current cycle (0..<`focusRounds`) — drives the
    /// progress dots and the choice of a short vs. long break.
    @Published private(set) var completedFocus = 0
    /// Focus sessions finished since the last reset — the running "done" tally.
    @Published private(set) var totalFocus = 0

    // Durations (minutes) and cadence, persisted so a tuned setup survives relaunch.
    @Published var focusMinutes: Int { didSet { persist() } }
    @Published var shortBreakMinutes: Int { didSet { persist() } }
    @Published var longBreakMinutes: Int { didSet { persist() } }
    /// Focus sessions per cycle before the long break.
    @Published var focusRounds: Int { didSet { persist() } }
    /// Roll straight into the next phase when one finishes, hands-free.
    @Published var autoContinue: Bool { didSet { persist() } }

    private var completion: Timer?
    private let defaults = UserDefaults.standard

    private init() {
        focusMinutes      = defaults.object(forKey: "pomodoro.focus")  as? Int  ?? 25
        shortBreakMinutes = defaults.object(forKey: "pomodoro.short")  as? Int  ?? 5
        longBreakMinutes  = defaults.object(forKey: "pomodoro.long")   as? Int  ?? 15
        focusRounds       = defaults.object(forKey: "pomodoro.rounds") as? Int  ?? 4
        autoContinue      = defaults.object(forKey: "pomodoro.auto")   as? Bool ?? true
    }

    private func persist() {
        defaults.set(focusMinutes,      forKey: "pomodoro.focus")
        defaults.set(shortBreakMinutes, forKey: "pomodoro.short")
        defaults.set(longBreakMinutes,  forKey: "pomodoro.long")
        defaults.set(focusRounds,       forKey: "pomodoro.rounds")
        defaults.set(autoContinue,      forKey: "pomodoro.auto")
    }

    var isRunning: Bool { endDate != nil }
    var isActive: Bool { endDate != nil || paused }

    func duration(for phase: Phase) -> TimeInterval {
        switch phase {
        case .focus:      return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak:  return TimeInterval(longBreakMinutes * 60)
        }
    }

    /// Time left in the phase: the live countdown while running, the frozen value
    /// while paused, or the phase's full length while idle (so the dial previews it).
    var remaining: TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSinceNow) }
        if paused { return pausedRemaining }
        return duration(for: phase)
    }

    /// Ring fill: fraction of the current run already elapsed. Zero while idle.
    var progress: Double {
        guard isActive, runTotal > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / runTotal))
    }

    /// Start (or resume) the current phase.
    func start() {
        if paused { resume(); return }
        guard !isRunning else { return }
        runTotal = duration(for: phase)
        paused = false
        endDate = Date().addingTimeInterval(runTotal)
        scheduleCompletion(after: runTotal)
    }

    func toggle() { isRunning ? pause() : start() }

    func pause() {
        guard let endDate, !paused else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        paused = true
        self.endDate = nil
        completion?.invalidate()
        completion = nil
    }

    func resume() {
        guard paused else { return }
        paused = false
        endDate = Date().addingTimeInterval(pausedRemaining)
        scheduleCompletion(after: pausedRemaining)
    }

    /// Stop the run and sit idle at the start of the current phase.
    func stop() {
        completion?.invalidate()
        completion = nil
        endDate = nil
        paused = false
        pausedRemaining = 0
        runTotal = 0
    }

    /// Jump to the next phase without finishing this one (no chime); does not count
    /// a skipped focus session toward the cycle.
    func skip() {
        advance(countFocus: false, autoStart: false)
    }

    private func scheduleCompletion(after interval: TimeInterval) {
        completion?.invalidate()
        completion = Timer.scheduledTimer(withTimeInterval: max(0.05, interval),
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in self?.complete() }
        }
    }

    private func complete() {
        completion?.invalidate()
        completion = nil
        NSSound(named: phase.isBreak ? "Blow" : "Glass")?.play()
        advance(countFocus: true, autoStart: autoContinue)
    }

    /// Reset the run state and move focus → break → focus, choosing a long break
    /// once a full round of focus sessions is done and looping the cycle after it.
    private func advance(countFocus: Bool, autoStart: Bool) {
        completion?.invalidate()
        completion = nil
        endDate = nil
        paused = false
        pausedRemaining = 0
        runTotal = 0

        switch phase {
        case .focus:
            if countFocus {
                completedFocus += 1
                totalFocus += 1
            }
            phase = completedFocus >= max(1, focusRounds) ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            completedFocus = 0
            phase = .focus
        }

        if autoStart { start() }
    }
}
