import AppKit
import ServiceManagement
import SwiftUI

// Test mode: Tack --process convert:jpg|compress:medium|upscale:2 <files…>
if let i = CommandLine.arguments.firstIndex(of: "--process"), CommandLine.arguments.count > i + 2 {
    guard let operation = Operation(spec: CommandLine.arguments[i + 1]) else {
        print("unknown operation \(CommandLine.arguments[i + 1])")
        exit(2)
    }
    for path in CommandLine.arguments[(i + 2)...] {
        do {
            let r = try ImageOps.process(operation, file: URL(fileURLWithPath: path))
            print("\(path) -> \(r.output?.path ?? "none") \(r.inBytes) -> \(r.outBytes) \(r.note ?? "")")
        } catch {
            print("\(path) failed: \(error.localizedDescription)")
        }
    }
    exit(0)
}

/// Test mode: Tack --snapshot <dir> renders the strip's states to PNGs.
@MainActor
func renderSnapshots(to dir: URL) {
    PanelBackground.flat = true
    let model = StripModel()
    func save(_ name: String) {
        let view = StripView(model: model).frame(width: 300, height: model.height)
            .background(Color(white: 0.12))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { print("render failed: \(name)"); return }
        let url = dir.appendingPathComponent(name + ".png")
        try? ImageOps.write(cg, to: url, format: .png, quality: 1)
        print(url.path)
    }
    save("1-idle")
    model.expanded = .convert
    model.targeted = "opt.convert.jpg"
    save("2-convert-hover")
    model.expanded = .upscale
    model.targeted = "box.upscale"
    save("3-upscale-hover")
    model.expanded = nil
    model.busyText = "Compressing 3 images…"
    save("4-busy")
    model.busyText = nil
    model.summary = "42% smaller · 1.2 MB → 690 KB"
    model.results = [URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns")]
    save("5-results")
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated { renderSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}

/// Shows the strip under Vorssaint's shelf while image files are being dragged, or while the shelf holds images.
@MainActor
final class Coordinator {
    let model = StripModel()
    private let drag = DragWatcher()
    private let shelf = ShelfLocator()
    private lazy var panel = StripPanel(model: model)
    private var timer: Timer?
    private var shown = false
    private var lastShelfFrame: NSRect?
    private var lastShelfRead = Date.distantPast
    private var tickCount = 0
    private var previewing = false

    func start() {
        drag.onStart = { [weak self] in
            guard let self else { return }
            shelf.dragStarted()
            if drag.hasSupportedImages { model.clearResults() }
        }
        drag.onEnd = { [weak self] in
            self?.model.expand(nil)
            self?.model.targeted = nil
        }
        model.onLayoutChange = { [weak self] in
            guard let self, shown, let frame = lastShelfFrame else { return }
            place(below: frame)
        }
        drag.start()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.write("Tack started; Vorssaint running: \(shelf.vorssaintRunning), shelf on: \(VorssaintShelf.shelfEnabled), cwebp: \(Tools.cwebp ?? "missing"), pngquant: \(Tools.pngquant ?? "missing")")
    }

    /// Shows the strip under a stand-in shelf in the middle of the screen, for checking the look (Tack --preview).
    func preview() {
        previewing = true
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let fake = NSRect(x: screen.midX - 150, y: screen.midY, width: 300, height: 255)
        lastShelfFrame = fake
        model.expand(.convert)
        model.targeted = "opt.convert.jpg"
        show(below: fake)
    }

    private func tick() {
        if previewing { return }
        tickCount += 1
        drag.poll()
        // Window lookups are cheap, but there's no need to do them 20 times a second while idle.
        guard drag.active || shown || model.isBusy || tickCount % 4 == 0 else { return }

        let frame = shelf.shelfFrame(dragging: drag.active)
        if let frame { lastShelfFrame = frame }

        if drag.active {
            if drag.hasSupportedImages, let frame {
                show(below: frame)
            } else if !drag.hasSupportedImages && !model.hasResults {
                hide()
            }
            // Shelf hid mid-drag (e.g. dragging out of it): keep the strip where it was.
            return
        }

        if model.isBusy { return }

        if let frame {
            if Date().timeIntervalSince(lastShelfRead) > 0.5 {
                model.shelfFiles = VorssaintShelf.imageFiles()
                lastShelfRead = Date()
            }
            if !model.shelfFiles.isEmpty || model.hasResults {
                show(below: frame)
            } else {
                hide()
            }
        } else if let shownAt = model.resultsShownAt, Date().timeIntervalSince(shownAt) < 10, shown {
            // Leave results up for a bit so they can be dragged back onto the shelf.
        } else {
            hide()
            model.clearResults()
        }
    }

    private func show(below shelfFrame: NSRect) {
        place(below: shelfFrame)
        guard !shown else { return }
        shown = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func place(below shelfFrame: NSRect) {
        let width = min(max(shelfFrame.width, 300), 460)
        let height = model.height
        let screen = NSScreen.screens.first { $0.frame.intersects(shelfFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: shelfFrame.midX - width / 2, y: shelfFrame.minY - 8 - height)
        if origin.y < visible.minY { origin.y = shelfFrame.maxY + 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height)).integral
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        model.expand(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }
}

/// No menu bar icon: Tack runs invisibly. Opening it again from Applications shows a small dialog to quit or change login.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = Coordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
        // It has no visible UI, so it should just always be there; turn on Open at Login the first time.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didSetUpLogin") {
            defaults.set(true, forKey: "didSetUpLogin")
            setOpenAtLogin(true)
        }
        if CommandLine.arguments.contains("--preview") { coordinator.preview() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    private func showControls() {
        let loginOn = SMAppService.mainApp.status == .enabled
        let vorssaint = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.vorssaint.utils").isEmpty
        let alert = NSAlert()
        alert.messageText = "Tack is running"
        let status = !vorssaint ? "Vorssaint isn't running, so the boxes won't show until it is."
            : !VorssaintShelf.shelfEnabled ? "Vorssaint's Shelf is turned off. Turn it on in Vorssaint's settings to see the boxes."
            : "Its boxes show up under Vorssaint's shelf when you drag images."
        alert.informativeText = status
            + "\n\nOpen at Login is \(loginOn ? "on" : "off")."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: loginOn ? "Turn Off Open at Login" : "Turn On Open at Login")
        alert.addButton(withTitle: "Quit Tack")
        NSApp.activate()
        switch alert.runModal() {
        case .alertSecondButtonReturn: setOpenAtLogin(!loginOn)
        case .alertThirdButtonReturn: NSApp.terminate(nil)
        default: break
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("open at login: \(on)")
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
