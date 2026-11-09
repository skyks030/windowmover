import AppKit
import SwiftUI

/// Checks GitHub Releases for a newer version and installs it in place of the running app.
/// At launch (and every few hours) newer versions are installed automatically; the menu offers a manual check.
@MainActor
final class Updater {
    static let shared = Updater()

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Returns true while the user is in the middle of something; automatic installs wait for the next check.
    var isBusy: () -> Bool = { false }

    private var repo: String {
        Bundle.main.object(forInfoDictionaryKey: "WindowMoverGitHubRepo") as? String ?? "skyks030/windowmover"
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    private var checking = false
    private var installing = false
    private var timer: Timer?
    private var progressWindow: NSWindow?

    func startAutomaticChecks() {
        check(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check(userInitiated: false) }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        guard !checking, !installing else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("WindowMover/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    if userInitiated { info("Es wurde noch keine Version veröffentlicht.") }
                    return
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = Self.normalize(release.tag_name)
                guard Self.compare(latest, Self.currentVersion) == .orderedDescending else {
                    if userInitiated { info("WindowMover ist aktuell (Version \(Self.currentVersion)).") }
                    return
                }
                guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else {
                    if userInitiated { info("Version \(latest) enthält kein installierbares Paket.") }
                    return
                }
                if !userInitiated && isBusy() { return }
                install(asset: asset, version: latest, showProgress: userInitiated)
            } catch {
                if userInitiated { info("Update-Prüfung fehlgeschlagen: \(error.localizedDescription)") }
            }
        }
    }

    private func info(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Software-Update"
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Install

    private func install(asset: Release.Asset, version: String, showProgress: Bool) {
        installing = true
        let progress = UpdateProgress()
        if showProgress {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "WindowMover \(version) wird installiert"
            window.contentView = NSHostingView(rootView: UpdateProgressView(progress: progress))
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.center()
            window.makeKeyAndOrderFront(nil)
            progressWindow = window
        }

        Task {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("windowmover-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

                progress.status = "Lade Version \(version) …"
                let zip = work.appendingPathComponent(asset.name)
                try await Self.download(asset.browser_download_url, to: zip, expectedSize: asset.size, progress: progress)

                progress.status = "Entpacke …"
                progress.fraction = nil
                let unpacked = work.appendingPathComponent("unpacked")
                try await Self.runDetached("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

                guard let newApp = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                    throw Self.error(1, "Im Paket wurde keine App gefunden.")
                }
                guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw Self.error(2, "Das Paket enthält eine fremde App.")
                }
                try? await Self.runDetached("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

                progress.status = "Installiere und starte neu …"
                try replaceAndRelaunch(with: newApp, allowPasswordPrompt: showProgress)
            } catch {
                installing = false
                progressWindow?.close()
                progressWindow = nil
                if showProgress { info("Update fehlgeschlagen: \(error.localizedDescription)") }
            }
        }
    }

    private nonisolated static func download(_ url: URL, to dest: URL, expectedSize: Int, progress: UpdateProgress) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw error(3, "Download fehlgeschlagen.") }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        let total = max(expectedSize, Int(response.expectedContentLength), 1)
        var buffer = Data()
        buffer.reserveCapacity(1 << 18)
        var written = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 18 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                let f = Double(written) / Double(total)
                await MainActor.run { progress.fraction = f }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    /// Hands off to a small shell script that swaps the bundle once this process has exited, then launches the new one.
    private func replaceAndRelaunch(with newApp: URL, allowPasswordPrompt: Bool) throws {
        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then
          rm -rf "$DEST.old"
        else
          rm -rf "$DEST"; mv "$DEST.old" "$DEST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        let parent = (dest as NSString).deletingLastPathComponent
        let writable = FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: dest)

        let task = Process()
        task.environment = ["DEST": dest, "NEW": newApp.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if writable {
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", script]
        } else {
            guard allowPasswordPrompt else {
                throw Self.error(5, "Keine Schreibrechte – Update bitte manuell über das Menü starten.")
            }
            let scriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("windowmover-update.sh")
            try ("DEST=\(Self.shellQuote(dest))\nNEW=\(Self.shellQuote(newApp.path))\n" + script)
                .write(to: scriptFile, atomically: true, encoding: .utf8)
            let apple = "do shell script \"/bin/sh \(scriptFile.path) > /dev/null 2>&1 &\" with administrator privileges"
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", apple]
        }
        try task.run()
        if !writable {
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw Self.error(4, "Administrator-Berechtigung wurde nicht erteilt.") }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private nonisolated static func runDetached(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw error(Int(p.terminationStatus), "\(tool) ist fehlgeschlagen (\(p.terminationStatus)).") }
        }.value
    }

    private nonisolated static func error(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "WindowMover.Update", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Versions

    nonisolated static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

@MainActor
final class UpdateProgress: ObservableObject {
    @Published var status = "Bereite vor …"
    @Published var fraction: Double? = 0
}

private struct UpdateProgressView: View {
    @ObservedObject var progress: UpdateProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.status)
            if let f = progress.fraction {
                ProgressView(value: f)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
