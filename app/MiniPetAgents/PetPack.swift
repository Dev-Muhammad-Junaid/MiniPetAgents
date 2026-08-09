import AppKit
import ImageIO

/// Sprite-sheet states as shipped by every petdex pack (rows 0–8 in order).
/// We only use what the spritesheet actually provides — no synthetic
/// rotations, mirroring or extra transforms. Direction-of-travel is handled
/// by swapping between `.runRight` and `.runLeft` rows, not by flipping.
enum PetState: String, CaseIterable {
    case idle       // row 0 — 6 frames, default rest pose
    case runRight   // row 1 — 8 frames, walking right
    case runLeft    // row 2 — 8 frames, walking left
    case waving     // row 3 — 4 frames, "hi" wave
    case jumping    // row 4 — 5 frames, jump pose
    case failed     // row 5 — 8 frames, error / sad reaction
    case waiting    // row 6 — 6 frames, thinking / agent busy
    case running    // row 7 — 6 frames, faster sprint
    case review     // row 8 — 6 frames, examining / tool use

    /// Accept a few legacy / alternate spellings from older pet.json files
    /// or pre-refactor code paths. Anything unknown falls back to `.idle`
    /// at the call site.
    static func resolve(_ raw: String) -> PetState? {
        let key = raw.lowercased()
        if let direct = PetState(rawValue: key) { return direct }
        switch key {
        case "walk", "walking":             return .runRight
        case "run":                         return .running
        case "sleep", "sleeping":           return .idle
        case "think", "thinking":           return .waiting
        case "talking", "talk", "talker":   return .waving
        case "happy", "celebrate", "hop":   return .jumping
        case "sad", "error":                return .failed
        case "working", "tool", "tooluse":  return .review
        case "wave":                        return .waving
        case "jump":                        return .jumping
        case "run-right", "run_right":      return .runRight
        case "run-left", "run_left":        return .runLeft
        default: return nil
        }
    }
}

/// On-disk pet pack as installed by `npx petdex install <slug>` into
/// `~/.codex/pets/<slug>/`. Each pack is `pet.json` + `spritesheet.{webp,png}`.
struct PetPack {
    let slug: String
    let folderURL: URL
    let metadata: PetMetadata
    let frames: [PetState: [NSImage]]
    /// First frame from idle (or any state) — useful for gallery previews.
    let previewFrame: NSImage?

    /// Load a pack from a folder. Returns nil if `pet.json` or the
    /// spritesheet are missing or unreadable.
    static func load(from folderURL: URL) -> PetPack? {
        let fm = FileManager.default
        let slug = folderURL.lastPathComponent

        let metaURL = folderURL.appendingPathComponent("pet.json")
        guard fm.fileExists(atPath: metaURL.path),
              let data = try? Data(contentsOf: metaURL) else {
            NSLog("PetPack: missing pet.json in \(folderURL.path)")
            return nil
        }

        let metadata: PetMetadata
        do {
            metadata = try PetMetadata.decode(from: data, slug: slug)
        } catch {
            NSLog("PetPack: failed to decode pet.json for \(slug): \(error)")
            return nil
        }

        // Locate spritesheet — the spec recommends webp; we accept png too.
        let candidates = ["spritesheet.webp", "spritesheet.png", "sprite.webp", "sprite.png"]
        var sheetURL: URL?
        for name in candidates {
            let url = folderURL.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { sheetURL = url; break }
        }
        guard let sheetURL = sheetURL else {
            NSLog("PetPack: no spritesheet found in \(folderURL.path)")
            return nil
        }

        guard let sheet = PetPack.loadImage(at: sheetURL) else {
            NSLog("PetPack: failed to decode spritesheet at \(sheetURL.path)")
            return nil
        }

        let frames = PetPack.slice(sheet: sheet, metadata: metadata)
        let preview = frames[.idle]?.first ?? frames.values.compactMap { $0.first }.first

        return PetPack(slug: slug, folderURL: folderURL,
                       metadata: metadata, frames: frames, previewFrame: preview)
    }

    /// macOS Sonoma has built-in WebP via ImageIO, but WebP decode is
    /// noticeably slower than PNG. We cache the decoded sheet as
    /// `spritesheet.cached.png` next to the source and reuse it on
    /// subsequent launches when the source hasn't changed.
    private static func loadImage(at url: URL) -> CGImage? {
        let isWebP = url.pathExtension.lowercased() == "webp"
        let cacheURL = url.deletingPathExtension().appendingPathExtension("cached.png")
        let fm = FileManager.default

        // Try cache first.
        if isWebP, fm.fileExists(atPath: cacheURL.path) {
            let srcDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let cacheDate = (try? fm.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
            if let s = srcDate, let c = cacheDate, c >= s,
               let cached = decodeImageIO(at: cacheURL) {
                return cached
            }
        }

        guard let img = decodeImageIO(at: url) ?? decodeViaNSImage(at: url) else { return nil }

        // Persist a PNG cache for next launch (fire-and-forget; the user
        // already has the decoded image in hand for this run).
        if isWebP {
            DispatchQueue.global(qos: .utility).async { writePNG(img, to: cacheURL) }
        }
        return img
    }

    private static func decodeImageIO(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    private static func decodeViaNSImage(at url: URL) -> CGImage? {
        guard let ns = NSImage(contentsOf: url),
              let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
    }

    /// Crop the spritesheet into per-state frame arrays based on metadata.
    private static func slice(sheet: CGImage, metadata: PetMetadata) -> [PetState: [NSImage]] {
        var result: [PetState: [NSImage]] = [:]
        let cols = metadata.gridCols
        let rows = metadata.gridRows
        guard cols > 0, rows > 0 else { return result }

        let frameW = sheet.width / cols
        let frameH = sheet.height / rows
        guard frameW > 0, frameH > 0 else { return result }

        for (state, anim) in metadata.animations {
            var images: [NSImage] = []
            for frameIdx in anim.frames {
                let row = frameIdx / cols
                let col = frameIdx % cols
                guard row < rows && col < cols else { continue }
                let rect = CGRect(x: col * frameW, y: row * frameH, width: frameW, height: frameH)
                if let cropped = sheet.cropping(to: rect) {
                    let img = NSImage(cgImage: cropped, size: NSSize(width: frameW, height: frameH))
                    images.append(img)
                }
            }
            if !images.isEmpty { result[state] = images }
        }
        return result
    }
}

// MARK: - Metadata

/// Decoded `pet.json`. The petdex spec is somewhat loose — we accept a few
/// common shapes and normalize to a fixed structure here.
struct PetMetadata {
    let displayName: String
    let credit: String?
    let gridCols: Int          // recommended 8
    let gridRows: Int          // recommended 9
    let animations: [PetState: PetAnimation]

    static func decode(from data: Data, slug: String) throws -> PetMetadata {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = json as? [String: Any] else {
            throw NSError(domain: "PetPack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "pet.json root is not an object"])
        }

        let displayName = (root["name"] as? String)
            ?? (root["displayName"] as? String)
            ?? slug

        let credit = root["credit"] as? String ?? root["author"] as? String

        // Grid: try `grid: {cols, rows}`, then `cols`/`rows`, then default to 8x9.
        var cols = 8
        var rows = 9
        if let grid = root["grid"] as? [String: Any] {
            cols = (grid["cols"] as? Int) ?? cols
            rows = (grid["rows"] as? Int) ?? rows
        } else {
            cols = (root["cols"] as? Int) ?? (root["columns"] as? Int) ?? cols
            rows = (root["rows"] as? Int) ?? rows
        }

        // Animations: dictionary keyed by state name.
        let animsRaw = (root["animations"] as? [String: Any])
            ?? (root["states"] as? [String: Any])
            ?? [:]

        var animations: [PetState: PetAnimation] = [:]
        for (key, value) in animsRaw {
            guard let state = PetState.resolve(key) else { continue }
            if let anim = PetAnimation.decode(value: value, defaultRow: animations.count, cols: cols) {
                animations[state] = anim
            }
        }

        // If pet.json has no animations dict (the petdex CLI ships pets
        // without one — see https://github.com/crafter-station/petdex
        // `src/lib/pet-states.ts`), fall back to the canonical petdex spec.
        // CRITICAL: each row's animation length is NOT `cols` — only the
        // first N cells of each row are real frames, the rest are blank
        // padding. Looping through the blank trailing cells is what caused
        // the "sprite goes invisible at end of loop" bug.
        if animations.isEmpty {
            // (state, row, frameCount, durationMs) — verbatim from petdex spec.
            let canonical: [(PetState, Int, Int, Double)] = [
                (.idle,     0, 6, 1100),
                (.runRight, 1, 8, 1060),
                (.runLeft,  2, 8, 1060),
                (.waving,   3, 4, 700),
                (.jumping,  4, 5, 840),
                (.failed,   5, 8, 1220),
                (.waiting,  6, 6, 1010),
                (.running,  7, 6, 820),
                (.review,   8, 6, 1030),
            ]
            for (state, row, count, durationMs) in canonical where row < rows {
                let frames = (0..<min(count, cols)).map { row * cols + $0 }
                let fps = Double(count) * 1000.0 / durationMs
                animations[state] = PetAnimation(frames: frames, fps: fps)
            }
        }

        return PetMetadata(displayName: displayName, credit: credit,
                           gridCols: cols, gridRows: rows, animations: animations)
    }
}

struct PetAnimation {
    /// Absolute frame indices into the spritesheet (row-major).
    let frames: [Int]
    /// Frames per second.
    let fps: Double

    static func decode(value: Any, defaultRow: Int, cols: Int) -> PetAnimation? {
        // Shape A: { row: 0, frames: 8, fps: 8 }
        if let obj = value as? [String: Any] {
            let fps = (obj["fps"] as? Double) ?? 8
            if let frameList = obj["frameIndices"] as? [Int] {
                return PetAnimation(frames: frameList, fps: fps)
            }
            if let row = obj["row"] as? Int, let count = obj["frames"] as? Int {
                let frames = (0..<count).map { row * cols + $0 }
                return PetAnimation(frames: frames, fps: fps)
            }
            if let from = obj["from"] as? Int, let to = obj["to"] as? Int {
                return PetAnimation(frames: Array(from...to), fps: fps)
            }
        }
        // Shape B: [0, 1, 2, 3] — bare frame array.
        if let arr = value as? [Int] {
            return PetAnimation(frames: arr, fps: 8)
        }
        return nil
    }
}

// MARK: - Animator

/// Drives a CALayer's `contents` from a `PetPack`'s frame arrays.
final class SpriteAnimator {
    private let pack: PetPack
    private weak var layer: CALayer?
    /// 60Hz tick driving frame advancement. Timer is more predictable than
    /// CVDisplayLink across screens / GPU power states and we don't need
    /// vsync precision for sprite-sheet animation.
    private var timer: Timer?
    private var currentFrames: [NSImage] = []
    private var currentFps: Double = 8
    private var frameIndex: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    /// Current animation state (drives static-hold vs timed advance vs walk sync).
    private(set) var currentState: PetState = .idle
    /// The frame currently on screen. Used for alpha hit testing so a click
    /// can fall through the transparent parts of the sprite without having to
    /// screen-capture the window back off the compositor.
    var currentFrameImage: NSImage? {
        guard currentFrames.indices.contains(frameIndex) else { return nil }
        return currentFrames[frameIndex]
    }
    /// When false, we hold a single frame (no rapid cycling — avoids idle "blinks").
    private var advanceFramesWithTimer = true

    /// `.idle` ticks slowly; everything else uses the FPS declared in pet.json.
    /// Nothing is held statically anymore — we use the provided sprite frames.
    private static let slowLoopStates: Set<PetState> = [.idle]
    private static let slowLoopFps: Double = 3

    init(pack: PetPack, layer: CALayer) {
        self.pack = pack
        self.layer = layer
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func play(state: PetState) {
        currentState = state
        let frames = pack.frames[state] ?? pack.frames[.idle] ?? []
        guard !frames.isEmpty else { return }
        currentFrames = frames
        currentFps = pack.metadata.animations[state]?.fps
            ?? pack.metadata.animations[.idle]?.fps
            ?? 8
        frameIndex = 0
        lastFrameTime = CACurrentMediaTime()

        if Self.slowLoopStates.contains(state) {
            currentFps = min(currentFps, Self.slowLoopFps)
        }
        advanceFramesWithTimer = true
        applyCurrentFrame()
    }

    private func applyCurrentFrame() {
        guard let layer = layer, !currentFrames.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = currentFrames[frameIndex]
        CATransaction.commit()
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Common mode so timer keeps firing during menu tracking / scroll.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard advanceFramesWithTimer, !currentFrames.isEmpty, currentFps > 0 else { return }
        let now = CACurrentMediaTime()
        let interval = 1.0 / currentFps
        if now - lastFrameTime >= interval {
            frameIndex = (frameIndex + 1) % currentFrames.count
            lastFrameTime = now
            applyCurrentFrame()
        }
    }
}
