import SwiftUI

/// Ambient sounds tab: pick a looping background soundscape (rain, storm, cabin,
/// park, shore) and set its volume. Playback is handled by ``AmbientPlayer`` and
/// keeps going whether the panel is open or collapsed. The scenes mirror the set
/// used in the Encore emulator.
struct AmbientTabView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: Spacing.lg) {
            GlassEffectContainer(spacing: Spacing.md) {
                HStack(spacing: Spacing.md) {
                    ForEach(AmbientScene.allCases) { scene in
                        SceneTile(scene: scene,
                                  isSelected: vm.ambientScene == scene,
                                  accent: settings.accent) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                // Tapping the active scene toggles it back off.
                                vm.ambientScene = (vm.ambientScene == scene && scene != .off) ? .off : scene
                            }
                        }
                    }
                }
            }

            VolumeRow(volume: $vm.ambientVolume, accent: settings.accent)
                .opacity(vm.ambientScene == .off ? 0.4 : 1)
                .disabled(vm.ambientScene == .off)
        }
    }
}

// MARK: - Scene tile

private struct SceneTile: View {
    let scene: AmbientScene
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.sm) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 20, weight: .semibold))
                Text(scene.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 86)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .modifier(SceneTileStyle(isSelected: isSelected, accent: accent, shape: shape))
        .notchHover(scale: 1.05)
    }
}

/// The selected scene is a filled accent-tinted glass tile; the rest are just an
/// outlined icon so the active soundscape reads at a glance.
private struct SceneTileStyle: ViewModifier {
    let isSelected: Bool
    let accent: Color
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if isSelected {
            content
                .blackGlass(in: shape, interactive: true, tint: accent.opacity(0.6))
                .overlay { shape.strokeBorder(accent, lineWidth: 1.5) }
        } else {
            content
                .overlay { shape.strokeBorder(Theme.line(0.18), lineWidth: 1) }
        }
    }
}

// MARK: - Volume

private struct VolumeRow: View {
    @Binding var volume: Double
    let accent: Color

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            VolumeSlider(value: $volume, accent: accent)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// A slim draggable volume bar, styled like the media scrubber.
private struct VolumeSlider: View {
    @Binding var value: Double
    let accent: Color
    /// Fattens the bar and reveals a grab knob while the pointer is over it.
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let progress = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line(0.14))
                Capsule().fill(accent)
                    .frame(width: geo.size.width * progress)
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: geo.size.width * progress - 5)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(height: hovering ? 6 : 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .pointerStyle(.grabIdle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        value = min(max(g.location.x / geo.size.width, 0), 1)
                    }
            )
        }
        .frame(height: 14)
    }
}
