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

    /// The closest other screen that lies in the given direction (by centre), so offset or diagonal
    /// arrangements work too. Gaps along the main axis and misalignment across it both count as distance.
    static func neighbor(of screen: NSScreen, _ direction: Direction) -> NSScreen? {
        let f = screen.frame
        func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat { max(0, max(a0, b0) - min(a1, b1)) }

        let candidates: [(NSScreen, CGFloat)] = NSScreen.screens.compactMap { other in
            guard other != screen else { return nil }
            let g = other.frame
            let dx = g.midX - f.midX, dy = g.midY - f.midY
            let gapX = gap(f.minX, f.maxX, g.minX, g.maxX), gapY = gap(f.minY, f.maxY, g.minY, g.maxY)
            switch direction {
            case .right: return dx > 1 ? (other, gapX + 2 * gapY + abs(dy) * 0.01) : nil
            case .left:  return dx < -1 ? (other, gapX + 2 * gapY + abs(dy) * 0.01) : nil
            case .up:    return dy > 1 ? (other, gapY + 2 * gapX + abs(dx) * 0.01) : nil
            case .down:  return dy < -1 ? (other, gapY + 2 * gapX + abs(dx) * 0.01) : nil
            }
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// Waypoints for the drag: start → (slide into the shared edge band) → cross over → final spot.
    /// The grabbed point ends up at the same relative position on the target screen.
    /// Without a shared edge the pointer simply jumps across (points off-screen are skipped while dragging).
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
            let lo = max(c.minY, t.minY) + margin, hi = min(c.maxY, t.maxY) - margin
            if lo <= hi {
                let bandY = clamp(tip.y, lo, hi)
                points.append(NSPoint(x: tip.x, y: bandY))
                points.append(NSPoint(x: endX, y: bandY))
            }
        case .up, .down:
            let lo = max(c.minX, t.minX) + margin, hi = min(c.maxX, t.maxX) - margin
            if lo <= hi {
                let bandX = clamp(tip.x, lo, hi)
                points.append(NSPoint(x: bandX, y: tip.y))
                points.append(NSPoint(x: bandX, y: endY))
            }
        }
        points.append(end)

        var result: [NSPoint] = []
        for p in points where result.last.map({ hypot($0.x - p.x, $0.y - p.y) > 0.5 }) ?? true {
            result.append(p)
        }
        return result
    }

    /// Human-readable list of the screens macOS reports, for the menu and error messages.
    static var screenSummary: String {
        NSScreen.screens.enumerated().map { i, s in
            "\(i + 1). \(s.localizedName) – \(Int(s.frame.width))×\(Int(s.frame.height)) bei (\(Int(s.frame.minX)), \(Int(s.frame.minY)))"
        }.joined(separator: "\n")
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
                    var count: UInt32 = 0
                    if i < steps, CGGetDisplaysWithPoint(p, 0, nil, &count) == .success, count == 0 { continue }
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
