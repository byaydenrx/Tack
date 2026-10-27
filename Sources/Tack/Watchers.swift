import AppKit

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tack.log")
    private static let queue = DispatchQueue(label: "tack.log")
    private static var writes = 0

    /// Past 1 MB the log is cut down to its newest 256 KB, so it never keeps growing.
    private static func trim() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(256_000)
        if let newline = tail.firstIndex(of: 10) { tail = tail[(newline + 1)...] }
        try? tail.write(to: url, options: .atomic)
    }

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            writes += 1
            if writes % 200 == 1 { trim() }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Notices when any app starts dragging files, by watching the system drag pasteboard.
@MainActor
final class DragWatcher {
    private(set) var active = false
    private(set) var hasSupportedImages = false
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?

    private var changeAtMouseDown = NSPasteboard(name: .drag).changeCount
    private var mouseDownInTack = false
    private var monitors: [Any] = []

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.changeAtMouseDown = NSPasteboard(name: .drag).changeCount
                self?.mouseDownInTack = false
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.changeAtMouseDown = NSPasteboard(name: .drag).changeCount
            self?.mouseDownInTack = true
            return event
        }) { monitors.append(m) }
    }

    /// Called on every tick. A drag is running while the button is held and the drag pasteboard changed since mouse down.
    func poll() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if active {
            if !pressed {
                active = false
                changeAtMouseDown = NSPasteboard(name: .drag).changeCount
                onEnd?()
            }
            return
        }
        let pasteboard = NSPasteboard(name: .drag)
        guard pressed, !mouseDownInTack, pasteboard.changeCount != changeAtMouseDown else { return }
        active = true
        hasSupportedImages = Self.containsSupportedImages(pasteboard)
        Log.write("drag started, supported images: \(hasSupportedImages), types: \(pasteboard.types?.map(\.rawValue).prefix(6) ?? [])")
        onStart?()
    }

    static func containsSupportedImages(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.contains(where: Supported.isImage)
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] {
            return promises.contains { $0.fileTypes.contains(where: Supported.isImageType) }
        }
        return false
    }
}

/// Finds Vorssaint's shelf panel on screen. Vorssaint has no API for this, so the shelf is
/// whichever Vorssaint window appears while a drag is running (or the one a drag starts in).
@MainActor
final class ShelfLocator {
    struct Window {
        let id: CGWindowID
        let frame: CGRect // window-server coordinates, origin top-left of the main display
        let layer: Int
    }

    private var shelfID: CGWindowID?
    private var baseline: Set<CGWindowID> = []

    var vorssaintRunning: Bool { pid != nil }

    private var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.vorssaint.utils").first?.processIdentifier
    }

    func visibleWindows() -> [Window] {
        guard let pid,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return Window(id: id, frame: rect, layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    private func plausible(_ w: Window) -> Bool {
        let screenWidth = NSScreen.screens.map(\.frame.width).max() ?? 4000
        return w.frame.width >= 100 && w.frame.width < min(1400, screenWidth * 0.9)
            && w.frame.height >= 40 && w.frame.height <= 1000
    }

    func dragStarted() {
        let windows = visibleWindows()
        baseline = Set(windows.map(\.id))
        // Dragging out of an already open shelf: the drag starts inside it.
        let mouse = Self.toWindowServer(NSEvent.mouseLocation)
        if let w = windows.first(where: { plausible($0) && $0.frame.contains(mouse) }) {
            learn(w, reason: "drag started inside it")
        }
    }

    /// The shelf's frame in Cocoa screen coordinates, if it's showing.
    func shelfFrame(dragging: Bool) -> NSRect? {
        let windows = visibleWindows().filter(plausible)
        if dragging, let fresh = windows.first(where: { !baseline.contains($0.id) }) {
            if fresh.id != shelfID { learn(fresh, reason: "appeared during drag") }
            baseline.insert(fresh.id)
            return Self.toCocoa(fresh.frame)
        }
        if let shelfID, let w = windows.first(where: { $0.id == shelfID }) {
            return Self.toCocoa(w.frame)
        }
        return nil
    }

    private func learn(_ w: Window, reason: String) {
        shelfID = w.id
        Log.write("shelf window \(w.id) (\(reason)): frame \(w.frame), layer \(w.layer)")
    }

    private static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toCocoa(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toWindowServer(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }
}

/// Image files currently sitting on Vorssaint's shelf, read from its saved shelf list.
enum VorssaintShelf {
    private static let domain = "com.vorssaint.utils" as CFString
    /// Vorssaint is free and open source; this is where to get it.
    static let download = URL(string: "https://github.com/vorssaint/vorssaint-utils/releases/latest")!

    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: domain as String) != nil }
    private static var loggedShape = false

    /// Vorssaint's own Shelf switch. Missing (an older Vorssaint) counts as on.
    static var shelfEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        var exists: DarwinBoolean = false
        let on = CFPreferencesGetAppBooleanValue("shelfEnabled" as CFString, domain, &exists)
        return on || !exists.boolValue
    }

    static func imageFiles() -> [URL] {
        CFPreferencesAppSynchronize(domain)
        guard let data = CFPreferencesCopyAppValue("shelfItems" as CFString, domain) as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: [URL] = []
        func walk(_ value: Any) {
            if let s = value as? String {
                if s.hasPrefix("file://"), let url = URL(string: s) { found.append(url) }
                else if s.hasPrefix("/") { found.append(URL(fileURLWithPath: s)) }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            } else if let dict = value as? [String: Any] {
                dict.values.forEach(walk)
            }
        }
        walk(json)
        if !loggedShape, let array = json as? [[String: Any]], let first = array.first {
            loggedShape = true
            Log.write("shelf item keys: \(first.keys.sorted())")
        }
        var seen = Set<String>()
        return found.filter { Supported.isImage($0) && FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }
}
