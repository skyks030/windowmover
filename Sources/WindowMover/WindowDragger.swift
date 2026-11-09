import AppKit
import ApplicationServices

enum Direction: String, CaseIterable {
    case right, left, up, down

    var title: String {
        switch self {
        case .right: "Nach rechts"
        case .left: "Nach links"
        case .up: "Nach oben"
        case .down: "Nach unten"
        }
    }

    var phrase: String {
        switch self {
        case .right: "rechts"
        case .left: "links"
        case .up: "oberhalb"
        case .down: "unterhalb"
        }
    }

    var symbol: String {
        switch self {
        case .right: "arrow.right"
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }
}

/// Plans and performs a synthetic mouse drag (press, drag, release) from a point onto the neighbouring screen.
/// All planning happens in AppKit coordinates (origin bottom-left of the primary screen, y up).
@MainActor
enum WindowDragger {
    // MARK: Permission

    static var hasPermission: Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Geometry

    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Minimum shared edge length for the pointer to be able to cross between two screens.
    private static let minOverlap: CGFloat = 40

    static func neighbor(of screen: NSScreen, _ direction: Direction) -> NSScreen? {
        let f = screen.frame
        func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat { min(a1, b1) - max(a0, b0) }

        let candidates: [(NSScreen, CGFloat)] = NSScreen.screens.compactMap { other in
            guard other != screen else { return nil }
            let g = other.frame
            switch direction {
            case .right:
                guard g.minX >= f.maxX - 2, overlap(f.minY, f.maxY, g.minY, g.maxY) >= minOverlap else { return nil }
                return (other, g.minX - f.maxX)
            case .left:
                guard g.maxX <= f.minX + 2, overlap(f.minY, f.maxY, g.minY, g.maxY) >= minOverlap else { return nil }
                return (other, f.minX - g.maxX)
            case .up:
                guard g.minY >= f.maxY - 2, overlap(f.minX, f.maxX, g.minX, g.maxX) >= minOverlap else { return nil }
                return (other, g.minY - f.maxY)
            case .down:
                guard g.maxY <= f.minY + 2, overlap(f.minX, f.maxX, g.minX, g.maxX) >= minOverlap else { return nil }
                return (other, f.minY - g.maxY)
            }
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// Waypoints for the drag: start → (slide along the edge into the shared band) → cross over → final spot.
    /// The grabbed point ends up at the same relative position on the target screen.
    static func plan(from tip: NSPoint, _ direction: Direction) -> [NSPoint]? {
        guard let current = screen(containing: tip) ?? NSScreen.main,
              let target = neighbor(of: current, direction) else { return nil }
        let c = current.frame, t = target.frame, tv = target.visibleFrame
        let margin: CGFloat = 30
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi) }

        // Keep distance from the top edge (title bars live there), keep horizontal position proportional.
        let fromTop = c.maxY - tip.y
        let endY = clamp(t.maxY - fromTop, tv.minY + margin, tv.maxY - 6)
        let endX = clamp(t.minX + (tip.x - c.minX) / c.width * t.width, t.minX + margin, t.maxX - margin)
        let end = NSPoint(x: endX, y: endY)

        var points = [tip]
        switch direction {
        case .left, .right:
            let bandY = clamp(tip.y, max(c.minY, t.minY) + margin, min(c.maxY, t.maxY) - margin)
            points.append(NSPoint(x: tip.x, y: bandY))
            points.append(NSPoint(x: endX, y: bandY))
        case .up, .down:
            let bandX = clamp(tip.x, max(c.minX, t.minX) + margin, min(c.maxX, t.maxX) - margin)
            points.append(NSPoint(x: bandX, y: tip.y))
            points.append(NSPoint(x: bandX, y: endY))
        }
        points.append(end)

        var result: [NSPoint] = []
        for p in points where result.last.map({ hypot($0.x - p.x, $0.y - p.y) > 0.5 }) ?? true {
            result.append(p)
        }
        return result
    }

    // MARK: Drag

    /// Presses the left button at the first point, drags along the path, releases, then puts the pointer back
    /// where the drag started (so it stays on the screen the remote-desktop user can see).
    static func perform(path: [NSPoint], completion: @escaping @MainActor () -> Void) {
        guard let primary = NSScreen.screens.first, path.count >= 2 else { completion(); return }
        let height = primary.frame.maxY
        let points = path.map { CGPoint(x: $0.x, y: height - $0.y) } // to global display coordinates (y down)

        DispatchQueue.global(qos: .userInteractive).async {
            let source = CGEventSource(stateID: .hidSystemState)
            func post(_ type: CGEventType, _ p: CGPoint, from prev: CGPoint? = nil) {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
                e.setIntegerValueField(.mouseEventClickState, value: 1)
                if let prev {
                    e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - prev.x).rounded()))
                    e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - prev.y).rounded()))
                }
                e.post(tap: .cghidEventTap)
            }

            let start = points[0]
            CGWarpMouseCursorPosition(start)
            post(.mouseMoved, start)
            usleep(120_000)
            post(.leftMouseDown, start)
            usleep(200_000)

            var last = start
            for target in points.dropFirst() {
                let from = last
                let distance = hypot(target.x - from.x, target.y - from.y)
                let steps = max(6, Int(distance / 20))
                for i in 1...steps {
                    let f = CGFloat(i) / CGFloat(steps)
                    let p = CGPoint(x: from.x + (target.x - from.x) * f, y: from.y + (target.y - from.y) * f)
                    post(.leftMouseDragged, p, from: last)
                    last = p
                    usleep(7_000)
                }
                usleep(40_000)
            }

            usleep(200_000)
            post(.leftMouseUp, last)
            usleep(150_000)
            CGWarpMouseCursorPosition(start)
            post(.mouseMoved, start)

            DispatchQueue.main.async { completion() }
        }
    }
}
