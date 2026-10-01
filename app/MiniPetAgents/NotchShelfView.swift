import AppKit

/// Draws the notch shelf: a black slab that bleeds off the top of the screen,
/// with the pets laid out along it.
///
/// Resting, it shows the active pet on the left and the rest as a condensed
/// cluster on the right. Expanded, the pets become a horizontal character
/// select — the active one large and lit, its neighbours smaller and dimmer —
/// so switching pets reads as a choice rather than a menu.
final class NotchShelfView: NSView {

    struct Entry {
        let slug: String
        let image: NSImage
        let tint: NSColor
        let isBusy: Bool
    }

    var onHoverChanged: ((Bool) -> Void)?
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

    func setExpanded(_ value: Bool, size: NSSize) {
        expanded = value
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

        guard !entries.isEmpty else { return }
        expanded ? drawExpanded(ctx) : drawResting(ctx)
    }

    // MARK: states

    private func drawResting(_ ctx: CGGraphicsContextAlias) {
        let size: CGFloat = 24
        let y = bounds.midY - size / 2
        // Active pet, left of the cut-out.
        draw(entries[activeIndex], in: NSRect(x: 16, y: y, width: size, height: size), lit: true, ctx: ctx)

        // Everyone else as a condensed cluster on the right.
        let others = entries.enumerated().filter { $0.offset != activeIndex }.map { $0.element }
        let dot: CGFloat = 9
        var x = bounds.maxX - 16 - CGFloat(min(others.count, 4)) * (dot + 4)
        for entry in others.prefix(4) {
            let rect = NSRect(x: x, y: bounds.midY - dot / 2, width: dot, height: dot)
            entry.tint.setFill()
            NSBezierPath(ovalIn: rect).fill()
            x += dot + 4
        }
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
