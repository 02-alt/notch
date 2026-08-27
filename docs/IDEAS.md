# Future Ideas

A running list of parked ideas and future directions for the app (internal target
`NotchGlass`, user-facing "All in a notch"). Nothing here is scheduled — it's a place to
capture the shape of an idea while it's fresh so we can pick it up later.

---

## Dynamic Island / Live Activities layer

An iOS-style **Dynamic Island** layer: an event-driven, contextual *collapsed pill* that
morphs on its own (not just on hover) to show glanceable live state.

**Why it fits:** ~70% of the scaffolding already exists — the morphing `NotchShape` + springs,
the collapsed media peek (art + EQ), the `CollapsedResting` glance (clock / fuel / battery),
and the live sources `NowPlayingManager`, `AirDropWatcher`, `BatteryMonitor`, and the Fuel
poller. Strong differentiator (à la NotchNook / boring.notch) and a headline paid feature for
the free-app / paid-tabs plan.

Three behaviours that make it read as the real Island (the shape alone isn't enough):

1. **Event-driven auto-expand** — track change / AirDrop start / timer hits 0 / Claude reply
   done → the pill briefly morphs out, then settles back.
2. **Leading + trailing slots** hugging the camera (art left / waveform right; ring left /
   countdown right) — the signature two-sided split.
3. **A small "Activity" abstraction + prioritised queue** so media, Pomodoro, AirDrop,
   charging, and a Chat "thinking" orb all present through ONE system, not per-view hacks.

**First step when picked up:** prototype ONE Activity end-to-end and nail the motion — a
Pomodoro/timer countdown ring, or AirDrop progress — kept behind the existing collapsed
system so nothing regresses, then generalise the queue. This is taste-in-motion (spring timing
+ trigger rules); iterate live like the glass work.

---

## Maker-authored tabs + "build your own tab" guide

Let makers (and us) add tabs easily, documented in a maker-facing guide.

**Contract first:** introduce a `Tab` protocol / registry so a new tab is **one file + one
registration line** instead of editing several files. Today tabs are wired across
`Views/*TabView.swift` plus wherever they're registered/enumerated in `Core` (e.g. the
view model). The guide documents that contract, the glass styling/theming hooks, and how
tab enablement / paywalling plugs in (ties into the free-app / paid-tabs plan).

---

## AI that builds tabs

A tab (or flow) that uses AI to create tabs. Two tracks off the same `Tab` contract:

- **Dev / build-time:** AI generates the Swift tab file + registration line → compile.
  Essentially the maker guide turned into a generator prompt. Good for us and third-party devs.
- **End-user / runtime:** Swift is compiled, so there's no clean way to inject AI-written
  Swift at runtime (`dlopen`/dylib exists, but code-signing / notarization / sandbox make it
  impractical for a shipping app). The clean path is a **declarative tab spec** — a JSON/DSL
  the AI emits (widgets like `webview`, `list`, `counter`, `apiFetch → display`, `timer`, plus
  styling) interpreted by a generic `SpecTabView`. The AI's job becomes "natural language →
  spec," which Claude is good at, and it reuses the Claude OAuth token already wired for
  the Scratch tab.

**Recommendation:** build the declarative spec first even for the dev path — "a tab is a spec"
is easier to document and it's what unlocks the runtime AI-tab feature. Swift codegen stays as
a bonus for power tabs that need real native code.
