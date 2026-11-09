import AppKit
import ServiceManagement

@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = CursorOverlay()
    private var dragging = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        overlay.onVisibilityChange = { [weak self] in self?.updateIcon() }
        overlay.directionMenu = { [weak self] in self?.makeDirectionMenu() ?? NSMenu() }

        Updater.shared.isBusy = { [weak self] in
            guard let self else { return false }
            return self.overlay.isVisible || self.dragging
        }
        Updater.shared.startAutomaticChecks()

        if !WindowDragger.hasPermission {
            WindowDragger.requestPermission()
        }
    }

    private func updateIcon() {
        let name = overlay.isVisible ? "cursorarrow.rays" : "cursorarrow"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "WindowMover")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "WindowMover"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem()
        header.view = MenuHeaderView(version: Updater.currentVersion)
        menu.addItem(header)
        menu.addItem(.separator())

        if overlay.isVisible {
            menu.addItem(item("Cursor ausblenden", symbol: "xmark.circle", action: #selector(toggleCursor)))
        } else {
            menu.addItem(item("Move a Window", symbol: "macwindow.on.rectangle", action: #selector(toggleCursor)))
        }

        let go = item("Let's go", symbol: "arrow.up.and.down.and.arrow.left.and.right", action: nil)
        go.submenu = makeDirectionMenu()
        go.isEnabled = overlay.isVisible && !dragging
        if !overlay.isVisible { go.toolTip = "Zuerst „Move a Window“ wählen und den Cursor auf eine Titelleiste ziehen." }
        menu.addItem(go)

        menu.addItem(.separator())

        if !WindowDragger.hasPermission {
            menu.addItem(item("Bedienungshilfen-Zugriff erteilen …", symbol: "exclamationmark.triangle", action: #selector(grantPermission)))
        }
        menu.addItem(item("Nach Updates suchen …", symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates)))
        let login = item("Beim Anmelden starten", symbol: nil, action: #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = item("WindowMover beenden", symbol: nil, action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func makeDirectionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tip = overlay.tipPoint
        for direction in Direction.allCases {
            let entry = item(direction.title, symbol: direction.symbol, action: #selector(go(_:)))
            entry.representedObject = direction.rawValue
            if let tip, WindowDragger.plan(from: tip, direction) == nil {
                entry.isEnabled = false
                entry.toolTip = "In dieser Richtung gibt es keinen weiteren Bildschirm."
            }
            menu.addItem(entry)
        }
        return menu
    }

    private func item(_ title: String, symbol: String?, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    // MARK: Actions

    @objc private func toggleCursor() {
        if overlay.isVisible { overlay.hide() } else { overlay.show() }
    }

    @objc private func go(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let direction = Direction(rawValue: raw),
              let tip = overlay.tipPoint else { return }
        guard WindowDragger.hasPermission else {
            grantPermission()
            return
        }
        guard let path = WindowDragger.plan(from: tip, direction) else {
            alert("Kein Bildschirm \(direction.phrase)", "Neben dem Bildschirm, auf dem der Cursor steht, wurde in dieser Richtung kein weiterer Bildschirm gefunden.")
            return
        }
        overlay.hide()
        dragging = true
        // Give the status menu a moment to close before we take over the mouse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            WindowDragger.perform(path: path) { [weak self] in
                self?.dragging = false
            }
        }
    }

    @objc private func grantPermission() {
        WindowDragger.requestPermission()
        WindowDragger.openAccessibilitySettings()
    }

    @objc private func checkForUpdates() {
        Updater.shared.check(userInitiated: true)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Autostart konnte nicht geändert werden", error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// The styled top row of the status menu: icon, app name and a version badge.
final class MenuHeaderView: NSView {
    init(version: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 48))

        let icon = NSImageView(frame: NSRect(x: 14, y: 8, width: 32, height: 32))
        icon.image = NSApp.applicationIconImage
        addSubview(icon)

        let name = NSTextField(labelWithString: "WindowMover")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.frame = NSRect(x: 54, y: 24, width: 180, height: 17)
        addSubview(name)

        let subtitle = NSTextField(labelWithString: "Fenster zwischen Bildschirmen ziehen")
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 54, y: 8, width: 190, height: 14)
        addSubview(subtitle)

        let badge = NSTextField(labelWithString: "v\(version)")
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .controlAccentColor
        badge.alignment = .center
        badge.sizeToFit()
        let w = badge.frame.width + 12
        let pill = NSView(frame: NSRect(x: 250 - 12 - w, y: 25, width: w, height: 16))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        badge.frame = NSRect(x: 0, y: 1, width: w, height: 14)
        pill.addSubview(badge)
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError() }
}
