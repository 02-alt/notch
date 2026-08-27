# NotchGlass

A macOS **notch** app built with SwiftUI and real **Liquid Glass** (`glassEffect`,
`GlassEffectContainer`). It lives as a black pill over the notch and expands into a
floating glass panel on hover. Requires **macOS 26 (Tahoe)** and Xcode 26.

## Tabs

1. **Media** 🏠 — now-playing from Apple Music / Spotify: artwork, title, artist,
   a lyrics line, a draggable scrubber with live position, and prev / play-pause / next.
2. **Drop** 📥 — an **AirDrop** button plus a drag-and-drop file shelf. Files you drop
   are parked as tiles you can drag back out to Finder or send via AirDrop.
3. **Websites** 🌐 — a quick-access shelf of favorite sites (favicons, opens in your
   browser, add/remove, persisted).
4. **Note** 📝 — an autosaving scratch note.

## Build & run

```bash
./build-app.sh          # builds NotchGlass.app (release, no Dock icon)
open NotchGlass.app
```

Or during development:

```bash
swift build && .build/debug/NotchGlass
```

Quit from the ⚙️ menu in the top-right of the panel (**Quit NotchGlass**).

## Notes

- The Media tab controls Music/Spotify via AppleScript, so macOS will ask for
  **Automation** permission the first time (System Settings ▸ Privacy & Security ▸
  Automation).
- Hover the pill to expand; move the pointer away to collapse.
- Window auto-positions on the display that has the notch (falls back to a pill on
  displays without one).

## Layout

```
Sources/NotchGlass/
  Core/    App, AppDelegate (window placement), NotchPanel, view model, models, metrics
  Media/   NowPlayingManager (AppleScript polling + interpolated playhead)
  Views/   RootView, PanelView, and the four tab views + glass helpers
```
