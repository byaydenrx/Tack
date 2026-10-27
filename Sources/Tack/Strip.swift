import AppKit
import SwiftUI

enum StripAction: String, CaseIterable, Identifiable {
    case convert, compress, upscale
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .upscale: "arrow.up.left.and.arrow.down.right"
        }
    }
}

struct StripOption: Identifiable {
    let id: String
    let label: String
    let operation: Operation
}

@MainActor
final class StripModel: ObservableObject {
    @Published var expanded: StripAction?
    @Published var targeted: String?
    @Published var busyText: String?
    @Published var results: [URL] = []
    @Published var summary: String?
    @Published var shelfFiles: [URL] = []
    var zones: [String: CGRect] = [:]
    var resultsShownAt: Date?
    var onLayoutChange: (() -> Void)?

    var hasResults: Bool { summary != nil }
    var isBusy: Bool { busyText != nil }

    static let rowHeight: CGFloat = 64
    static let optionsHeight: CGFloat = 40

    var height: CGFloat {
        let content = expanded != nil && !isBusy && !hasResults ? Self.rowHeight + Self.optionsHeight + 6 : Self.rowHeight
        return content + 20
    }

    func options(for action: StripAction) -> [StripOption] {
        switch action {
        case .convert:
            OutFormat.allCases
                .filter { $0 != .webp || Tools.cwebp != nil }
                .map { StripOption(id: "opt.convert.\($0.rawValue)", label: $0.label, operation: .convert($0)) }
        case .compress:
            CompressLevel.allCases.map { StripOption(id: "opt.compress.\($0.rawValue)", label: $0.label, operation: .compress($0)) }
        case .upscale:
            [1.5, 2, 3, 4].map { StripOption(id: "opt.upscale.\($0)", label: "\(Int($0 * 100))%", operation: .upscale($0)) }
        }
    }

    func defaultOperation(for action: StripAction) -> Operation {
        switch action {
        case .convert: .convert(.jpg)
        case .compress: .compress(.medium)
        case .upscale: .upscale(2)
        }
    }

    func expand(_ action: StripAction?) {
        guard expanded != action else { return }
        expanded = action
        onLayoutChange?()
    }

    // MARK: Drop targeting (points are in the strip's top-left coordinate space)

    func hover(at point: CGPoint) {
        if let option = zones.first(where: { $0.key.hasPrefix("opt.") && $0.value.contains(point) }) {
            targeted = option.key
        } else if let box = zones.first(where: { $0.key.hasPrefix("box.") && $0.value.contains(point) }) {
            targeted = box.key
            expand(StripAction(rawValue: String(box.key.dropFirst(4))))
        } else {
            targeted = nil
        }
    }

    func operation(at point: CGPoint) -> Operation? {
        for action in StripAction.allCases {
            if let option = options(for: action).first(where: { zones[$0.id]?.contains(point) == true }) {
                return option.operation
            }
            if zones["box.\(action.rawValue)"]?.contains(point) == true {
                return defaultOperation(for: action)
            }
        }
        return nil
    }

    // MARK: Running

    func clearResults() {
        guard hasResults else { return }
        results = []
        summary = nil
        resultsShownAt = nil
        onLayoutChange?()
    }

    func run(_ operation: Operation, on files: [URL]) {
        let images = files.filter(Supported.isImage)
        expanded = nil
        targeted = nil
        guard !images.isEmpty else {
            showResults([], summary: "No PNG, JPG or WebP images there")
            return
        }
        busyText = "\(operation.progressVerb) \(images.count == 1 ? images[0].lastPathComponent : "\(images.count) images")…"
        onLayoutChange?()
        Task.detached(priority: .userInitiated) {
            var outputs: [URL] = []
            var inBytes = 0, outBytes = 0
            var notes: [String] = []
            for file in images {
                do {
                    let r = try ImageOps.process(operation, file: file)
                    if let out = r.output {
                        outputs.append(out)
                        inBytes += r.inBytes
                        outBytes += r.outBytes
                    }
                    if let note = r.note { notes.append(images.count == 1 ? note : "\(file.lastPathComponent) \(note)") }
                    Log.write("\(operation) \(file.path) -> \(r.output?.path ?? "none") \(r.note ?? "")")
                } catch {
                    notes.append(error.localizedDescription)
                    Log.write("\(operation) \(file.path) failed: \(error.localizedDescription)")
                }
            }
            let summary = Self.summarize(operation, count: outputs.count, inBytes: inBytes, outBytes: outBytes, notes: notes)
            let finished = outputs
            await MainActor.run {
                self.busyText = nil
                self.showResults(finished, summary: summary)
            }
        }
    }

    private func showResults(_ urls: [URL], summary: String) {
        results = urls
        self.summary = summary
        resultsShownAt = Date()
        onLayoutChange?()
    }

    nonisolated static func summarize(_ op: Operation, count: Int, inBytes: Int, outBytes: Int, notes: [String]) -> String {
        guard count > 0 else { return notes.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Nothing to do" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        let sizes = "\(f.string(fromByteCount: Int64(inBytes))) → \(f.string(fromByteCount: Int64(outBytes)))"
        let what: String
        switch op {
        case .convert(let format): what = "\(count == 1 ? "" : "\(count) ")→ \(format.label)"
        case .compress:
            let saved = inBytes > 0 ? Int((1 - Double(outBytes) / Double(inBytes)) * 100) : 0
            what = "\(saved)% smaller"
        case .upscale(let s): what = "\(Int(s * 100))%"
        }
        let skipped = notes.isEmpty ? "" : " · \(notes.count) skipped"
        return "\(what) · \(sizes)\(skipped)"
    }
}

// MARK: - Views

private struct ZoneKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func zone(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ZoneKey.self, value: [id: g.frame(in: .named("strip"))])
        })
    }
}

struct StripView: View {
    @ObservedObject var model: StripModel

    var body: some View {
        VStack(spacing: 6) {
            if let busy = model.busyText {
                busyRow(busy)
            } else if model.hasResults {
                resultsRow
            } else {
                HStack(spacing: 8) {
                    ForEach(StripAction.allCases) { box($0) }
                }
                .frame(height: StripModel.rowHeight)
                if let action = model.expanded {
                    optionsRow(action)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanelBackground())
        .coordinateSpace(name: "strip")
        .onPreferenceChange(ZoneKey.self) { model.zones = $0 }
        .animation(.snappy(duration: 0.18), value: model.expanded)
        .animation(.snappy(duration: 0.18), value: model.targeted)
        .environment(\.colorScheme, .dark)
    }

    private func box(_ action: StripAction) -> some View {
        let isTarget = model.targeted == "box.\(action.rawValue)"
        let isOpen = model.expanded == action
        return VStack(spacing: 5) {
            Image(systemName: action.symbol)
                .font(.system(size: 15, weight: .medium))
            Text(action.title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(isOpen || isTarget ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dashedBox(highlighted: isOpen || isTarget))
        .contentShape(Rectangle())
        .onTapGesture { model.expand(isOpen ? nil : action) }
        .zone("box.\(action.rawValue)")
    }

    private func optionsRow(_ action: StripAction) -> some View {
        HStack(spacing: 6) {
            ForEach(model.options(for: action)) { option in
                let isTarget = model.targeted == option.id
                Text(option.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isTarget ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isTarget ? Color.accentColor : Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(isTarget ? 0 : 0.12), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.run(option.operation, on: model.shelfFiles) }
                    .zone(option.id)
            }
        }
        .frame(height: StripModel.optionsHeight)
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: StripModel.rowHeight)
        .background(dashedBox(highlighted: true))
    }

    private var resultsRow: some View {
        HStack(spacing: 8) {
            ForEach(model.results.prefix(3), id: \.self) { url in
                ResultThumb(url: url)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.summary ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !model.results.isEmpty {
                    Text("Drag back to the shelf")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !model.results.isEmpty {
                circleButton("magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting(model.results) }
            }
            circleButton("xmark") { model.clearResults() }
        }
        .padding(.horizontal, 8)
        .frame(height: StripModel.rowHeight)
        .background(dashedBox(highlighted: false))
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func dashedBox(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(highlighted ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        highlighted ? Color.accentColor : Color.white.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1.2, dash: highlighted ? [] : [5, 4])
                    )
            )
    }
}

private struct ResultThumb: View {
    let url: URL

    var body: some View {
        Group {
            if let image = ThumbCache.image(for: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.lastPathComponent)
    }
}

/// SwiftUI's @State needs a macro plugin that only ships with full Xcode, so thumbnails are cached here instead.
@MainActor
private enum ThumbCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = ImageOps.thumbnail(url, size: 120) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Matches the shelf: dark translucent panel, continuous corners, hairline light border.
struct PanelBackground: View {
    /// Offscreen snapshots can't render the blur, so they get a flat stand-in.
    nonisolated(unsafe) static var flat = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Group {
            if Self.flat { Color(white: 0.22) } else { VisualEffect() }
        }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Panel

/// Hosts the SwiftUI strip and takes file drops itself, routing them to whichever box or option is under the pointer.
final class DropHostView: NSView {
    private let model: StripModel
    private let hosting: NSHostingView<StripView>

    init(model: StripModel) {
        self.model = model
        hosting = NSHostingView(rootView: StripView(model: model))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    private func stripPoint(_ info: NSDraggingInfo) -> CGPoint {
        let p = convert(info.draggingLocation, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { model.targeted = nil }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil else { return [] } // our own result thumbnails
        return MainActor.assumeIsolated {
            let point = stripPoint(sender)
            model.hover(at: point)
            return model.operation(at: point) == nil ? [] : .copy
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource == nil else { return false }
        return MainActor.assumeIsolated {
            guard let operation = model.operation(at: stripPoint(sender)) else { return false }
            FileIntake.collect(from: sender.draggingPasteboard) { [model] files in
                model.run(operation, on: files)
            }
            return true
        }
    }
}

final class StripPanel: NSPanel {
    init(model: StripModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 84),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = DropHostView(model: model)
    }

    override var canBecomeKey: Bool { false }
}

enum FileIntake {
    /// File URLs from a drop, receiving promised files (like ones dragged out of some shelves) into a temp folder first.
    static func collect(from pasteboard: NSPasteboard, completion: @escaping @MainActor ([URL]) -> Void) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            MainActor.assumeIsolated { completion(urls) }
            return
        }
        guard let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty else {
            MainActor.assumeIsolated { completion([]) }
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Tack-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let group = DispatchGroup()
        let lock = NSLock()
        var received: [URL] = []
        let queue = OperationQueue()
        for promise in promises {
            // The reader runs once per promised file; leave the group exactly as many times as we entered.
            var remaining = max(1, promise.fileNames.count)
            for _ in 0..<remaining { group.enter() }
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                lock.lock()
                if error == nil { received.append(url) }
                let shouldLeave = remaining > 0
                remaining -= 1
                lock.unlock()
                if shouldLeave { group.leave() }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(received) }
        }
    }
}
