import AppKit
import SwiftUI

/// Singleton wrapper around the SwiftUI gallery window so we can show/hide
/// it from the menubar without rebuilding state.
final class PetGalleryWindowController {
    static let shared = PetGalleryWindowController()

    private var window: NSWindow?
    weak var controller: PetAgentsController?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let view = PetGalleryView()
            .environment(\.petController, controller)

        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Mini Pet Agents — Gallery"
        win.setContentSize(NSSize(width: 720, height: 520))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI Environment plumbing

private struct PetControllerKey: EnvironmentKey {
    static let defaultValue: PetAgentsController? = nil
}
extension EnvironmentValues {
    var petController: PetAgentsController? {
        get { self[PetControllerKey.self] }
        set { self[PetControllerKey.self] = newValue }
    }
}

// MARK: - SwiftUI views

struct PetGalleryView: View {
    @Environment(\.petController) private var controller
    @State private var pets: [InstalledPet] = []
    @State private var installSlug: String = ""
    @State private var installLog: String = ""
    @State private var isInstalling = false

    var body: some View {
        VStack(spacing: 0) {
            installerBar
            Divider()
            if pets.isEmpty {
                emptyState
            } else {
                columnHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pets, id: \.slug) { pet in
                            PetRow(pet: pet) { reloadPets() }
                                .environment(\.petController, controller)
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear {
            reloadPets()
            NotificationCenter.default.addObserver(forName: PetLibrary.didChange,
                                                   object: nil, queue: .main) { _ in
                reloadPets()
            }
        }
    }

    private var installerBar: some View {
        // Three stacked rows so nothing overlaps. Top: install field +
        // buttons. Middle: usage tip (small, muted). Bottom: install log
        // (only shown while installing or after the most recent run).
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                TextField("Install pet by slug (e.g. noir-webling)", text: $installSlug)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(triggerInstall)
                    .disabled(isInstalling)
                Button(isInstalling ? "Installing…" : "Install") { triggerInstall() }
                    .disabled(installSlug.trimmingCharacters(in: .whitespaces).isEmpty || isInstalling)
                Button("Browse petdex.crafter.run") {
                    if let url = URL(string: "https://petdex.crafter.run/") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }
            Text("Drag a spawned pet anywhere on screen; click to open its chat. Pets resume walking after you drop them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !installLog.isEmpty {
                Text(installLog)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 48)            // preview column
            Text("PET").frame(maxWidth: .infinity, alignment: .leading)
            Text("PROVIDER").frame(width: 100, alignment: .leading)
            Text("SIZE").frame(width: 70, alignment: .leading)
            Text("SPAWN").frame(width: 40, alignment: .leading)
            Spacer().frame(width: 100)           // chat + delete buttons
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No pets installed yet")
                .font(.headline)
            Text("Install one above, or run `npx petdex install <slug>` in your terminal.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func reloadPets() { pets = PetLibrary.shared.pets }

    private func triggerInstall() {
        let slug = installSlug.trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty else { return }
        isInstalling = true
        installLog = "$ npx petdex install \(slug)"
        PetInstaller.shared.install(slug: slug, onOutput: { progress in
            installLog = progress.line.trimmingCharacters(in: .newlines)
        }, onComplete: { result in
            isInstalling = false
            switch result {
            case .success:
                installLog = "✓ installed \(slug)"
                installSlug = ""
                reloadPets()
            case .failure(let err):
                installLog = "✗ \(err.localizedDescription)"
            }
        })
    }
}

private struct PetRow: View {
    let pet: InstalledPet
    var onChange: () -> Void
    @Environment(\.petController) private var controller

    @State private var preview: NSImage?
    @State private var spawned: Bool = false
    @State private var providerOverride: AgentProvider? = nil
    @State private var sizeChoice: String = "default"

    var body: some View {
        // Single-row layout. Placement, walk speed, and movement mode now
        // live in the menubar / drag-to-zone UX; the gallery is just the
        // pet roster.
        HStack(spacing: 12) {
            previewView
                .frame(width: 48, height: 48)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(pet.slug).font(.headline)
                Text(pet.folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Picker("Provider", selection: providerBinding) {
                Text("Default").tag(AgentProvider?.none)
                ForEach(AgentProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(AgentProvider?.some(p))
                }
            }
            .labelsHidden()
            .frame(width: 100)

            Picker("Size", selection: $sizeChoice) {
                Text("Def").tag("default")
                ForEach(PetLibrary.displayHeightPresets, id: \.self) { h in
                    Text("\(Int(h))").tag("\(Int(h))")
                }
            }
            .labelsHidden()
            .frame(width: 70)
            .onChange(of: sizeChoice) { _, newVal in
                applySizeChoice(newVal)
            }

            // Spawn switch — column header makes the label redundant.
            Toggle("", isOn: $spawned)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(spawned ? "Spawned — toggle to remove from screen" : "Spawn this pet")
                .onChange(of: spawned) { newValue in
                    pet.isSpawned = newValue
                    if newValue { controller?.spawn(pet: pet) } else { controller?.despawn(slug: pet.slug) }
                    onChange()
                }

            Button("Open Chat") {
                controller?.openChat(slug: pet.slug)
            }
            .disabled(!spawned)

            Button {
                confirmDeletePet()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete \(pet.slug) and remove its files")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            spawned = pet.isSpawned
            providerOverride = pet.providerOverride
            if let s = PetLibrary.storedPerPetDisplayHeight(slug: pet.slug) {
                sizeChoice = "\(Int(s))"
            } else {
                sizeChoice = "default"
            }
            DispatchQueue.global(qos: .utility).async {
                let pack = pet.loadPack()
                DispatchQueue.main.async { preview = pack?.previewFrame }
            }
        }
    }

    private func confirmDeletePet() {
        let alert = NSAlert()
        alert.messageText = "Delete \(pet.slug)?"
        alert.informativeText = "This removes the pet's files from ~/.codex/pets/ and clears its preferences. You can reinstall it any time with `npx petdex install \(pet.slug)`."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.despawn(slug: pet.slug)
            PetLibrary.uninstall(slug: pet.slug)
            onChange()
        }
    }

    private func applySizeChoice(_ newVal: String) {
        if newVal == "default" {
            PetLibrary.clearPerPetDisplayHeight(slug: pet.slug)
        } else if let v = Double(newVal) {
            PetLibrary.setDisplayHeight(CGFloat(v), for: pet.slug)
        }
        controller?.refreshPet(slug: pet.slug)
    }

    private var providerBinding: Binding<AgentProvider?> {
        Binding(
            get: { providerOverride },
            set: { newValue in
                providerOverride = newValue
                pet.providerOverride = newValue
                controller?.refreshPet(slug: pet.slug)
            }
        )
    }

    @ViewBuilder
    private var previewView: some View {
        if let image = preview {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
