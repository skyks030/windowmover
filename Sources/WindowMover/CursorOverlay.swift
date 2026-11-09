import AppKit

/// A large, draggable on-screen arrow that marks where the synthetic drag will grab.
@MainActor
final class CursorOverlay {
    var onVisibilityChange: (() -> Void)?
    var directionMenu: (() -> NSMenu)?

    private var panel: OverlayPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The arrow tip in AppKit screen coordinates, or nil when hidden.
    var tipPoint: NSPoint? {
        guard let panel, panel.isVisible else { return nil }
        return NSPoint(x: panel.frame.minX + CursorView.tip.x, y: panel.frame.maxY - CursorView.tip.y)
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = WindowDragger.screen(containing: mouse) ?? NSScreen.main ?? NSScreen.screens[0]
        let center = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        panel.setFrameOrigin(NSPoint(x: center.x - CursorView.tip.x, y: center.y - panel.frame.height + CursorView.tip.y))
        panel.orderFrontRegardless()
        panel.makeKey()
        onVisibilityChange?()
    }

    func hide() {
        panel?.orderOut(nil)
        onVisibilityChange?()
    }

    private func makePanel() -> OverlayPanel {
        let view = CursorView(frame: NSRect(origin: .zero, size: CursorView.size))
        let panel = OverlayPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        view.onEscape = { [weak self] in self?.hide() }
        view.directionMenu = { [weak self] in self?.directionMenu?() }
        return panel
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CursorView: NSView {
    /// Scale relative to the regular macOS pointer.
    static let scale: CGFloat = 3.4
    /// Arrow tip inside the view (flipped coordinates).
    static let tip = NSPoint(x: 18, y: 18)
    static let size = NSSize(width: 300, height: 112)

    var onEscape: (() -> Void)?
    var directionMenu: (() -> NSMenu?)?

    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let s = Self.scale, tip = Self.tip

        // Soft ring marking the hotspot.
        let ring = NSBezierPath(ovalIn: NSRect(x: tip.x - 14, y: tip.y - 14, width: 28, height: 28))
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        ring.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        ring.lineWidth = 2
        ring.stroke()

        // Classic macOS arrow, in 1x pointer units with the tip at (0, 0), y down.
        let shape: [NSPoint] = [
            .init(x: 0, y: 0), .init(x: 0, y: 16.2), .init(x: 3.9, y: 12.6), .init(x: 6.4, y: 18.6),
            .init(x: 9.1, y: 17.5), .init(x: 6.6, y: 11.6), .init(x: 11.6, y: 11.6),
        ]
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tip.x + shape[0].x * s, y: tip.y + shape[0].y * s))
        for p in shape.dropFirst() { arrow.line(to: NSPoint(x: tip.x + p.x * s, y: tip.y + p.y * s)) }
        arrow.close()
        arrow.lineJoinStyle = .round

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.6 * s
        arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setFill()
        arrow.fill()

        // Hint pill.
        let text = "Auf die Titelleiste ziehen,\ndann im Menü „Let's go“ wählen"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.boundingRect(with: NSSize(width: 220, height: 100), options: [.usesLineFragmentOrigin]).size
        let pill = NSRect(x: tip.x + 14 * s, y: tip.y + 13 * s, width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 10)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        str.draw(with: pill.insetBy(dx: 10, dy: 5), options: [.usesLineFragmentOrigin])
    }

    // MARK: Moving

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let windowOrigin else { return }
        let now = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: windowOrigin.x + now.x - dragOrigin.x, y: windowOrigin.y + now.y - dragOrigin.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        windowOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = directionMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        guard let window else { return }
        var o = window.frame.origin
        switch event.keyCode {
        case 53: onEscape?(); return // Esc
        case 36, 76: // Return / Enter: show the direction menu at the tip
            if let menu = directionMenu?() { menu.popUp(positioning: nil, at: NSPoint(x: Self.tip.x + 6, y: Self.tip.y + 6), in: self) }
            return
        case 123: o.x -= step
        case 124: o.x += step
        case 125: o.y -= step
        case 126: o.y += step
        default: super.keyDown(with: event); return
        }
        window.setFrameOrigin(o)
    }
}
