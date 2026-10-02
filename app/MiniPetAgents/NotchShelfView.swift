import AppKit

/// Draws the notch shelf: a black slab that bleeds off the top of the screen,
/// with the pets laid out along it.
///
/// Resting, it shows the active pet on the left and the rest as a condensed
/// cluster on the right. Expanded, the pets become a horizontal character
/// select — the active one large and lit, its neighbours smaller and dimmer —
/// so switching pets reads as a choice rather than a menu.
final class NotchShelfView: NSView {

    /// Which body the shelf is showing. Modes swap the body and never the
    /// roster — the pet you have selected is the context for all of them.
    /// Chat is deliberately absent until it actually works; a rail segment
    /// that opens an empty panel is worse than one that isn't there yet.
    enum Mode: CaseIterable {
        case pets, chat, activity
        var title: String {
            switch self {
            case .pets:     return "Pets"
            case .chat:     return "Chat"
            case .activity: return "Activity"
            }
        }
    }

    /// One line of a conversation, flattened for drawing.
    struct ChatLine {
        let isUser: Bool
        let text: String
    }

    struct Entry {
        let slug: String
        /// The pet's full animation for whatever it is doing, not one frozen
        /// frame. A still sprite in the notch is the single biggest reason the
        /// shelf read as dead.
        let frames: [NSImage]
        let fps: Double
        let tint: NSColor
        let isBusy: Bool

        var image: NSImage? { frames.first }

        /// The frame for a given moment, cycling at the pack's own rate.
        func frame(at time: CFTimeInterval) -> NSImage? {
            guard !frames.isEmpty else { return nil }
            guard frames.count > 1, fps > 0 else { return frames[0] }
            return frames[Int(time * fps) % frames.count]
        }
    }

    /// One row of the feed, flattened for drawing. Built by the command centre
    /// so this view never reaches into the store.
    struct ActivityRow {
        let name: String
        let provider: String
        let activity: String
        let state: ActivityStore.Record.State
        let trailing: String       // duration and usage, already formatted
        let remedy: String?        // inline fix, e.g. "Sign in"
        let tint: NSColor
        let image: NSImage?
        /// Live rows animate; settled ones hold one frame, so motion in the
        /// feed always means "still happening".
        var frames: [NSImage] = []
        var fps: Double = 8
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onModeChanged: ((Mode) -> Void)?
    /// A click anywhere that isn't a control — this is what opens the panel.
    var onActivate: (() -> Void)?
    /// Clicking the pet already at the front opens it — the next step in the
    /// flow, rather than re-selecting what is already selected.
    var onOpenPet: ((String) -> Void)?
    private var stage: NotchCommandCentre.Stage = .collapsed
    /// Size the shelf is drawn at right now, eased toward `targetShelf`.
    /// Animating the drawing instead of the window is what removed the hover
    /// flicker: the window never moves, so nothing can cross the pointer.
    private var currentShelf: NSSize = .zero
    private var targetShelf: NSSize = .zero
    private var sizeAnimation: Timer?

    /// The drawn shelf, in view coordinates: centred horizontally, anchored to
    /// the top edge so it always meets the screen edge.
    var shelfRect: NSRect { rect(for: currentShelf) }

    /// Where the shelf is *going*. Everything interactive measures against
    /// this, never against `shelfRect` — a control that is hit-tested while
    /// its rectangle is still animating is a control you cannot reliably
    /// click, which is exactly how the Activity tab came to swallow clicks
    /// and drop the panel.
    var settledRect: NSRect { rect(for: targetShelf) }

    private func rect(for size: NSSize) -> NSRect {
        NSRect(x: (bounds.width - size.width) / 2,
               y: bounds.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// Rail pill frames, derived rather than recorded during drawing, so
    /// hit-testing cannot lag a frame behind what is on screen.
    private func railFrames() -> [(Mode, NSRect)] {
        var out: [(Mode, NSRect)] = []
        var x = settledRect.minX + 18
        let y = settledRect.maxY - 34
        for m in Mode.allCases {
            let w = m.title.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 28
            out.append((m, NSRect(x: x, y: y, width: w, height: 24)))
            x += w + 4
        }
        return out
    }
    private(set) var mode: Mode = .pets
    private(set) var rows: [ActivityRow] = []
    private(set) var summary: String = ""
    /// Status word and the concrete step under it — the "Spelunking… /
    /// Running the test suite" pairing from the design.
    private(set) var activeWord: String = ""
    private(set) var activeCaption: String = ""
    private(set) var chat: [ChatLine] = []
    /// 0→1 after the panel opens. Drives the staggered arrival so the roster
    /// assembles rather than snapping into place.
    private var appear: CGFloat = 0
    private var appearTimer: Timer?
    /// Drives sprite playback and every breathing/pulsing value. One timer for
    /// the whole shelf — the pets are already decoded, so this is just a
    /// redraw at the pack's own frame rate.
    private var heartbeat: Timer?
    /// 0→1 across a mode change. Below 0.5 the outgoing body is still drawn,
    /// fading; above it the incoming one fades in. A cut between two dark
    /// panels reads as a glitch, so they cross rather than swap.
    private var modeFade: CGFloat = 1
    private var modeFadeTimer: Timer?
    private var outgoingMode: Mode?
    /// Alpha for whichever body is being drawn right now.
    private var bodyAlpha: CGFloat {
        modeFade >= 1 ? 1 : (modeFade < 0.5 ? 1 - modeFade * 2 : (modeFade - 0.5) * 2)
    }
    private var clock: CFTimeInterval { CACurrentMediaTime() }
    private(set) var entries: [Entry] = []
    private(set) var activeIndex = 0
    private var expanded = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }

    /// Start once the view is in a window; stop when it leaves, so a hidden
    /// shelf costs nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        heartbeat?.invalidate()
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent)  { onHoverChanged?(false) }

    func update(entries: [Entry]) {
        self.entries = entries
        if activeIndex >= entries.count { activeIndex = max(0, entries.count - 1) }
        needsDisplay = true
    }

    func update(rows: [ActivityRow], summary: String) {
        self.rows = rows
        self.summary = summary
        needsDisplay = true
    }

    func update(chat lines: [ChatLine]) {
        chat = lines
        needsDisplay = true
    }

    func update(word: String, caption: String) {
        activeWord = word
        activeCaption = caption
        needsDisplay = true
    }

    /// Replays whenever the panel opens or the mode changes, so content
    /// arrives in sequence instead of all at once.
    private func restartAppear() {
        appearTimer?.invalidate()
        appear = 0
        let start = CACurrentMediaTime()
        appearTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { return t.invalidate() }
            let p = min(1, CGFloat((CACurrentMediaTime() - start) / 0.42))
            // Ease out: fast to begin, settling softly, which is what makes a
            // spring read as physical rather than linear.
            self.appear = 1 - pow(1 - p, 3)
            if p >= 1 { t.invalidate() }
            self.needsDisplay = true
        }
        if let appearTimer { RunLoop.main.add(appearTimer, forMode: .common) }
    }

    /// 0→1 for the n-th item, offset so each lands 40ms after the one before.
    private func stagger(_ index: Int) -> CGFloat {
        let offset = CGFloat(index) * 0.13
        return max(0, min(1, (appear - offset) / max(0.0001, 1 - offset)))
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        outgoingMode = mode
        mode = newMode
        startModeFade()
        onModeChanged?(newMode)
    }

    private func startModeFade() {
        modeFadeTimer?.invalidate()
        modeFade = 0
        let start = CACurrentMediaTime()
        modeFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { return t.invalidate() }
            let p = min(1, CGFloat((CACurrentMediaTime() - start) / 0.26))
            self.modeFade = p
            // The incoming body replays its stagger as it arrives, so the new
            // mode deals itself out rather than simply appearing at full.
            if p >= 0.5, self.outgoingMode != nil {
                self.outgoingMode = nil
                self.restartAppear()
            }
            if p >= 1 { t.invalidate() }
            self.needsDisplay = true
        }
        if let modeFadeTimer { RunLoop.main.add(modeFadeTimer, forMode: .common) }
    }

    override func mouseDown(with event: NSEvent) {
        guard stage == .expanded else {
            onActivate?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // Generous vertical slop: the pills are 24pt tall and people aim at
        // the word, not the capsule.
        if let hit = railFrames().first(where: { $0.1.insetBy(dx: -2, dy: -8).contains(point) }) {
            setMode(hit.0)
            return
        }
        // Clicking a pet in the character select makes it active.
        guard mode == .pets, !entries.isEmpty else { return }
        if let hit = slots().first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }) {
            if hit.index == activeIndex { onOpenPet?(entries[hit.index].slug) }
            else { select(hit.index) }
        }
    }

    func setStage(_ value: NotchCommandCentre.Stage, shelf: NSSize) {
        stage = value
        expanded = value == .expanded
        targetShelf = shelf
        if currentShelf == .zero { currentShelf = shelf }
        startSizeAnimation()
        if value == .expanded { restartAppear() } else { appear = 1 }
        needsDisplay = true
    }

    /// Ease the drawn size toward the target. Growing overshoots a little so
    /// the shelf reads as one piece of material stretching; shrinking does
    /// not, because a shelf that bounces shut looks like a bug.
    private func startSizeAnimation() {
        sizeAnimation?.invalidate()
        let growing = targetShelf.width > currentShelf.width
        let rate: CGFloat = growing ? 0.26 : 0.34
        sizeAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { return timer.invalidate() }
            let dw = self.targetShelf.width - self.currentShelf.width
            let dh = self.targetShelf.height - self.currentShelf.height
            if abs(dw) < 0.6 && abs(dh) < 0.6 {
                self.currentShelf = self.targetShelf
                timer.invalidate()
            } else {
                self.currentShelf.width += dw * rate
                self.currentShelf.height += dh * rate
            }
            self.needsDisplay = true
        }
        if let sizeAnimation { RunLoop.main.add(sizeAnimation, forMode: .common) }
    }

    /// Only the drawn shelf takes the mouse. Everywhere else the window is
    /// transparent and must stay click-through, or it would eat menu-bar
    /// clicks across the whole top of the screen.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard settledRect.contains(local) else { return nil }
        // Collapsed, only the pet itself is clickable. The rest of the shelf
        // is sitting on the menu bar and must let clicks through, or reaching
        // for a menu lands on an invisible window instead.
        if stage == .collapsed {
            let b = shelfRect
            let size = min(22, b.height - 8)
            let pet = NSRect(x: b.minX + 11, y: b.midY - size / 2,
                             width: size, height: size).insetBy(dx: -6, dy: -4)
            return pet.contains(local) ? self : nil
        }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // The slab. Square at the top so it meets the screen edge with no
        // seam; rounded only at the bottom, so it looks moulded rather than
        // like a window that happens to be up there.
        let b = shelfRect
        guard b.width > 1, b.height > 1 else { return }
        let r: CGFloat = min(26, b.height * 0.7)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: b.minX, y: b.maxY))
        path.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        path.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY),
                    tangent2End: CGPoint(x: b.minX + r, y: b.minY), radius: r)
        path.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        path.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY),
                    tangent2End: CGPoint(x: b.maxX, y: b.minY + r), radius: r)
        path.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()

        switch stage {
        case .collapsed: return drawCollapsed()
        case .peek:      return drawResting(ctx)
        case .expanded:  break
        }
        guard !entries.isEmpty || !rows.isEmpty else { return }
        drawRail()
        switch outgoingMode ?? mode {
        case .pets:     drawExpanded(ctx)
        case .chat:     drawChat()
        case .activity: drawActivity()
        }
    }

    // MARK: text

    private func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight,
                      _ colour: NSColor, at origin: NSPoint, maxWidth: CGFloat = .greatestFiniteMagnitude,
                      rightAligned: Bool = false, centred: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centred ? .center : (rightAligned ? .right : .left)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: colour,
            .paragraphStyle: style,
        ]
        let rect = NSRect(x: origin.x, y: origin.y - size - 2,
                          width: min(maxWidth, max(10, shelfRect.maxX - origin.x)), height: size + 6)
        NSAttributedString(string: string, attributes: attrs).draw(in: rect)
    }

    /// The dark elevated card the design puts every body on. Without it the
    /// content floats on bare black and the panel reads as a void.
    private func card(_ rect: NSRect, alpha: CGFloat = 1) {
        guard rect.width > 2, rect.height > 2 else { return }
        NSColor(white: 0.078, alpha: alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill()
    }

    /// Soft bloom behind a pet — the only light source in the composition.
    private func glow(_ centre: NSPoint, radius: CGFloat, colour: NSColor, alpha: CGFloat) {
        guard alpha > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colours = [colour.withAlphaComponent(0.22 * alpha).cgColor,
                       colour.withAlphaComponent(0).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colours, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: radius,
                               options: .drawsAfterEndLocation)
        ctx.restoreGState()
    }

    // MARK: the mode rail

    private func drawRail() {
        let frames = railFrames()
        // The rail sits on its own recessed track, as in the design — without
        // it the segments float and the active pill has nothing to sit in.
        if let first = frames.first, let last = frames.last {
            let track = NSRect(x: first.1.minX - 3, y: first.1.minY - 3,
                               width: last.1.maxX - first.1.minX + 6,
                               height: first.1.height + 6)
            NSColor(white: 0.07, alpha: 1).setFill()
            NSBezierPath(roundedRect: track, xRadius: track.height / 2,
                         yRadius: track.height / 2).fill()
        }
        // The active pill slides between segments rather than cutting, so the
        // selection reads as one object moving.
        if let to = frames.first(where: { $0.0 == mode })?.1 {
            let from = outgoingMode.flatMap { o in frames.first(where: { $0.0 == o })?.1 } ?? to
            let p = min(1, modeFade / 0.5)
            let eased = 1 - pow(1 - p, 3)
            let pill = NSRect(x: from.minX + (to.minX - from.minX) * eased,
                              y: to.minY,
                              width: from.width + (to.width - from.width) * eased,
                              height: to.height)
            NSColor(white: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
        }
        for (m, pill) in frames {
            text(m.title, 12, m == mode ? .semibold : .medium,
                 m == mode ? .white : NSColor(white: 0.56, alpha: 1),
                 at: NSPoint(x: pill.minX + 14, y: pill.maxY - 5))
        }
        if !summary.isEmpty {
            text(summary, 11, .regular, NSColor(white: 0.52, alpha: 1),
                 at: NSPoint(x: settledRect.maxX - 280, y: settledRect.maxY - 15),
                 maxWidth: 262, rightAligned: true)
        }
    }

    // MARK: states

    /// The whole UI when nobody is using it: one dot in the active pet's
    /// status colour.
    ///
    /// It sits off-centre deliberately. On a notched Mac the cut-out is not a
    /// display area, so anything drawn dead centre is simply not rendered —
    /// the dot has to land on the visible strip beside it.
    private func drawCollapsed() {
        let b = shelfRect
        guard let entry = entries.indices.contains(activeIndex) ? entries[activeIndex] : entries.first
        else { return }

        // Left strip: the active pet, animating. A character that is actually
        // moving is what tells you the app is alive; a dot only tells you it
        // is installed.
        let size = min(22, b.height - 8)
        let petRect = NSRect(x: b.minX + 11, y: b.midY - size / 2, width: size, height: size)
        if let image = entry.frame(at: clock) {
            glow(NSPoint(x: petRect.midX, y: petRect.midY), radius: size * 0.95,
                 colour: entry.tint, alpha: entry.isBusy ? 0.55 : 0.22)
            image.draw(in: Self.aspectFit(image.size, in: petRect), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // Right strip: one dot per other pet, the busy ones breathing.
        let others = entries.enumerated().filter { $0.offset != activeIndex }.map { $0.element }
        let dot: CGFloat = 6
        var x = b.maxX - 11 - CGFloat(min(others.count, 3)) * (dot + 4)
        for other in others.prefix(3) {
            let pulse = other.isBusy ? 0.55 + 0.45 * CGFloat(0.5 + 0.5 * sin(clock * 2.4)) : 0.5
            other.tint.withAlphaComponent(pulse).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: b.midY - dot / 2,
                                        width: dot, height: dot)).fill()
            x += dot + 4
        }
    }

    private func drawResting(_ ctx: CGGraphicsContextAlias) {
        guard !entries.isEmpty else { return }
        let b = shelfRect
        let size: CGFloat = 20
        let y = b.midY - size / 2
        let dot: CGFloat = 7
        let others = entries.enumerated().filter { $0.offset != activeIndex }.map { $0.element }

        // At notch width there is only room for the active pet and a couple of
        // dots. Lay them out from the centre and drop the dots entirely when
        // they would not fit, rather than letting anything spill past the edge.
        let dotsWidth = CGFloat(min(others.count, 3)) * (dot + 3)
        let needed = size + 8 + dotsWidth
        let showDots = needed <= b.width - 16

        var x = b.midX - (showDots ? needed : size) / 2
        draw(entries[activeIndex], in: NSRect(x: x, y: y, width: size, height: size),
             lit: true, ctx: ctx)
        guard showDots else { return }
        x += size + 8
        for entry in others.prefix(3) {
            entry.tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: b.midY - dot / 2,
                                        width: dot, height: dot)).fill()
            x += dot + 3
        }
    }

    /// Frames of each carousel slot, in `entries` order. Shared by drawing and
    /// hit-testing so a click can never land on a pet other than the one drawn
    /// under the pointer.
    /// One visible slot: which entry, where, and how far from the front.
    struct Slot {
        let index: Int
        let rect: NSRect
        /// 0 at the front, growing with distance. Fractional, because the row
        /// is a continuous position rather than a set of discrete places.
        let distance: CGFloat
    }

    /// The carousel's position, in roster units. 2.0 means pet 2 is centred;
    /// 2.5 means the row is halfway between 2 and 3.
    ///
    /// Everything about the row is derived from this one number, which is what
    /// lets a two-finger swipe move it continuously — the pets travel with
    /// your fingers, the way a picker does, instead of cross-fading between
    /// fixed states.
    private var carousel: CGFloat = 0
    private var carouselVelocity: CGFloat = 0
    private var settleTimer: Timer?

    private func wrapped(_ i: Int) -> Int {
        let n = entries.count
        guard n > 0 else { return 0 }
        return ((i % n) + n) % n
    }

    private func slots() -> [Slot] {
        let n = entries.count
        guard n > 0 else { return [] }
        let body = bodyRect()
        let baseline = body.minY + Self.rowCentre(in: body)
        let spacing: CGFloat = 78
        let centre = Int(carousel.rounded())

        var out: [Slot] = []
        for step in -3...3 {
            let slotIndex = centre + step
            if n < 5, !(0..<n).contains(slotIndex) { continue }
            // Signed offset from the centre of the row, in slot units.
            let offset = CGFloat(slotIndex) - carousel
            let d = abs(offset)
            guard d < 3.2 else { continue }
            // Size falls off with distance; interpolating rather than
            // stepping is what makes a swipe read as one continuous move.
            let size = max(28, 76 - d * 21)
            let x = body.midX + offset * spacing
            out.append(Slot(index: wrapped(slotIndex),
                            rect: NSRect(x: x - size / 2, y: baseline - size / 2,
                                         width: size, height: size),
                            distance: d))
        }
        // Far slots first so nearer pets overlap them, never the other way.
        return out.sorted { $0.distance > $1.distance }
    }

    /// Two-finger swipe moves the row directly.
    override func scrollWheel(with event: NSEvent) {
        guard stage == .expanded, mode == .pets, entries.count > 1 else { return }
        settleTimer?.invalidate()
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        carousel -= delta / 90
        if entries.count < 5 {
            carousel = min(max(0, carousel), CGFloat(entries.count - 1))
        }
        activeIndex = wrapped(Int(carousel.rounded()))
        needsDisplay = true
        if event.phase == .ended || event.momentumPhase == .ended || event.phase == [] {
            settle(to: carousel.rounded())
        }
    }

    /// Spring the row onto the nearest pet. Critically damped-ish: it arrives
    /// and stops, with no bounce — a picker that wobbles feels broken.
    private func settle(to target: CGFloat) {
        settleTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { return timer.invalidate() }
            let gap = target - self.carousel
            self.carouselVelocity = self.carouselVelocity * 0.72 + gap * 0.28
            self.carousel += self.carouselVelocity
            if abs(gap) < 0.002, abs(self.carouselVelocity) < 0.002 {
                self.carousel = target
                self.carouselVelocity = 0
                timer.invalidate()
            }
            self.activeIndex = self.wrapped(Int(self.carousel.rounded()))
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        settleTimer = t
    }

    /// Clicking a pet slides the row to it rather than cutting.
    func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let n = CGFloat(entries.count)
        var target = CGFloat(index)
        // Travel the short way round the ring.
        if entries.count >= 5 {
            while target - carousel > n / 2 { target -= n }
            while carousel - target > n / 2 { target += n }
        }
        settle(to: target)
    }

    /// Largest rect of `size`'s aspect ratio that fits inside `bounds`.
    static func aspectFit(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// The Pets body is laid out from one ladder of offsets above the card's
    /// bottom edge, so the row, the selection bar, the name and the status
    /// pairing can't drift into each other — which they did when each was
    /// derived separately and the name landed on top of the word.
    private static func rowCentre(in body: NSRect) -> CGFloat { body.height - 84 }
    private static let barY: CGFloat = 80
    private static let nameY: CGFloat = 72
    private static let wordY: CGFloat = 50
    private static let captionY: CGFloat = 25

    /// The elevated card every body sits on.
    private func bodyRect() -> NSRect {
        let b = settledRect
        return NSRect(x: b.minX + 14, y: b.minY + 12,
                      width: b.width - 28, height: b.height - 58)
    }

    private func drawExpanded(_ ctx: CGGraphicsContextAlias) {
        let body = bodyRect()
        card(body, alpha: appear * bodyAlpha)

        for slot in slots() {
            let t = stagger(Int(slot.distance.rounded()))
            guard t > 0.01 else { continue }
            // Opacity falls off continuously with distance too, so nothing
            // pops as it passes the front.
            let base = max(0.26, 1 - slot.distance * 0.36)
            let lifted = slot.rect.offsetBy(dx: 0, dy: (1 - t) * -10)
            // The halo belongs to whatever is at the front, fading as the row
            // moves so it travels with the selection instead of jumping.
            if slot.distance < 1 {
                glow(NSPoint(x: lifted.midX, y: lifted.midY),
                     radius: lifted.width * 1.15, colour: entries[slot.index].tint,
                     alpha: (1 - slot.distance) * t * bodyAlpha)
            }
            draw(entries[slot.index], in: lifted, lit: slot.distance < 0.5,
                 alpha: base * t * bodyAlpha, ctx: ctx)
        }

        guard entries.indices.contains(activeIndex) else { return }
        let t = stagger(3) * bodyAlpha
        guard t > 0.01 else { return }
        let front = entries[activeIndex]
        let lift = (1 - stagger(3)) * 8

        // A short bar in the pet's own colour under the front slot, as the
        // design has it — it anchors the selection without drawing a box.
        let barW: CGFloat = 32
        let bar = NSRect(x: body.midX - barW / 2,
                         y: body.minY + Self.barY - lift, width: barW, height: 3)
        front.tint.withAlphaComponent(0.9 * t).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()

        text(front.slug, 11.5, .semibold, NSColor(white: 0.78, alpha: t),
             at: NSPoint(x: body.minX, y: body.minY + Self.nameY - lift),
             maxWidth: body.width, centred: true)
        text(activeWord, 21, .semibold, NSColor(white: 1, alpha: t),
             at: NSPoint(x: body.minX, y: body.minY + Self.wordY - lift),
             maxWidth: body.width, centred: true)
        text(activeCaption, 12, .regular, NSColor(white: 0.52, alpha: t),
             at: NSPoint(x: body.minX, y: body.minY + Self.captionY - lift),
             maxWidth: body.width, centred: true)
    }

    // MARK: chat

    /// The conversation with whichever pet is at the front of the carousel —
    /// so switching pets switches the thread, and the roster stays the context
    /// for every mode.
    private func drawChat() {
        let body = bodyRect()
        card(body, alpha: appear * bodyAlpha)

        // Composer sits on the floor of the card, where a reply would be typed.
        let field = NSRect(x: body.minX + 14, y: body.minY + 12,
                           width: body.width - 28, height: 34)
        NSColor(white: 0.13, alpha: appear * bodyAlpha).setFill()
        NSBezierPath(roundedRect: field, xRadius: 17, yRadius: 17).fill()
        let who = entries.indices.contains(activeIndex) ? entries[activeIndex].slug : "the pet"
        text("Ask \(who)…", 13, .regular,
             NSColor(white: 0.44, alpha: appear * bodyAlpha),
             at: NSPoint(x: field.minX + 16, y: field.maxY - 9), maxWidth: field.width - 32)
        // A caret that blinks, so the field reads as ready rather than drawn.
        if appear > 0.9 {
            let on = sin(clock * 3.4) > 0
            if on {
                NSColor(white: 0.7, alpha: 0.8 * bodyAlpha).setFill()
                NSBezierPath(rect: NSRect(x: field.minX + 16 + textWidth("Ask \(who)…", 13) + 3,
                                          y: field.midY - 7, width: 1.5, height: 14)).fill()
            }
        }

        guard !chat.isEmpty else {
            text("No conversation yet.", 13, .regular,
                 NSColor(white: 0.44, alpha: appear * bodyAlpha),
                 at: NSPoint(x: body.minX + 18, y: body.maxY - 20), maxWidth: body.width - 36)
            return
        }

        // Newest at the bottom, filling upward, so the latest reply is nearest
        // the composer — the same way every chat in the world reads.
        var y = field.maxY + 16
        for (i, line) in chat.reversed().enumerated() {
            let t = stagger(i) * bodyAlpha
            guard t > 0.01 else { break }
            let maxW = body.width - 56
            let h = max(22, ceil(textHeight(line.text, 13, maxW - 24)) + 16)
            guard y + h < body.maxY - 8 else { break }
            let w = min(maxW, textWidth(line.text, 13) + 26)
            let bubble = NSRect(x: line.isUser ? body.maxX - 18 - w : body.minX + 18,
                                y: y + (1 - t) * -6, width: w, height: h)
            (line.isUser ? NSColor(white: 0.19, alpha: t)
                         : NSColor(white: 0.11, alpha: t)).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 13, yRadius: 13).fill()
            text(line.text, 13, .regular,
                 NSColor(white: line.isUser ? 0.96 : 0.82, alpha: t),
                 at: NSPoint(x: bubble.minX + 13, y: bubble.maxY - 7), maxWidth: w - 26)
            y += h + 8
        }
    }

    private func textWidth(_ s: String, _ size: CGFloat) -> CGFloat {
        s.size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    private func textHeight(_ s: String, _ size: CGFloat, _ width: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size)]
        return NSAttributedString(string: s, attributes: attrs)
            .boundingRect(with: NSSize(width: width, height: 400),
                          options: [.usesLineFragmentOrigin]).height
    }

    // MARK: the activity feed

    private func drawActivity() {
        guard !rows.isEmpty else {
            text("No turns yet — send a pet a message.", 13, .regular,
                 NSColor(white: 0.56, alpha: 1),
                 at: NSPoint(x: settledRect.minX + 30, y: settledRect.maxY - 80))
            return
        }
        let body = bodyRect()
        card(body, alpha: appear * bodyAlpha)

        let rowHeight: CGFloat = 44
        var y = body.maxY - 6
        let fits = max(0, Int((y - body.minY - 4) / rowHeight))
        for (i, row) in rows.prefix(fits).enumerated() {
            let t = stagger(i) * bodyAlpha
            if t > 0.01 { draw(row, topY: y + (1 - t) * -8, height: rowHeight, alpha: t, body: body) }
            y -= rowHeight
        }
    }

    private func draw(_ row: ActivityRow, topY: CGFloat, height: CGFloat,
                      alpha: CGFloat, body: NSRect) {
        let midY = topY - height / 2
        let avatar = NSRect(x: body.minX + 16, y: midY - 13, width: 26, height: 26)

        // No bloom in the feed. A halo belongs to the pet at the front of the
        // carousel and nowhere else — five of them turns a dark panel grey and
        // the light stops meaning anything.
        let frame: NSImage? = row.state == .live && row.frames.count > 1
            ? row.frames[Int(clock * row.fps) % row.frames.count]
            : (row.frames.first ?? row.image)
        if let image = frame {
            image.draw(in: Self.aspectFit(image.size, in: avatar), from: .zero,
                       operation: .sourceOver,
                       fraction: (row.state == .live ? 1.0 : 0.72) * alpha,
                       respectFlipped: true, hints: nil)
        } else {
            row.tint.withAlphaComponent((row.state == .live ? 1.0 : 0.7) * alpha).setFill()
            NSBezierPath(ovalIn: avatar).fill()
        }
        if row.state == .live {
            let spin = clock.truncatingRemainder(dividingBy: 2.6) / 2.6 * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: avatar.midX, y: avatar.midY),
                          radius: avatar.width / 2 + 6, startAngle: spin, endAngle: spin + 260)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            row.tint.withAlphaComponent(0.95 * alpha).setStroke()
            arc.stroke()
        }

        let textX = body.minX + 58
        text("\(row.name) · \(row.provider)", 10.5, .regular,
             NSColor(white: 0.5, alpha: alpha),
             at: NSPoint(x: textX, y: topY - 9), maxWidth: 260)
        text(row.activity, 13, row.state == .live ? .semibold : .regular,
             NSColor(white: row.state == .live ? 1 : 0.78, alpha: alpha),
             at: NSPoint(x: textX, y: topY - 25), maxWidth: body.width - 330)

        var rightEdge = body.maxX - 16
        text(row.trailing, 10.5, .regular, NSColor(white: 0.5, alpha: alpha),
             at: NSPoint(x: rightEdge - 150, y: topY - 19), maxWidth: 150, rightAligned: true)
        rightEdge -= 160

        if let remedy = row.remedy {
            let w = remedy.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width + 24
            let pill = NSRect(x: rightEdge - w, y: midY - 11, width: w, height: 22)
            let path = NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11)
            path.lineWidth = 1
            NSColor(white: 0.34, alpha: alpha).setStroke()
            path.stroke()
            text(remedy, 11, .semibold, NSColor(white: 1, alpha: alpha),
                 at: NSPoint(x: pill.minX + 12, y: pill.maxY - 4))
            rightEdge -= w + 10
        }

        // Status chip in the row's own hue — fill, border and label all one
        // colour, as the chips in the design do.
        if row.state != .live {
            let label = row.state == .done ? "done"
                      : (row.state == .failed ? "failed" : "interrupted")
            let w = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)]).width + 20
            let chip = NSRect(x: rightEdge - w, y: midY - 9, width: w, height: 18)
            row.tint.withAlphaComponent(0.13 * alpha).setFill()
            let path = NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9)
            path.fill()
            path.lineWidth = 1
            row.tint.withAlphaComponent(0.34 * alpha).setStroke()
            path.stroke()
            text(label, 10.5, .semibold, row.tint.withAlphaComponent(alpha),
                 at: NSPoint(x: chip.minX + 10, y: chip.maxY - 3))
        }
    }

    // MARK: drawing one pet

    private func draw(_ entry: Entry, in rect: NSRect, lit: Bool,
                      alpha: CGFloat = 1.0, ctx: CGGraphicsContextAlias) {
        if lit {
            // The pet's own glow is the only light in the composition.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: rect.width * 0.55,
                          color: entry.tint.withAlphaComponent(0.55).cgColor)
            entry.tint.withAlphaComponent(0.001).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)).fill()
            ctx.restoreGState()
        }
        // Sprite frames are taller than they are wide; drawing them into a
        // square stretches the pet. Fit, don't fill.
        guard let image = entry.frame(at: clock) else { return }
        var box = rect
        if lit {
            // A slow breath on the active pet. Barely perceptible on any one
            // frame, but it is the difference between a character standing
            // there and a picture of one.
            let breath = 1 + 0.025 * CGFloat(sin(clock * 1.9))
            box = NSRect(x: rect.midX - rect.width * breath / 2,
                         y: rect.midY - rect.height * breath / 2,
                         width: rect.width * breath, height: rect.height * breath)
        }
        image.draw(in: Self.aspectFit(image.size, in: box),
                   from: .zero, operation: .sourceOver,
                   fraction: alpha, respectFlipped: true, hints: nil)

        // Status ring: a gap in the stroke while the agent is working, a
        // closed quiet ring otherwise. Motion carries state; identity does not.
        guard lit else { return }
        let d = max(rect.width, rect.height) + 14
        let ring = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        // Quiet full ring when idle; a long arc with one gap while working, so
        // it reads as a ring that is turning rather than a stray crescent.
        let quiet = NSBezierPath(ovalIn: ring)
        quiet.lineWidth = 2
        entry.tint.withAlphaComponent(entry.isBusy ? 0.16 : 0.3).setStroke()
        quiet.stroke()
        if entry.isBusy {
            // Turning, not static: the arc sweeps once every 2.6s.
            let spin = clock.truncatingRemainder(dividingBy: 2.6) / 2.6 * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY),
                          radius: d / 2, startAngle: spin, endAngle: spin + 260)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            entry.tint.withAlphaComponent(0.95).setStroke()
            arc.stroke()
        }
    }
}

/// Small alias so the drawing helpers read clearly.
typealias CGGraphicsContextAlias = CGContext
