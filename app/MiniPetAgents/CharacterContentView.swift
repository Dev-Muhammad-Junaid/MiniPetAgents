import AppKit

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts the sprite layer and handles click vs drag.
///
/// Drag uses no modifier — any press-and-move past `dragThreshold` becomes a
/// drag. Drag math runs in **screen coordinates** so the cursor stays glued
/// to the pet even as the window moves: window origin = anchor + (cursor −
/// initialCursor). Using `event.locationInWindow` for this is wrong — once
/// the window starts moving the locationInWindow drifts and the pet feels
/// "sticky".
class CharacterContentView: NSView {
    weak var character: WalkerCharacter?

    private var dragInitialCursorScreen: NSPoint?
    private var dragInitialWindowOrigin: NSPoint?
    private var didDrag = false
    /// Pixels of cursor movement before a press becomes a drag.
    private static let dragThreshold: CGFloat = 3.0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let opts: NSTrackingArea.Options = [
            .activeAlways,
            .inVisibleRect,
            .mouseEnteredAndExited,
            .cursorUpdate,
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil))
    }

    /// Kept for source compatibility with older controller code.
    func refreshRepositionCursor() { applyCursor() }

    private func applyCursor() {
        if character?.isShiftDraggingWindow == true {
            NSCursor.closedHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func mouseEntered(with event: NSEvent) { applyCursor() }
    override func mouseExited(with event: NSEvent)  { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { applyCursor() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // Pixel-alpha hit test against the on-screen sprite for accurate clicks
        // through transparent regions.
        let screenPoint = window?.convertPoint(toScreen: convert(localPoint, to: nil)) ?? .zero
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - screenPoint.y

        let captureRect = CGRect(x: screenPoint.x - 0.5, y: flippedY - 0.5, width: 1, height: 1)
        guard let windowID = window?.windowNumber, windowID > 0 else { return nil }

        if let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixel: [UInt8] = [0, 0, 0, 0]
            if let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if pixel[3] > 30 { return self }
                return nil
            }
        }

        // Fallback: accept click within center 60% of view.
        let insetX = bounds.width * 0.2
        let insetY = bounds.height * 0.15
        let hitRect = bounds.insetBy(dx: insetX, dy: insetY)
        return hitRect.contains(localPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragInitialCursorScreen = NSEvent.mouseLocation
        dragInitialWindowOrigin = window?.frame.origin
        didDrag = false
        character?.isShiftDraggingWindow = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startCursor = dragInitialCursorScreen,
              let startOrigin = dragInitialWindowOrigin,
              let win = window else { return }

        let cur = NSEvent.mouseLocation
        let dx = cur.x - startCursor.x
        let dy = cur.y - startCursor.y

        if !didDrag {
            if hypot(dx, dy) < Self.dragThreshold { return }
            // First frame past the threshold: enter drag mode.
            didDrag = true
            character?.isShiftDraggingWindow = true
            NSCursor.closedHand.set()
            character?.beginDragSession()
        }

        // Window origin = original origin + cumulative cursor delta. No drift.
        win.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        character?.updateDragSession()
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = didDrag
        dragInitialCursorScreen = nil
        dragInitialWindowOrigin = nil
        didDrag = false
        character?.isShiftDraggingWindow = false

        if wasDrag {
            character?.endDragSession()
        } else {
            character?.handleClick()
        }
        applyCursor()
    }
}
