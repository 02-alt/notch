import SwiftUI
import UniformTypeIdentifiers

/// AirDrop button + a drop-file shelf you can also drag files back out of.
struct DropTabView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    /// True while files are being dragged directly onto the AirDrop card.
    @State private var airDropTargeted = false

    var body: some View {
        HStack(spacing: Spacing.base) {
            airDropCard
            dropShelf
        }
    }

    // MARK: - AirDrop

    private var airDropCard: some View {
        Button {
            shareViaAirDrop()
        } label: {
            VStack(spacing: Spacing.md) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 54, height: 54)
                    .blackGlass(in: Circle(), interactive: true)
                Text("AirDrop")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
            }
            .frame(width: 130)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        // Highlight the card while files are dragged onto it, matching the shelf.
        .overlay {
            if airDropTargeted {
                RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(settings.accent, lineWidth: 2)
            }
        }
        .notchHover(scale: 1.02)
        // Drag files straight onto the card to AirDrop them immediately, without
        // routing through the shelf first.
        .onDrop(of: [.fileURL], isTargeted: airDropTargetBinding) { providers in
            airDropDropped(providers)
            return true
        }
    }

    private var airDropTargetBinding: Binding<Bool> {
        Binding(
            get: { airDropTargeted },
            set: { targeted in
                airDropTargeted = targeted
                vm.noteDrag(active: targeted)
                if targeted { vm.keepOpen() }
            }
        )
    }

    /// Click: AirDrop whatever is on the shelf (or prompt for files if empty).
    private func shareViaAirDrop() {
        if vm.droppedItems.isEmpty {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            guard panel.runModal() == .OK else { return }
            performAirDrop(panel.urls)
        } else {
            performAirDrop(vm.droppedItems.map(\.url))
        }
    }

    /// Resolve dropped providers to file URLs, then open the AirDrop share sheet.
    private func airDropDropped(_ providers: [NSItemProvider]) {
        vm.keepOpen()
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { performAirDrop(urls) }
    }

    private func performAirDrop(_ urls: [URL]) {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }

    // MARK: - Drop shelf

    private var dropShelf: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    vm.isTargetedForDrop ? settings.accent : Theme.line(0.18),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )

            if vm.droppedItems.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Text("Drop files here")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .fill(vm.isTargetedForDrop ? settings.accent.opacity(0.08) : Color.clear)
        }
        .onDrop(of: [.fileURL], isTargeted: dropTargetBinding) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { vm.isTargetedForDrop },
            set: { targeted in
                vm.isTargetedForDrop = targeted
                vm.noteDrag(active: targeted)
                if targeted { vm.keepOpen() }
            }
        )
    }

    private var fileList: some View {
        VStack(spacing: Spacing.s) {
            HStack {
                Text("\(vm.droppedItems.count) file\(vm.droppedItems.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    vm.clearDropped()
                } label: {
                    Text("Clear")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(settings.accent)
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.08)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(vm.droppedItems) { item in
                        FileChip(item: item) { vm.removeDropped(item) }
                    }
                }
                .padding(.horizontal, Spacing.hair)
            }
        }
        .padding(Spacing.base)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        vm.keepOpen()
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in vm.addDropped(urls: [url]) }
            }
        }
    }
}

/// A single file tile: icon + name, draggable back out, with a remove button.
private struct FileChip: View {
    let item: DroppedItem
    let remove: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 40, height: 40)
            Text(item.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .padding(Spacing.sm)
        .innerCard(cornerRadius: 12)
        .notchHover(cursor: .grabIdle)
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.2, brighten: 0.15)
            .offset(x: 4, y: -4)
        }
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
    }
}
