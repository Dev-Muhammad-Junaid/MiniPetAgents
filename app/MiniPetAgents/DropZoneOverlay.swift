import AppKit
import QuartzCore

/// Translucent overlay shown while the user drags a pet, highlighting the
/// "Dock" zone at the bottom of the screen. Releasing the pet inside the
/// zone switches the pet's placement to `.dock`; releasing anywhere else
/// switches it to `.freeRoam`.
///
/// Only the dock zone has a visible panel — free-roam is implicit (the rest
/// of the screen). This is the intentionally-simple two-zone model.
final class DropZoneOverlay {
    static let shared = DropZoneOverlay()

    private var window: NSWindow?
    private var zoneView: ZoneView?
    /// Last-known zone in screen coords, used by `zoneAt(_:)`.
    private(set) var dockZoneRect: NSRect = .zero

    /// Show the overlay anchored to the given screen, sized to the dock
    /// icon strip (`dockX`/`dockWidth`/`dockTopY`).
    func show(on screen: NSScreen, dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        let zoneHeight: CGFloat = 96
        // The "drop into dock" target sits where dock icons are. Pad sideways
        // so dragging vaguely toward the dock still counts.
        let pad: CGFloat = 24
        let rect = NSRect(
            x: dockX - pad,
            y: max(screen.visibleFrame.minY - zoneHeight * 0.4, screen.frame.minY),
            width: dockWidth + pad * 2,
            height: zoneHeight
        )
        dockZoneRect = rect

        if window == nil {
            let w = NSWindow(contentRect: rect,
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            // Above pets, below menu bar. Pet windows live at statusBar+i.
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 100)
            let v = ZoneView(frame: NSRect(origin: .zero, size: rect.size))
            w.contentView = v
            zoneView = v
            window = w
        } else {
            window?.setFrame(rect, display: false)
            zoneView?.frame = NSRect(origin: .zero, size: rect.size)
        }
        zoneView?.isHighlighted = false
        zoneView?.needsDisplay = true
        window?.alphaValue = 0
        window?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window?.animator().alphaValue = 1
        }
    }

    /// Update which zone is "active" given the dragged pet's center in screen
    /// coords. Returns the resolved placement so the caller can preview it.
    @discardableResult
    func update(petCenter: NSPoint) -> PlacementMode {
        let inDock = dockZoneRect.contains(petCenter)
        zoneView?.isHighlighted = inDock
        zoneView?.needsDisplay = true
        return inDock ? .dock : .freeRoam
    }

    func hide() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        })
    }

    /// Returns the placement that would result from a drop at `point`
    /// without changing overlay state.
    func zoneAt(_ point: NSPoint) -> PlacementMode {
        dockZoneRect.contains(point) ? .dock : .freeRoam
    }
}

private final class ZoneView: NSView {
    var isHighlighted = false {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 8)
        let radius: CGFloat = 18
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        // Fill: subtle when idle, brighter when the pet is over the zone.
        let fillAlpha: CGFloat = isHighlighted ? 0.32 : 0.12
        NSColor(calibratedRed: 0.30, green: 0.70, blue: 1.0, alpha: fillAlpha).setFill()
        path.fill()

        // Border: dashed-ish but rendered solid for cleanliness.
        let borderAlpha: CGFloat = isHighlighted ? 0.85 : 0.45
        NSColor(calibratedRed: 0.30, green: 0.70, blue: 1.0, alpha: borderAlpha).setStroke()
        path.lineWidth = isHighlighted ? 2.5 : 1.5
        path.stroke()

        // Label.
        let title = isHighlighted ? "Drop here · Dock" : "Dock"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(isHighlighted ? 0.95 : 0.7)
        ]
        let s = NSAttributedString(string: title, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }
}
