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
    var shelfRect: NSRect {
        NSRect(x: (bounds.width - currentShelf.width) / 2,
               y: bounds.maxY - currentShelf.height,
               width: currentShelf.width, height: currentShelf.height)
    }
    private(set) var mode: Mode = .pets
    private(set) var rows: [ActivityRow] = []
    private(set) var summary: String = ""
    /// Rail segment frames, recomputed on every draw so hit-testing can never
    /// disagree with what is on screen.
    private var railHits: [(Mode, NSRect)] = []
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

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        needsDisplay = true
        onModeChanged?(newMode)
    }

    override func mouseDown(with event: NSEvent) {
        guard stage == .expanded else {
            onActivate?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = railHits.first(where: { $0.1.contains(point) }) {
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
        return shelfRect.contains(local) ? self : nil
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
                      rightAligned: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = rightAligned ? .right : .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: colour,
            .paragraphStyle: style,
        ]
        let rect = NSRect(x: origin.x, y: origin.y - size - 2,
                          width: min(maxWidth, max(10, shelfRect.maxX - origin.x)), height: size + 6)
        NSAttributedString(string: string, attributes: attrs).draw(in: rect)
    }

    // MARK: the mode rail

    private func drawRail() {
        railHits.removeAll()
        var x = shelfRect.minX + 18
        let y = shelfRect.maxY - 34
        for m in Mode.allCases {
            let label = m.title
            let w = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 26
            let pill = NSRect(x: x, y: y, width: w, height: 24)
            if m == mode {
                NSColor(white: 0.15, alpha: 1).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
            }
            text(label, 12, m == mode ? .semibold : .medium,
                 m == mode ? .white : NSColor(white: 0.56, alpha: 1),
                 at: NSPoint(x: pill.minX + 13, y: pill.maxY - 5))
            railHits.append((m, pill))
            x += w + 4
        }
        if !summary.isEmpty {
            text(summary, 11, .regular, NSColor(white: 0.56, alpha: 1),
                 at: NSPoint(x: shelfRect.maxX - 260, y: y + 19), maxWidth: 242, rightAligned: true)
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
        let frames = slotFrames()
        for (i, rect) in frames.enumerated() where rect != .zero {
            let distance = abs(i - activeIndex)
            let alpha: CGFloat = distance == 0 ? 1.0 : (distance == 1 ? 0.55 : 0.38)
            draw(entries[i], in: rect, lit: distance == 0, alpha: alpha, ctx: ctx)
        }
    }

    // MARK: the activity feed

    private func drawActivity() {
        guard !rows.isEmpty else {
            text("No turns yet — send a pet a message.", 13, .regular,
                 NSColor(white: 0.56, alpha: 1),
                 at: NSPoint(x: shelfRect.minX + 20, y: shelfRect.maxY - 80))
            return
        }
        let rowHeight: CGFloat = 46
        var y = shelfRect.maxY - 56
        for row in rows.prefix(max(0, Int((y - shelfRect.minY - 12) / rowHeight))) {
            draw(row, topY: y, height: rowHeight)
            y -= rowHeight
        }
    }

    private func draw(_ row: ActivityRow, topY: CGFloat, height: CGFloat) {
        let midY = topY - height / 2
        let avatar = NSRect(x: shelfRect.minX + 20, y: midY - 13, width: 26, height: 26)

        if let image = row.image {
            image.draw(in: Self.aspectFit(image.size, in: avatar), from: .zero,
                       operation: .sourceOver,
                       fraction: row.state == .live ? 1.0 : 0.72,
                       respectFlipped: true, hints: nil)
        } else {
            row.tint.withAlphaComponent(row.state == .live ? 1.0 : 0.7).setFill()
            NSBezierPath(ovalIn: avatar).fill()
        }

        // A live row keeps its arc; a settled one is completely still, so a
        // quiet row reads as finished without being read.
        if row.state == .live {
            let d = avatar.width + 12
            let c = NSPoint(x: avatar.midX, y: avatar.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: d / 2, startAngle: 40, endAngle: 300)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            row.tint.withAlphaComponent(0.95).setStroke()
            arc.stroke()
        }

        text("\(row.name) · \(row.provider)", 11, .regular,
             NSColor(white: 0.56, alpha: 1),
             at: NSPoint(x: shelfRect.minX + 62, y: topY - 10), maxWidth: 300)
        text(row.activity, 13, row.state == .live ? .semibold : .regular,
             row.state == .live ? .white : NSColor(white: 0.79, alpha: 1),
             at: NSPoint(x: shelfRect.minX + 62, y: topY - 26),
             maxWidth: shelfRect.width - 300)

        if let remedy = row.remedy {
            let w: CGFloat = 76
            let pill = NSRect(x: shelfRect.maxX - 20 - 150 - w - 10, y: midY - 11,
                              width: w, height: 22)
            let path = NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11)
            path.lineWidth = 1
            NSColor(white: 0.32, alpha: 1).setStroke()
            path.stroke()
            text(remedy, 11, .semibold, .white, at: NSPoint(x: pill.minX + 13, y: pill.maxY - 4))
        }

        text(row.trailing, 11, .regular, NSColor(white: 0.56, alpha: 1),
             at: NSPoint(x: shelfRect.maxX - 170, y: topY - 20), maxWidth: 150, rightAligned: true)
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
