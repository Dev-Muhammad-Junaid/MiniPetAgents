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

    func setStage(_ value: NotchCommandCentre.Stage, size: NSSize) {
        stage = value
        expanded = value == .expanded
        setFrameSize(size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // The slab. Square at the top so it meets the screen edge with no
        // seam; rounded only at the bottom, so it looks moulded rather than
        // like a window that happens to be up there.
        let r: CGFloat = 26
        let b = bounds
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
                          width: min(maxWidth, bounds.maxX - origin.x), height: size + 6)
        NSAttributedString(string: string, attributes: attrs).draw(in: rect)
    }

    // MARK: the mode rail

    private func drawRail() {
        railHits.removeAll()
        var x = bounds.minX + 18
        let y = bounds.maxY - 34
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
                 at: NSPoint(x: bounds.maxX - 260, y: y + 19), maxWidth: 242, rightAligned: true)
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
        guard let entry = entries.indices.contains(activeIndex) ? entries[activeIndex] : entries.first
        else { return }
        let d: CGFloat = entry.isBusy ? 8 : 6
        let rect = NSRect(x: bounds.minX + 14, y: bounds.midY - d / 2, width: d, height: d)
        entry.tint.withAlphaComponent(entry.isBusy ? 1.0 : 0.75).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawResting(_ ctx: CGGraphicsContextAlias) {
        guard !entries.isEmpty else { return }
        let size: CGFloat = 20
        let y = bounds.midY - size / 2
        let dot: CGFloat = 7
        let others = entries.enumerated().filter { $0.offset != activeIndex }.map { $0.element }

        // At notch width there is only room for the active pet and a couple of
        // dots. Lay them out from the centre and drop the dots entirely when
        // they would not fit, rather than letting anything spill past the edge.
        let dotsWidth = CGFloat(min(others.count, 3)) * (dot + 3)
        let needed = size + 8 + dotsWidth
        let showDots = needed <= bounds.width - 16

        var x = bounds.midX - (showDots ? needed : size) / 2
        draw(entries[activeIndex], in: NSRect(x: x, y: y, width: size, height: size),
             lit: true, ctx: ctx)
        guard showDots else { return }
        x += size + 8
        for entry in others.prefix(3) {
            entry.tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - dot / 2,
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
        let baseline = bounds.minY + 52
        frames[activeIndex] = NSRect(x: bounds.midX - active / 2, y: baseline - active / 2,
                                     width: active, height: active)
        var x = bounds.midX - active / 2 - gap
        for offset in 1...2 {
            let i = activeIndex - offset
            guard i >= 0 else { break }
            let s = neighbour - CGFloat(offset - 1) * 10
            x -= s
            frames[i] = NSRect(x: x, y: baseline - s / 2, width: s, height: s)
            x -= gap
        }
        x = bounds.midX + active / 2 + gap
        for offset in 1...2 {
            let i = activeIndex + offset
            guard i < entries.count else { break }
            let s = neighbour - CGFloat(offset - 1) * 10
            frames[i] = NSRect(x: x, y: baseline - s / 2, width: s, height: s)
            x += s + gap
        }
        return frames
    }

    private func drawExpanded(_ ctx: CGGraphicsContextAlias) {
        let active: CGFloat = 74
        let neighbour: CGFloat = 46
        let gap: CGFloat = 20
        let baseline = bounds.minY + 52

        // Lay the row out from the centre so the active pet is always centred
        // and the others fall away either side.
        var slots: [(Entry, CGFloat, CGFloat, CGFloat)] = []   // entry, size, x, alpha
        slots.append((entries[activeIndex], active, bounds.midX - active / 2, 1.0))

        var x = bounds.midX - active / 2 - gap
        for offset in 1...2 {
            let i = activeIndex - offset
            guard i >= 0 else { break }
            let s = neighbour - CGFloat(offset - 1) * 10
            x -= s
            slots.append((entries[i], s, x, offset == 1 ? 0.55 : 0.38))
            x -= gap
        }
        x = bounds.midX + active / 2 + gap
        for offset in 1...2 {
            let i = activeIndex + offset
            guard i < entries.count else { break }
            let s = neighbour - CGFloat(offset - 1) * 10
            slots.append((entries[i], s, x, offset == 1 ? 0.55 : 0.38))
            x += s + gap
        }

        for (entry, size, x, alpha) in slots {
            let rect = NSRect(x: x, y: baseline - size / 2, width: size, height: size)
            draw(entry, in: rect, lit: alpha == 1.0, alpha: alpha, ctx: ctx)
        }
    }

    // MARK: the activity feed

    private func drawActivity() {
        guard !rows.isEmpty else {
            text("No turns yet — send a pet a message.", 13, .regular,
                 NSColor(white: 0.56, alpha: 1), at: NSPoint(x: 20, y: bounds.maxY - 80))
            return
        }
        let rowHeight: CGFloat = 46
        var y = bounds.maxY - 56
        for row in rows.prefix(Int((y - bounds.minY - 12) / rowHeight)) {
            draw(row, topY: y, height: rowHeight)
            y -= rowHeight
        }
    }

    private func draw(_ row: ActivityRow, topY: CGFloat, height: CGFloat) {
        let midY = topY - height / 2
        let avatar = NSRect(x: 20, y: midY - 13, width: 26, height: 26)

        if let image = row.image {
            image.draw(in: avatar, from: .zero, operation: .sourceOver,
                       fraction: row.state == .live ? 1.0 : 0.72, respectFlipped: true, hints: nil)
        } else {
            row.tint.withAlphaComponent(row.state == .live ? 1.0 : 0.7).setFill()
            NSBezierPath(ovalIn: avatar).fill()
        }

        // A live row keeps its ring turning; a settled one is completely
        // still, so a quiet row reads as finished without being read.
        if row.state == .live {
            let ring = avatar.insetBy(dx: -6, dy: -6)
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = 2
            path.setLineDash([ring.width * 0.8, ring.width * 2.3], count: 2, phase: 0)
            row.tint.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }

        text("\(row.name) · \(row.provider)", 11, .regular,
             NSColor(white: 0.56, alpha: 1), at: NSPoint(x: 60, y: topY - 10), maxWidth: 300)
        text(row.activity, 13, row.state == .live ? .semibold : .regular,
             row.state == .live ? .white : NSColor(white: 0.79, alpha: 1),
             at: NSPoint(x: 60, y: topY - 26), maxWidth: bounds.width - 300)

        if let remedy = row.remedy {
            let w: CGFloat = 76
            let pill = NSRect(x: bounds.maxX - 20 - 150 - w - 10, y: midY - 11, width: w, height: 22)
            NSColor(white: 0.18, alpha: 1).setStroke()
            let path = NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11)
            path.lineWidth = 1
            path.stroke()
            text(remedy, 11, .semibold, .white, at: NSPoint(x: pill.minX + 13, y: pill.maxY - 4))
        }

        text(row.trailing, 11, .regular, NSColor(white: 0.56, alpha: 1),
             at: NSPoint(x: bounds.maxX - 170, y: topY - 20), maxWidth: 150, rightAligned: true)
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
        entry.image.draw(in: rect, from: .zero, operation: .sourceOver,
                         fraction: alpha, respectFlipped: true, hints: nil)

        // Status ring: a gap in the stroke while the agent is working, a
        // closed quiet ring otherwise. Motion carries state; identity does not.
        guard lit else { return }
        let ring = rect.insetBy(dx: -7, dy: -7)
        let path = NSBezierPath(ovalIn: ring)
        path.lineWidth = 2
        entry.tint.withAlphaComponent(entry.isBusy ? 0.9 : 0.28).setStroke()
        if entry.isBusy {
            path.setLineDash([ring.width * 0.8, ring.width * 2.3], count: 2, phase: 0)
        }
        path.stroke()
    }
}

/// Small alias so the drawing helpers read clearly.
typealias CGGraphicsContextAlias = CGContext
