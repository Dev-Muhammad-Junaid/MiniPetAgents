import Foundation
import AppKit

/// One installed pet on disk. Lazily loads its `PetPack` on demand so the
/// gallery can list hundreds without parsing every spritesheet up front.
final class InstalledPet {
    let slug: String
    let folderURL: URL
    private var cachedPack: PetPack?

    /// User-set per-pet preferences, persisted in UserDefaults.
    var placement: PlacementMode {
        get { PetLibrary.preferredPlacement(for: slug) }
        set { PetLibrary.setPreferredPlacement(newValue, for: slug) }
    }
    var providerOverride: AgentProvider? {
        get { PetLibrary.preferredProvider(for: slug) }
        set { PetLibrary.setPreferredProvider(newValue, for: slug) }
    }
    /// Directory this pet's CLI runs in. nil = the user's home directory.
    var workingDirectory: URL? {
        get { PetLibrary.preferredWorkingDirectory(for: slug) }
        set { PetLibrary.setPreferredWorkingDirectory(newValue, for: slug) }
    }
    /// Model passed to the CLI via --model. nil = the provider's default.
    var model: String? {
        get { PetLibrary.preferredModel(for: slug) }
        set { PetLibrary.setPreferredModel(newValue, for: slug) }
    }
    /// Spawn state — does the user currently want this pet on screen?
    var isSpawned: Bool {
        get { PetLibrary.isSpawned(slug: slug) }
        set { PetLibrary.setSpawned(newValue, slug: slug) }
    }

    // MARK: - Resolved animation/movement (per-pet override falls back to app default)

    var resolvedMovementMode: MovementMode { PetLibrary.resolvedMovementMode(for: slug) }
    var resolvedWalkSpeed: WalkSpeed       { PetLibrary.resolvedWalkSpeed(for: slug) }

    init(slug: String, folderURL: URL) {
        self.slug = slug
        self.folderURL = folderURL
    }

    func loadPack() -> PetPack? {
        if let cached = cachedPack { return cached }
        let pack = PetPack.load(from: folderURL)
        cachedPack = pack
        return pack
    }

    /// Drop the in-memory frame arrays. Called when a pet is despawned so
    /// inactive pets don't keep their decoded sprite sheets resident.
    /// Next `loadPack()` will reload from disk (now PNG-cached and fast).
    func releasePack() { cachedPack = nil }
}

/// Discovers installed pets in `~/.codex/pets/` and watches the directory
/// for newly-installed packs (via `npx petdex install ...`) so the UI
/// updates without a relaunch.
final class PetLibrary {
    static let shared = PetLibrary()

    /// Notification posted whenever the installed pet list changes.
    static let didChange = Notification.Name("PetLibrary.didChange")
    /// Posted when display size or pinned position prefs change (spawned pets should relayout).
    static let layoutPreferencesDidChange = Notification.Name("PetLibrary.layoutPreferencesDidChange")

    /// Default on-screen pet height (width matches for square box).
    static let defaultDisplayHeight: CGFloat = 80
    static let displayHeightPresets: [CGFloat] = [40, 56, 72, 96, 128, 160]

    private(set) var pets: [InstalledPet] = []

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    private init() {
        rescan()
        startWatching()
    }

    deinit { stopWatching() }

    /// `~/.codex/pets/`
    static var rootURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/pets", isDirectory: true)
    }

    /// Delete the pet's folder and clean up its UserDefaults. The caller is
    /// responsible for first telling the controller to despawn the pet.
    /// Returns `true` if the folder was removed.
    @discardableResult
    static func uninstall(slug: String) -> Bool {
        let url = rootURL.appendingPathComponent(slug, isDirectory: true)
        let removed = (try? FileManager.default.removeItem(at: url)) != nil
        // Drop any per-pet preferences too; rescan() also prunes orphans
        // but that runs after the folder is gone.
        for suffix in perPetKeySuffixes {
            UserDefaults.standard.removeObject(forKey: "pet.\(slug).\(suffix)")
        }
        shared.rescan()
        return removed
    }

    func pet(slug: String) -> InstalledPet? {
        pets.first(where: { $0.slug == slug })
    }

    func rescan() {
        let root = Self.rootURL
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else {
            pets = []
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return
        }
        var found: [InstalledPet] = []
        for url in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let petJSON = url.appendingPathComponent("pet.json")
            guard fm.fileExists(atPath: petJSON.path) else { continue }
            // Reuse existing InstalledPet objects so cached PetPack stays warm.
            if let existing = pets.first(where: { $0.slug == url.lastPathComponent }) {
                found.append(existing)
            } else {
                found.append(InstalledPet(slug: url.lastPathComponent, folderURL: url))
            }
        }
        found.sort { $0.slug.localizedCaseInsensitiveCompare($1.slug) == .orderedAscending }
        pets = found
        pruneOrphanedPreferences(validSlugs: Set(found.map { $0.slug }))
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - File system watcher

    private func startWatching() {
        let url = Self.rootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.rescan() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedFD, fd >= 0 { close(fd); self?.watchedFD = -1 }
        }
        source.resume()
        watchSource = source
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    // MARK: - Per-pet preferences (UserDefaults-backed)

    private static func placementKey(_ slug: String) -> String { "pet.\(slug).placement" }
    private static func providerKey(_ slug: String) -> String  { "pet.\(slug).provider" }
    private static func spawnedKey(_ slug: String) -> String   { "pet.\(slug).spawned" }

    static func preferredPlacement(for slug: String) -> PlacementMode {
        let raw = UserDefaults.standard.string(forKey: placementKey(slug)) ?? PlacementMode.dock.rawValue
        return PlacementMode(rawValue: raw) ?? .dock
    }
    static func setPreferredPlacement(_ mode: PlacementMode, for slug: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: placementKey(slug))
    }

    static func preferredProvider(for slug: String) -> AgentProvider? {
        guard let raw = UserDefaults.standard.string(forKey: providerKey(slug)) else { return nil }
        return AgentProvider(rawValue: raw)
    }
    static func setPreferredProvider(_ provider: AgentProvider?, for slug: String) {
        if let provider = provider {
            UserDefaults.standard.set(provider.rawValue, forKey: providerKey(slug))
        } else {
            UserDefaults.standard.removeObject(forKey: providerKey(slug))
        }
    }

    private static func workingDirKey(_ slug: String) -> String { "pet.\(slug).workingDir" }

    /// Per-pet working directory the CLI runs in. nil = home directory.
    static func preferredWorkingDirectory(for slug: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: workingDirKey(slug)),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static func setPreferredWorkingDirectory(_ url: URL?, for slug: String) {
        if let url = url {
            UserDefaults.standard.set(url.path, forKey: workingDirKey(slug))
        } else {
            UserDefaults.standard.removeObject(forKey: workingDirKey(slug))
        }
    }

    private static func modelKey(_ slug: String) -> String { "pet.\(slug).model" }

    /// Per-pet model name passed via --model. nil = provider default.
    static func preferredModel(for slug: String) -> String? {
        let v = UserDefaults.standard.string(forKey: modelKey(slug))
        return (v?.isEmpty == false) ? v : nil
    }
    static func setPreferredModel(_ model: String?, for slug: String) {
        if let model = model, !model.isEmpty {
            UserDefaults.standard.set(model, forKey: modelKey(slug))
        } else {
            UserDefaults.standard.removeObject(forKey: modelKey(slug))
        }
    }

    static func isSpawned(slug: String) -> Bool {
        UserDefaults.standard.object(forKey: spawnedKey(slug)) as? Bool ?? false
    }
    static func setSpawned(_ value: Bool, slug: String) {
        UserDefaults.standard.set(value, forKey: spawnedKey(slug))
    }

    // MARK: - Display size (global default + per-pet override)

    private static let defaultDisplayHeightKey = "app.defaultPetDisplayHeight"
    private static func displayHeightKey(_ slug: String) -> String { "pet.\(slug).displayHeight" }

    /// Resolved height for a spawned pet: per-pet value if set, else global default, else 160.
    static func displayHeight(for slug: String) -> CGFloat {
        let per = UserDefaults.standard.double(forKey: displayHeightKey(slug))
        if per >= 32 {
            return CGFloat(per)
        }
        let global = UserDefaults.standard.double(forKey: defaultDisplayHeightKey)
        if global >= 32 {
            return CGFloat(global)
        }
        return defaultDisplayHeight
    }

    /// `slug == nil` sets the global default for newly spawned pets without a per-pet height.
    static func setDisplayHeight(_ height: CGFloat, for slug: String?) {
        let clamped = min(320, max(32, height))
        if let slug = slug {
            UserDefaults.standard.set(Double(clamped), forKey: displayHeightKey(slug))
        } else {
            UserDefaults.standard.set(Double(clamped), forKey: defaultDisplayHeightKey)
        }
        NotificationCenter.default.post(name: layoutPreferencesDidChange, object: nil)
    }

    static func clearPerPetDisplayHeight(slug: String) {
        UserDefaults.standard.removeObject(forKey: displayHeightKey(slug))
        NotificationCenter.default.post(name: layoutPreferencesDidChange, object: nil)
    }

    /// Whether the user set an explicit height for this pet (not inherited from the app default).
    static func hasPerPetDisplayHeightOverride(slug: String) -> Bool {
        UserDefaults.standard.object(forKey: displayHeightKey(slug)) != nil
    }

    /// Raw per-pet height if set; does not fall back to the global default.
    static func storedPerPetDisplayHeight(slug: String) -> CGFloat? {
        guard UserDefaults.standard.object(forKey: displayHeightKey(slug)) != nil else { return nil }
        let v = UserDefaults.standard.double(forKey: displayHeightKey(slug))
        return v >= 32 ? CGFloat(v) : nil
    }

    /// Global default height (what new pets inherit when they have no per-pet value).
    static func resolvedGlobalDefaultDisplayHeight() -> CGFloat {
        let global = UserDefaults.standard.double(forKey: defaultDisplayHeightKey)
        if global >= 32 { return CGFloat(global) }
        return defaultDisplayHeight
    }

    // MARK: - Legacy: clear stale pinned-position keys on launch
    //
    // Earlier builds saved a fixed origin per pet on Shift-drag and used it to
    // override placement. The new free-drag UX doesn't pin pets, so any saved
    // origins from the old build would freeze a pet in place. Wipe them once.
    static func clearLegacyPinnedOrigins() {
        let defaults = UserDefaults.standard
        let migrationKey = "app.didClearLegacyPinnedOrigins.v1"
        if defaults.bool(forKey: migrationKey) { return }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("pet.") && key.hasSuffix(".pinnedScreenOrigin") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: migrationKey)
    }

    // MARK: - Popover (chat) window size — per pet, persisted

    static let defaultPopoverSize = NSSize(width: 420, height: 310)
    static let minPopoverSize = NSSize(width: 320, height: 220)
    static let maxPopoverSize = NSSize(width: 900, height: 800)

    private static func popoverSizeKey(_ slug: String) -> String { "pet.\(slug).popoverSize" }

    static func popoverSize(for slug: String) -> NSSize {
        guard let s = UserDefaults.standard.string(forKey: popoverSizeKey(slug)),
              !s.isEmpty else { return defaultPopoverSize }
        let size = NSSizeFromString(s)
        guard size.width >= minPopoverSize.width, size.height >= minPopoverSize.height else {
            return defaultPopoverSize
        }
        return NSSize(width: min(size.width, maxPopoverSize.width),
                      height: min(size.height, maxPopoverSize.height))
    }

    static func setPopoverSize(_ size: NSSize, for slug: String) {
        let clamped = NSSize(
            width: min(maxPopoverSize.width, max(minPopoverSize.width, size.width)),
            height: min(maxPopoverSize.height, max(minPopoverSize.height, size.height))
        )
        UserDefaults.standard.set(NSStringFromSize(clamped), forKey: popoverSizeKey(slug))
    }

    // MARK: - Animation & movement preferences

    private static func movementModeKey(_ slug: String) -> String { "pet.\(slug).movementMode" }
    private static func walkSpeedKey(_ slug: String) -> String    { "pet.\(slug).walkSpeed" }

    private static let appMovementModeKey = "app.movementMode"
    private static let appWalkSpeedKey    = "app.walkSpeed"

    static func resolvedMovementMode(for slug: String) -> MovementMode {
        if let raw = UserDefaults.standard.string(forKey: movementModeKey(slug)),
           let v = MovementMode(rawValue: raw) { return v }
        if let raw = UserDefaults.standard.string(forKey: appMovementModeKey),
           let v = MovementMode(rawValue: raw) { return v }
        return .spriteDriven
    }
    static func resolvedWalkSpeed(for slug: String) -> WalkSpeed {
        if let raw = UserDefaults.standard.string(forKey: walkSpeedKey(slug)),
           let v = WalkSpeed(rawValue: raw) { return v }
        if let raw = UserDefaults.standard.string(forKey: appWalkSpeedKey),
           let v = WalkSpeed(rawValue: raw) { return v }
        return .normal
    }

    static func storedMovementMode(slug: String) -> MovementMode? {
        UserDefaults.standard.string(forKey: movementModeKey(slug)).flatMap(MovementMode.init(rawValue:))
    }
    static func storedWalkSpeed(slug: String) -> WalkSpeed? {
        UserDefaults.standard.string(forKey: walkSpeedKey(slug)).flatMap(WalkSpeed.init(rawValue:))
    }

    static func setMovementMode(_ value: MovementMode?, for slug: String?) {
        let key = slug.map { movementModeKey($0) } ?? appMovementModeKey
        if let v = value { UserDefaults.standard.set(v.rawValue, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        NotificationCenter.default.post(name: layoutPreferencesDidChange, object: nil)
    }
    static func setWalkSpeed(_ value: WalkSpeed?, for slug: String?) {
        let key = slug.map { walkSpeedKey($0) } ?? appWalkSpeedKey
        if let v = value { UserDefaults.standard.set(v.rawValue, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        NotificationCenter.default.post(name: layoutPreferencesDidChange, object: nil)
    }

    // MARK: - Orphan-prune for uninstalled pets

    /// All per-pet UserDefaults key suffixes we own. Used to clean up when a slug disappears.
    private static let perPetKeySuffixes: [String] = [
        "placement", "provider", "spawned",
        "displayHeight", "pinnedScreenOrigin",
        "movementMode", "walkSpeed",
        "popoverSize", "workingDir", "model",
        // Legacy keys still pruned so old installs clean up:
        "idleWander", "pauseWhileTalking", "roamRegion", "edge"
    ]

    private func pruneOrphanedPreferences(validSlugs: Set<String>) {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("pet.") {
            // Format: pet.<slug>.<suffix>
            let parts = key.dropFirst(4).split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let slug = String(parts[0])
            let suffix = String(parts[1])
            guard Self.perPetKeySuffixes.contains(suffix) else { continue }
            if !validSlugs.contains(slug) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

// MARK: - Animation & movement value types

enum MovementMode: String, CaseIterable {
    case spriteDriven, stationary
    var displayName: String {
        switch self {
        case .spriteDriven: return "Sprite-driven"
        case .stationary:   return "Stationary"
        }
    }
}

enum WalkSpeed: String, CaseIterable {
    case slow, normal, fast
    var displayName: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }
    /// Multiplier applied to base motion speed. >1 → finishes a walk faster.
    var multiplier: Double {
        switch self {
        case .slow: return 0.5
        case .normal: return 1.0
        case .fast: return 2.0
        }
    }
}

