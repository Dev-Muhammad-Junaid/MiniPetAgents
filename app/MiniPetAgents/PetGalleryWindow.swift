import AppKit
import SwiftUI

// MARK: - Window controller

final class PetGalleryWindowController {
    static let shared = PetGalleryWindowController()
    private var window: NSWindow?
    weak var controller: PetAgentsController?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = PetGalleryView().environment(\.petController, controller)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Mini Pet Agents"
        win.setContentSize(NSSize(width: 760, height: 560))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Environment

private struct PetControllerKey: EnvironmentKey {
    static let defaultValue: PetAgentsController? = nil
}
extension EnvironmentValues {
    var petController: PetAgentsController? {
        get { self[PetControllerKey.self] }
        set { self[PetControllerKey.self] = newValue }
    }
}

// MARK: - Root gallery view

struct PetGalleryView: View {
    @Environment(\.petController) private var controller
    @State private var pets: [InstalledPet] = []
    @State private var installSlug = ""
    @State private var installLog  = ""
    @State private var isInstalling = false
    @State private var searchText  = ""
    @State private var isListView    = false
    @State private var listRefreshID = UUID()

    private var filteredPets: [InstalledPet] {
        searchText.isEmpty ? pets : pets.filter {
            $0.slug.localizedCaseInsensitiveContains(searchText)
        }
    }
    private var spawnedCount: Int { pets.filter(\.isSpawned).count }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.4)
            if filteredPets.isEmpty {
                emptyState
            } else if isListView {
                petList
            } else {
                petGrid
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            reloadPets()
            NotificationCenter.default.addObserver(
                forName: PetLibrary.didChange, object: nil, queue: .main) { _ in reloadPets() }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                // App identity
                Image(systemName: "pawprint.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mini Pet Agents").font(.headline)
                    Text("\(pets.count) installed · \(spawnedCount) active")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Install controls
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    TextField("Install by slug…", text: $installSlug)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(triggerInstall)
                        .disabled(isInstalling)
                    Button(isInstalling ? "Installing…" : "Install") { triggerInstall() }
                        .disabled(installSlug.trimmingCharacters(in: .whitespaces).isEmpty || isInstalling)
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://petdex.crafter.run/")!)
                    } label: {
                        Label("Browse", systemImage: "safari")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)

                    Divider().frame(height: 16)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isListView.toggle() }
                    } label: {
                        Image(systemName: isListView ? "square.grid.2x2" : "list.bullet")
                            .help(isListView ? "Switch to grid view" : "Switch to list view")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            if !installLog.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: installLog.hasPrefix("✓") ? "checkmark.circle.fill" : "terminal")
                        .foregroundStyle(installLog.hasPrefix("✓") ? .green : .secondary)
                        .font(.caption)
                    Text(installLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            // Search bar
            if !pets.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search pets…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Grid

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)
    ]

    private var petGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(filteredPets, id: \.slug) { pet in
                    PetCard(pet: pet, onChange: reloadPets)
                        .environment(\.petController, controller)
                }
            }
            .padding(16)
        }
    }

    // MARK: List

    private var petList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPets, id: \.slug) { pet in
                        PetListRow(pet: pet, onChange: reloadPets)
                            .environment(\.petController, controller)
                        Divider().padding(.leading, 60)
                    }
                }
                .padding(.vertical, 4)
            }
            .id(listRefreshID)
        }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            // thumbnail column
            Color.clear.frame(width: 38, height: 1)
            // name column
            Text("PET")
                .frame(minWidth: 80, alignment: .leading)
            Spacer()
            // CLI column
            Text("CLI")
                .frame(width: 84)
            // Position column — icons set all pets at once
            HStack(spacing: 0) {
                ForEach(PlacementMode.allCases, id: \.self) { mode in
                    Button { applyPlacementToAll(mode) } label: {
                        Image(systemName: mode.symbolName)
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Set all to \(mode.displayName)")
                }
            }
            // size column
            Text("SIZE").frame(width: 62)
            // actions column
            Color.clear.frame(width: 80, height: 1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func applyPlacementToAll(_ mode: PlacementMode) {
        for pet in filteredPets {
            PetLibrary.setPreferredPlacement(mode, for: pet.slug)
            controller?.refreshPet(slug: pet.slug)
        }
        listRefreshID = UUID()  // force PetListRow rebuild so @State re-reads from PetLibrary
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "pawprint.circle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.quaternary)
            Text("No pets installed yet")
                .font(.title3.weight(.medium))
            Text("Enter a slug above to install your first pet,\nor browse the gallery online.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                NSWorkspace.shared.open(URL(string: "https://petdex.crafter.run/")!)
            } label: {
                Label("Browse petdex.crafter.run", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(50)
    }

    // MARK: Actions

    private func reloadPets() { pets = PetLibrary.shared.pets }

    private func triggerInstall() {
        let slug = installSlug.trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty else { return }
        isInstalling = true
        installLog = "Installing \(slug)…"
        PetInstaller.shared.install(slug: slug, onOutput: { progress in
            installLog = progress.line.trimmingCharacters(in: .newlines)
        }, onComplete: { result in
            isInstalling = false
            switch result {
            case .success:
                installLog = "✓ Installed \(slug)"
                installSlug = ""
                reloadPets()
            case .failure(let err):
                installLog = "✗ \(err.localizedDescription)"
            }
        })
    }
}

// MARK: - Provider menu
// Uses NSViewRepresentable + NSPopUpButton to avoid SwiftUI type-checker
// timeouts that occur with Menu { } label: { } + chained modifiers.

private struct ProviderMenuButton: NSViewRepresentable {
    let selected: AgentProvider?
    let onSelect: (AgentProvider?) -> Void

    // Menu structure:  0=Default, 1=separator, 2…=allCases
    private static let offset = 2

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let btn = NSPopUpButton(frame: .zero, pullsDown: false)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 10, weight: .medium)
        buildMenu(btn)
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.changed(_:))
        return btn
    }

    func updateNSView(_ btn: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        if btn.numberOfItems == 0 { buildMenu(btn) }
        syncSelection(btn)
    }

    private func buildMenu(_ btn: NSPopUpButton) {
        btn.removeAllItems()
        btn.imagePosition = .imageLeft

        // "Default" item — generic globe icon
        let defaultItem = NSMenuItem(title: "Default", action: nil, keyEquivalent: "")
        defaultItem.image = sfIcon("circle.dotted", size: 13)
        btn.menu?.addItem(defaultItem)
        btn.menu?.addItem(.separator())

        for p in AgentProvider.allCases {
            let item = NSMenuItem(title: p.displayName, action: nil, keyEquivalent: "")
            item.image = providerIcon(p, size: 14)
            btn.menu?.addItem(item)
        }
    }

    private func syncSelection(_ btn: NSPopUpButton) {
        // imagePosition must survive rebuilds
        btn.imagePosition = .imageLeft
        if let p = selected {
            btn.selectItem(withTitle: p.displayName)
        } else {
            btn.selectItem(at: 0)
        }
        // Colour the button-face text with the brand colour
        let color = selected?.brandColor ?? .secondaryLabelColor
        let title = btn.selectedItem?.title ?? ""
        btn.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color,
                         .font: NSFont.systemFont(ofSize: 10, weight: .medium)])
    }

    /// Load the provider's asset-catalog logo, scaled to `size`×`size`.
    /// Falls back to the provider's SF Symbol if the image slot is empty.
    private func providerIcon(_ provider: AgentProvider, size: CGFloat) -> NSImage {
        let dim = NSSize(width: size, height: size)
        if let asset = NSImage(named: provider.logoImageName) {
            return asset.scaledCopy(to: dim)
        }
        return sfIcon(provider.symbolName, size: size - 2)
            ?? NSImage(size: dim)
    }

    private func sfIcon(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    final class Coordinator: NSObject {
        var onSelect: (AgentProvider?) -> Void = { _ in }
        @objc func changed(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            if idx == 0 { onSelect(nil) }
            else if idx >= ProviderMenuButton.offset {
                onSelect(AgentProvider.allCases[idx - ProviderMenuButton.offset])
            }
        }
    }
}


// MARK: - Placement icon picker
// Four SF symbol buttons — one per PlacementMode. Selected mode is tinted
// with the accent colour; each button shows a tooltip on hover.

private struct PlacementIconPicker: View {
    @Binding var placement: PlacementMode
    let slug: String
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            iconButton(for: .dock)
            iconButton(for: .freeRoam)
            iconButton(for: .leftStack)
            iconButton(for: .rightStack)
        }
    }

    private func iconButton(for mode: PlacementMode) -> some View {
        let isSelected = placement == mode
        return Button {
            placement = mode
            PetLibrary.setPreferredPlacement(mode, for: slug)
            onRefresh()
        } label: {
            Image(systemName: mode.symbolName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .help(mode.displayName)
    }
}

// MARK: - Pet list row

private struct PetListRow: View {
    let pet: InstalledPet
    var onChange: () -> Void
    @Environment(\.petController) private var controller

    @State private var preview: NSImage?
    @State private var spawned = false
    @State private var providerOverride: AgentProvider? = nil
    @State private var placementChoice: PlacementMode = .dock
    @State private var sizeChoice = "default"

    var body: some View {
        HStack(spacing: 10) {
            thumbnailView
            nameColumn
            Spacer()
            ProviderMenuButton(selected: providerOverride, onSelect: setProvider)
                .frame(width: 80)
            PlacementIconPicker(placement: $placementChoice, slug: pet.slug,
                                onRefresh: { controller?.refreshPet(slug: pet.slug) })
            sizePicker
            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .onAppear { setup() }
    }

    // MARK: Sub-views

    private var thumbnailView: some View {
        Group {
            if let img = preview {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.08)
            }
        }
        .frame(width: 38, height: 38)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if spawned {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white, lineWidth: 1))
                    .offset(x: 2, y: -2)
            }
        }
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(pet.slug)
                .font(.system(.subheadline, weight: .medium))
                .lineLimit(1)
            Text(pet.folderURL.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(minWidth: 80, alignment: .leading)
    }

    private var sizePicker: some View {
        Picker("", selection: $sizeChoice) {
            Text("Def").tag("default")
            ForEach(PetLibrary.displayHeightPresets, id: \.self) { h in
                Text("\(Int(h))").tag("\(Int(h))")
            }
        }
        .labelsHidden()
        .frame(width: 62)
        .onChange(of: sizeChoice) { _, v in
            if v == "default" { PetLibrary.clearPerPetDisplayHeight(slug: pet.slug) }
            else if let h = Double(v) { PetLibrary.setDisplayHeight(CGFloat(h), for: pet.slug) }
            controller?.refreshPet(slug: pet.slug)
        }
        .help("Display size")
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button { controller?.openChat(slug: pet.slug) } label: {
                Image(systemName: "bubble.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(spawned ? Color.blue : Color.secondary.opacity(0.4))
            .disabled(!spawned)
            .help("Open chat")

            Button { confirmDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.secondary)
            .help("Delete \(pet.slug)")

            Toggle("", isOn: $spawned)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.75)
                .help(spawned ? "Spawned — toggle off to remove" : "Spawn this pet")
                .onChange(of: spawned) { _, v in
                    pet.isSpawned = v
                    if v { controller?.spawn(pet: pet) } else { controller?.despawn(slug: pet.slug) }
                    onChange()
                }
        }
    }

    // MARK: Actions

    private func setup() {
        spawned = pet.isSpawned
        providerOverride = pet.providerOverride
        placementChoice = PetLibrary.preferredPlacement(for: pet.slug)
        sizeChoice = PetLibrary.storedPerPetDisplayHeight(slug: pet.slug).map { "\(Int($0))" } ?? "default"
        DispatchQueue.global(qos: .utility).async {
            let pack = pet.loadPack()
            DispatchQueue.main.async { preview = pack?.previewFrame }
        }
    }

    private func setProvider(_ provider: AgentProvider?) {
        providerOverride = provider
        pet.providerOverride = provider
        controller?.refreshPet(slug: pet.slug)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(pet.slug)?"
        alert.informativeText = "Removes files from disk and clears preferences."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.despawn(slug: pet.slug)
            PetLibrary.uninstall(slug: pet.slug)
            onChange()
        }
    }
}

// MARK: - Pet card

private struct PetCard: View {
    let pet: InstalledPet
    var onChange: () -> Void
    @Environment(\.petController) private var controller

    @State private var preview: NSImage?
    @State private var spawned = false
    @State private var providerOverride: AgentProvider? = nil
    @State private var sizeChoice = "default"
    @State private var placementChoice: PlacementMode = .dock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bannerSection
            Divider()
            infoSection
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .onAppear { setup() }
    }

    private var bannerSection: some View {
        ZStack(alignment: .topTrailing) {
            previewBanner
                .frame(height: 110)
                .clipped()
            if spawned {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .padding(8)
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            nameRow
            settingsRow
            controlsRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(pet.slug)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
            Spacer()
            ProviderMenuButton(selected: providerOverride, onSelect: setProvider)
        }
    }

    private var settingsRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            PlacementIconPicker(placement: $placementChoice, slug: pet.slug,
                                onRefresh: { controller?.refreshPet(slug: pet.slug) })
            Spacer()
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 6) {
            sizePicker
            Spacer()
            chatButton
            deleteButton
            spawnToggle
        }
    }

    private var sizePicker: some View {
        Picker("Size", selection: $sizeChoice) {
            Text("Default").tag("default")
            ForEach(PetLibrary.displayHeightPresets, id: \.self) { h in
                Text("\(Int(h)) px").tag("\(Int(h))")
            }
        }
        .labelsHidden()
        .frame(width: 90)
        .onChange(of: sizeChoice) { _, v in applySizeChoice(v) }
    }

    private var chatButton: some View {
        Button { controller?.openChat(slug: pet.slug) } label: {
            Image(systemName: "bubble.left")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(spawned ? Color.blue : Color.secondary.opacity(0.4))
        .disabled(!spawned)
        .help("Open chat")
    }

    private var deleteButton: some View {
        Button { confirmDelete() } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.secondary)
        .help("Delete \(pet.slug)")
    }

    private var spawnToggle: some View {
        Toggle("", isOn: $spawned)
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(0.8)
            .help(spawned ? "Spawned — tap to remove" : "Spawn this pet")
            .onChange(of: spawned) { _, v in
                pet.isSpawned = v
                if v { controller?.spawn(pet: pet) } else { controller?.despawn(slug: pet.slug) }
                onChange()
            }
    }

    // MARK: Sub-views

    @ViewBuilder
    private var previewBanner: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let img = preview {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 80)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private func setup() {
        spawned = pet.isSpawned
        providerOverride = pet.providerOverride
        placementChoice = PetLibrary.preferredPlacement(for: pet.slug)
        sizeChoice = PetLibrary.storedPerPetDisplayHeight(slug: pet.slug).map { "\(Int($0))" } ?? "default"
        DispatchQueue.global(qos: .utility).async {
            let pack = pet.loadPack()
            DispatchQueue.main.async { preview = pack?.previewFrame }
        }
    }

    private func setProvider(_ provider: AgentProvider?) {
        providerOverride = provider
        pet.providerOverride = provider
        controller?.refreshPet(slug: pet.slug)
    }

    private func applySizeChoice(_ v: String) {
        if v == "default" { PetLibrary.clearPerPetDisplayHeight(slug: pet.slug) }
        else if let h = Double(v) { PetLibrary.setDisplayHeight(CGFloat(h), for: pet.slug) }
        controller?.refreshPet(slug: pet.slug)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(pet.slug)?"
        alert.informativeText = "Removes files from disk and clears preferences. You can reinstall any time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.despawn(slug: pet.slug)
            PetLibrary.uninstall(slug: pet.slug)
            onChange()
        }
    }
}

// MARK: - Helpers

private extension NSImage {
    /// Return a copy of the image drawn into a new canvas of `size`.
    func scaledCopy(to size: NSSize) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        draw(in: NSRect(origin: .zero, size: size),
             from: .zero, operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}
