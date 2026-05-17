import AppKit
import QuartzCore

/// Translucent overlay shown while the user drags a pet.
/// Shows three drop targets — Dock (bottom), Left Stack, Right Stack —
/// all rendered with a white-tinted palette so they read cleanly on any
/// desktop background.  Releasing inside a target snaps the pet to that
/// placement; releasing elsewhere keeps it in Free Roam.
final class DropZoneOverlay {
    static let shared = DropZoneOverlay()

    private var dockWindow:  NSWindow?
    private var leftWindow:  NSWindow?
    private var rightWindow: NSWindow?

    private(set) var dockZoneRect:  NSRect = .zero
    private(set) var leftZoneRect:  NSRect = .zero
    private(set) var rightZoneRect: NSRect = .zero

    // MARK: - Show

    func show(on screen: NSScreen, dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        // Dock strip at the bottom
        let dockH: CGFloat = 96
        let pad:   CGFloat = 24
        dockZoneRect = NSRect(
            x: dockX - pad,
            y: max(screen.visibleFrame.minY - dockH * 0.4, screen.frame.minY),
            width: dockWidth + pad * 2,
            height: dockH
        )

        // Side strips running the full visible height
        let stripW: CGFloat = 100
        let stripY  = screen.visibleFrame.minY
        let stripH  = screen.visibleFrame.height
        leftZoneRect  = NSRect(x: screen.frame.minX,              y: stripY, width: stripW, height: stripH)
        rightZoneRect = NSRect(x: screen.frame.maxX - stripW,     y: stripY, width: stripW, height: stripH)

        showPanel(window: &dockWindow,  frame: dockZoneRect,  label: "Dock",        orientation: .horizontal)
        showPanel(window: &leftWindow,  frame: leftZoneRect,  label: "Left Stack",  orientation: .vertical)
        showPanel(window: &rightWindow, frame: rightZoneRect, label: "Right Stack", orientation: .vertical)
    }

    private func showPanel(window: inout NSWindow?,
                           frame: NSRect,
                           label: String,
                           orientation: ZonePanel.Orientation) {
        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 100)
            let v = ZonePanel(frame: NSRect(origin: .zero, size: frame.size))
            v.label = label
            v.orientation = orientation
            w.contentView = v
            window = w
        } else {
            window?.setFrame(frame, display: false)
            if let v = window?.contentView as? ZonePanel {
                v.frame = NSRect(origin: .zero, size: frame.size)
            }
        }
        (window?.contentView as? ZonePanel)?.isHighlighted = false
        window?.contentView?.needsDisplay = true
        window?.alphaValue = 0
        window?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window?.animator().alphaValue = 1
        }
    }

    // MARK: - Update

    @discardableResult
    func update(petCenter: NSPoint) -> PlacementMode {
        let inDock  = dockZoneRect.contains(petCenter)
        let inLeft  = leftZoneRect.contains(petCenter)
        let inRight = rightZoneRect.contains(petCenter)

        highlight(window: dockWindow,  on: inDock)
        highlight(window: leftWindow,  on: inLeft)
        highlight(window: rightWindow, on: inRight)

        if inDock  { return .dock }
        if inLeft  { return .leftStack }
        if inRight { return .rightStack }
        return .freeRoam
    }

    private func highlight(window: NSWindow?, on: Bool) {
        guard let v = window?.contentView as? ZonePanel, v.isHighlighted != on else { return }
        v.isHighlighted = on
        v.needsDisplay = true
    }

    // MARK: - Hide

    func hide() {
        for w in [dockWindow, leftWindow, rightWindow].compactMap({ $0 }) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                w.animator().alphaValue = 0
            }, completionHandler: { w.orderOut(nil) })
        }
    }

    // MARK: - Hit test

    func zoneAt(_ point: NSPoint) -> PlacementMode {
        if dockZoneRect.contains(point)  { return .dock }
        if leftZoneRect.contains(point)  { return .leftStack }
        if rightZoneRect.contains(point) { return .rightStack }
        return .freeRoam
    }
}

// MARK: - Zone panel view

private final class ZonePanel: NSView {
    enum Orientation { case horizontal, vertical }

    var isHighlighted = false {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }
    var label = ""
    var orientation: Orientation = .horizontal

    override func draw(_ dirtyRect: NSRect) {
        let r = orientation == .horizontal
            ? bounds.insetBy(dx: 6,  dy: 8)
            : bounds.insetBy(dx: 10, dy: 6)

        // White-tinted fill & border
        let path = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
        NSColor.white.withAlphaComponent(isHighlighted ? 0.28 : 0.09).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(isHighlighted ? 0.85 : 0.38).setStroke()
        path.lineWidth = isHighlighted ? 2.5 : 1.5
        path.stroke()

        // Label — rotated 90° for vertical panels so it reads along the strip
        let fontSize: CGFloat = orientation == .horizontal ? 13 : 11
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(isHighlighted ? 0.95 : 0.65)
        ]

        let primaryText = isHighlighted ? "Drop here" : label
        let primary = NSAttributedString(string: primaryText, attributes: attrs)
        let primarySize = primary.size()

        if orientation == .vertical {
            // Rotate the canvas so text reads top-to-bottom along the strip
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.rotate(by: -.pi / 2)
            primary.draw(at: NSPoint(x: -primarySize.width / 2, y: -primarySize.height / 2))

            // When highlighted, also draw the zone name above it
            if isHighlighted {
                let smallAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.75)
                ]
                let sub = NSAttributedString(string: label, attributes: smallAttrs)
                let subSize = sub.size()
                sub.draw(at: NSPoint(x: -subSize.width / 2,
                                     y: primarySize.height / 2 + 3))
            }
            ctx.restoreGState()
        } else {
            // Horizontal (dock) — draw label centred
            let drawLabel = isHighlighted ? "Drop here · \(label)" : label
            let finalAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(isHighlighted ? 0.95 : 0.65)
            ]
            let s = NSAttributedString(string: drawLabel, attributes: finalAttrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
    }
}
