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
        case pets, activity
        var title: String { self == .pets ? "Pets" : "Activity" }
    }

    struct Entry {
        let slug: String
        let image: NSImage
        let tint: NSColor
        let isBusy: Bool
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
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onModeChanged: ((Mode) -> Void)?
    /// A click anywhere that isn't a control — this is what opens the panel.
    var onActivate: (() -> Void)?
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
    /// 0→1 after the panel opens. Drives the staggered arrival so the roster
    /// assembles rather than snapping into place.
    private var appear: CGFloat = 0
    private var appearTimer: Timer?
    private(set) var entries: [Entry] = []
    private(set) var activeIndex = 0
    private var expanded = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }

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
        mode = newMode
        restartAppear()
        needsDisplay = true
        onModeChanged?(newMode)
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
        if let i = slotFrames().firstIndex(where: { $0.contains(point) }) {
            activeIndex = i
            needsDisplay = true
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
        return settledRect.contains(local) ? self : nil
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
        switch mode {
        case .pets:     drawExpanded(ctx)
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
        let colours = [colour.withAlphaComponent(0.30 * alpha).cgColor,
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
        for (m, pill) in frames {
            if m == mode {
                NSColor(white: 0.16, alpha: 1).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
            }
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
        let d: CGFloat = entry.isBusy ? 8 : 6
        let rect = NSRect(x: b.minX + 14, y: b.midY - d / 2, width: d, height: d)
        entry.tint.withAlphaComponent(entry.isBusy ? 1.0 : 0.75).setFill()
        NSBezierPath(ovalIn: rect).fill()
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
    private func slotFrames() -> [NSRect] {
        var frames = [NSRect](repeating: .zero, count: entries.count)
        guard !entries.isEmpty else { return frames }
        let active: CGFloat = 74, neighbour: CGFloat = 46, gap: CGFloat = 20
        // Sit the row in the panel's own vertical middle, below the rail.
        let baseline = shelfRect.minY + (shelfRect.height - 34) / 2
        frames[activeIndex] = NSRect(x: shelfRect.midX - active / 2, y: baseline - active / 2,
                                     width: active, height: active)
        var x = shelfRect.midX - active / 2 - gap
        for offset in 1...2 {
            let i = activeIndex - offset
            guard i >= 0 else { break }
            let s = neighbour - CGFloat(offset - 1) * 10
            x -= s
            frames[i] = NSRect(x: x, y: baseline - s / 2, width: s, height: s)
            x -= gap
        }
        x = shelfRect.midX + active / 2 + gap
        for offset in 1...2 {
            let i = activeIndex + offset
            guard i < entries.count else { break }
            let s = neighbour - CGFloat(offset - 1) * 10
            frames[i] = NSRect(x: x, y: baseline - s / 2, width: s, height: s)
            x += s + gap
        }
        // Centre the group that actually exists. With the active pet at either
        // end of the roster there are no neighbours on one side, and centring
        // only the active pet leaves the row visibly lopsided.
        let used = frames.filter { $0 != .zero }
        if let minX = used.map({ $0.minX }).min(), let maxX = used.map({ $0.maxX }).max() {
            let shift = shelfRect.midX - (minX + maxX) / 2
            if abs(shift) > 0.5 {
                for i in frames.indices where frames[i] != .zero {
                    frames[i] = frames[i].offsetBy(dx: shift, dy: 0)
                }
            }
        }
        return frames
    }

    /// Largest rect of `size`'s aspect ratio that fits inside `bounds`.
    static func aspectFit(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func drawExpanded(_ ctx: CGGraphicsContextAlias) {
        let b = settledRect
        let body = NSRect(x: b.minX + 14, y: b.minY + 12,
                          width: b.width - 28, height: b.height - 58)
        card(body, alpha: appear)

        let frames = slotFrames()
        for (i, rect) in frames.enumerated() where rect != .zero {
            let distance = abs(i - activeIndex)
            let t = stagger(distance)
            guard t > 0.01 else { continue }
            let base: CGFloat = distance == 0 ? 1.0 : (distance == 1 ? 0.55 : 0.36)
            // Arrive from slightly below as well as fading, so the row
            // assembles rather than appearing.
            let lifted = rect.offsetBy(dx: 0, dy: (1 - t) * -10)
            if distance == 0 {
                glow(NSPoint(x: lifted.midX, y: lifted.midY),
                     radius: lifted.width * 1.3, colour: entries[i].tint, alpha: t)
            }
            draw(entries[i], in: lifted, lit: distance == 0, alpha: base * t, ctx: ctx)
        }

        // The status pairing: whimsical word large, the real work beneath it.
        guard !activeWord.isEmpty || !activeCaption.isEmpty else { return }
        let t = stagger(3)
        guard t > 0.01 else { return }
        let textY = body.minY + 46
        text(activeWord, 20, .semibold, NSColor(white: 1, alpha: t),
             at: NSPoint(x: body.minX, y: textY), maxWidth: body.width, centred: true)
        text(activeCaption, 12, .regular, NSColor(white: 0.56, alpha: t),
             at: NSPoint(x: body.minX, y: textY - 22), maxWidth: body.width, centred: true)
    }

    // MARK: the activity feed

    private func drawActivity() {
        guard !rows.isEmpty else {
            text("No turns yet — send a pet a message.", 13, .regular,
                 NSColor(white: 0.56, alpha: 1),
                 at: NSPoint(x: settledRect.minX + 30, y: settledRect.maxY - 80))
            return
        }
        let b = settledRect
        let body = NSRect(x: b.minX + 14, y: b.minY + 12,
                          width: b.width - 28, height: b.height - 58)
        card(body, alpha: appear)

        let rowHeight: CGFloat = 44
        var y = body.maxY - 6
        let fits = max(0, Int((y - body.minY - 4) / rowHeight))
        for (i, row) in rows.prefix(fits).enumerated() {
            let t = stagger(i)
            if t > 0.01 { draw(row, topY: y + (1 - t) * -8, height: rowHeight, alpha: t, body: body) }
            y -= rowHeight
        }
    }

    private func draw(_ row: ActivityRow, topY: CGFloat, height: CGFloat,
                      alpha: CGFloat, body: NSRect) {
        let midY = topY - height / 2
        let avatar = NSRect(x: body.minX + 16, y: midY - 13, width: 26, height: 26)

        // A live row carries its arc and a faint bloom; a settled one is
        // completely still, so a quiet row reads as finished without being read.
        if row.state == .live {
            glow(NSPoint(x: avatar.midX, y: avatar.midY), radius: 26,
                 colour: row.tint, alpha: alpha)
        }
        if let image = row.image {
            image.draw(in: Self.aspectFit(image.size, in: avatar), from: .zero,
                       operation: .sourceOver,
                       fraction: (row.state == .live ? 1.0 : 0.72) * alpha,
                       respectFlipped: true, hints: nil)
        } else {
            row.tint.withAlphaComponent((row.state == .live ? 1.0 : 0.7) * alpha).setFill()
            NSBezierPath(ovalIn: avatar).fill()
        }
        if row.state == .live {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: avatar.midX, y: avatar.midY),
                          radius: avatar.width / 2 + 6, startAngle: 40, endAngle: 300)
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
        entry.image.draw(in: Self.aspectFit(entry.image.size, in: rect),
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
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY),
                          radius: d / 2, startAngle: 40, endAngle: 300)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            entry.tint.withAlphaComponent(0.95).setStroke()
            arc.stroke()
        }
    }
}

/// Small alias so the drawing helpers read clearly.
typealias CGGraphicsContextAlias = CGContext
