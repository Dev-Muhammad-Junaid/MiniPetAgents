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
            providerMenu
        }
    }

    private var settingsRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            placementPicker
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

    @ViewBuilder
    private var providerMenu: some View {
        let p = providerOverride
        let color: Color = p.map { Color(nsColor: $0.brandColor) } ?? .secondary
        Menu {
            Button("Default (global setting)") { setProvider(nil) }
            Divider()
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                Button {
                    setProvider(provider)
                } label: {
                    if p == provider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        } label: {
            Text(p?.displayName ?? "Default")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
                .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Select AI provider")
    }

    private var placementPicker: some View {
        Picker("Movement", selection: $placementChoice) {
            ForEach(PlacementMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .frame(width: 110)
        .onChange(of: placementChoice) { _, mode in
            PetLibrary.setPreferredPlacement(mode, for: pet.slug)
            controller?.refreshPet(slug: pet.slug)
        }
        .help("Pet movement / placement mode")
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
