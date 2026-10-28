import AppKit
import HelperCore
import SwiftUI

/// "Protokoll anzeigen …" (docs/logging.md, "The log window"): the log file, followed as
/// `tail -f` does, with a level filter, a search, "Folgen", "Kopieren" and "In Console öffnen".
/// It reads the file, so it shows what a bug report would carry, the worker's lines included.
@MainActor
final class LogStore: ObservableObject {
    /// The lines the window holds; older ones are in the file.
    static let maxEntries = 20_000
    /// What the window reads of the file when it opens.
    static let initialBytes = 2 << 20

    @Published var filter: LogFilter {
        didSet {
            if !Log.muted { UserDefaults.standard.set(filter.rawValue, forKey: "logFilter") }
            rebuild()
        }
    }
    @Published var search = "" { didSet { rebuild() } }
    @Published var follow = LogFollow()
    @Published var debug: Bool {
        didSet {
            Log.debugOn = debug
            Log.notice(.app, "debug lines \(debug ? "on" : "off") (log window)")
        }
    }
    /// The lines the filter and the search let through.
    @Published private(set) var visible: [LogEntry] = []
    /// Goes up when `visible` is made anew rather than added to, so the text view redraws all.
    @Published private(set) var generation = 0

    private var entries: [LogEntry] = []
    private let tail = LogTail(url: Log.windowURL)
    private var timer: Timer?
    private var started = false

    init() {
        filter = UserDefaults.standard.string(forKey: "logFilter").flatMap(LogFilter.init(rawValue:)) ?? .info
        debug = Log.debugOn
    }

    /// The window opened: the file's end, then every half second what was added.
    func start() {
        if !started {
            started = true
            add(tail.start(lastBytes: Self.initialBytes), rebuilding: true)
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let lines = tail.read()
        if !lines.isEmpty { add(lines, rebuilding: false) }
    }

    private func add(_ lines: [String], rebuilding: Bool) {
        var new: [LogEntry] = []
        new.reserveCapacity(lines.count)
        for line in lines where !line.isEmpty {
            // A line in another form (written by hand, cut) shows as it is.
            new.append(LogEntry.parse(line)
                ?? LogEntry(date: new.last?.date ?? entries.last?.date ?? Date(), level: .info, category: .app, message: line))
        }
        entries += new
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            return rebuild()
        }
        if rebuilding { return rebuild() }
        let shown = new.filter { filter.shows($0, search: search) }
        if !shown.isEmpty { visible += shown }
    }

    private func rebuild() {
        visible = entries.filter { filter.shows($0, search: search) }
        generation += 1
    }

    /// The visible lines as the window shows them, for "Kopieren".
    var text: String { visible.map(LogLineStyle.plain).joined(separator: "\n") }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text + "\n", forType: .string)
    }

    func openInConsole() {
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            NSWorkspace.shared.activateFileViewerSelecting([Log.windowURL])
            return
        }
        NSWorkspace.shared.open([Log.windowURL], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct LogView: View {
    @StateObject private var store = LogStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Stufe", selection: $store.filter) {
                    ForEach(LogFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Suchen", text: $store.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 220)
                Spacer()
                Toggle("Folgen", isOn: Binding(get: { store.follow.on }, set: { store.follow.on = $0 }))
                    .toggleStyle(.checkbox)
                    .help("Zeigt immer die neueste Zeile. Hochscrollen schaltet es aus, ans Ende scrollen wieder ein.")
                Toggle("Debug aufzeichnen", isOn: $store.debug)
                    .toggleStyle(.checkbox)
                    .help("Schreibt auch die Debug-Zeilen ins Protokoll: jedes Ereignis des Workers, jeden Befehl an ihn, jede Anfrage der Safari-Extension.")
            }
            .padding(8)
            Divider()
            LogTextView(entries: store.visible, generation: store.generation, follow: $store.follow)
                .overlay {
                    if store.visible.isEmpty {
                        Text(store.filter == .debug && !store.debug
                             ? "Keine Zeilen. Debug-Zeilen kommen erst mit „Debug aufzeichnen“."
                             : "Keine Zeilen für diese Auswahl.")
                            .foregroundStyle(.secondary)
                    }
                }
            Divider()
            // The same lines, and older ones, as files to send with a bug report.
            HStack(spacing: 12) {
                Text(Log.windowURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(store.visible.count) Zeilen").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Kopieren") { store.copy() }
                    .help("Kopiert die sichtbaren Zeilen.")
                    .disabled(store.visible.isEmpty)
                Button("In Console öffnen") { store.openInConsole() }
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Log.windowURL]) }
            }
            .padding(8)
        }
        .frame(minWidth: 640, minHeight: 300)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }
}

#if DEBUG
extension LogView {
    /// `-menuPreview YES -logRender <file.png>` (with `-logWindowFile <sample>`): the log window
    /// as the app draws it, for a pull request, then quits (AGENTS.md).
    @MainActor
    static func render(_ model: AppModel, to path: String) {
        model.showLog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            defer { NSApp.terminate(nil) }
            // The window server's picture of the window, title bar and shadow included. An app may
            // take its own windows without the screen-recording permission. CGWindowListCreateImage
            // is gone from the SDK but not from the system; cacheDisplay and CALayer.render leave
            // SwiftUI's controls out.
            typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "log" }),
                  let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let image = unsafeBitCast(symbol, to: Create.self)(.null, 1 << 3 /* including window */,
                                                                     UInt32(window.windowNumber), 0)?.takeRetainedValue()
            else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

/// How a line looks in the window: `28.10. 20:08:35.213  NOTICE  worker    worker started`.
enum LogLineStyle {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm:ss.SSS"
        return f
    }()

    static func plain(_ e: LogEntry) -> String {
        "\(time.string(from: e.date))  \(e.body)"
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    /// A wrapped line goes on under the message, not under the time.
    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        let column = "28.10. 19:30:44.757  NOTICE extension "
        p.headIndent = (column as NSString).size(withAttributes: [.font: font]).width
        return p
    }()

    static func attributed(_ e: LogEntry) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let quiet: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        s.append(NSAttributedString(string: time.string(from: e.date) + "  ", attributes: quiet))
        let levelColor: NSColor
        let text: NSColor
        switch e.level {
        case .fault, .error: (levelColor, text) = (.systemRed, .systemRed)
        case .warning: (levelColor, text) = (.systemOrange, .labelColor)
        case .notice: (levelColor, text) = (.labelColor, .labelColor)
        case .info: (levelColor, text) = (.secondaryLabelColor, .labelColor)
        case .debug: (levelColor, text) = (.tertiaryLabelColor, .secondaryLabelColor)
        }
        let body = e.body
        let head = body.prefix(7 + 10)
        s.append(NSAttributedString(string: String(head.prefix(7)), attributes: [.font: bold, .foregroundColor: levelColor]))
        s.append(NSAttributedString(string: String(head.dropFirst(7)), attributes: quiet))
        s.append(NSAttributedString(string: String(body.dropFirst(head.count)) + "\n", attributes: [.font: font, .foregroundColor: text]))
        s.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: s.length))
        return s
    }
}

/// The lines in an NSTextView: selectable, fast with thousands of lines, and a scroll view that
/// tells the user's scrolling (wheel, trackpad, scroller) from its own scroll to the end.
struct LogTextView: NSViewRepresentable {
    let entries: [LogEntry]
    let generation: Int
    @Binding var follow: LogFollow

    final class ScrollView: NSScrollView {
        var onUserScroll: (() -> Void)?

        override func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)
            onUserScroll?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: LogTextView
        weak var scrollView: ScrollView?
        weak var textView: NSTextView?
        var shownGeneration = -1
        var shownCount = 0
        var wasFollowing = true

        init(_ parent: LogTextView) { self.parent = parent }

        /// The user scrolled: "Folgen" off above the end, on again at it.
        func userScrolled() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.documentVisibleRect
            var follow = parent.follow
            follow.userScrolled(distanceFromEnd: Double(document.bounds.height - visible.maxY))
            guard follow != parent.follow else { return }
            wasFollowing = follow.on
            // Not while SwiftUI updates the view.
            DispatchQueue.main.async { self.parent.follow = follow }
        }

        @objc func liveScrolled(_ note: Notification) { userScrolled() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ScrollView {
        let scroll = ScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.font = LogLineStyle.font
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = text
        context.coordinator.scrollView = scroll
        context.coordinator.textView = text
        scroll.onUserScroll = { [weak coordinator = context.coordinator] in coordinator?.userScrolled() }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.liveScrolled(_:)),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: ScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let text = c.textView, let storage = text.textStorage else { return }
        if c.shownGeneration != generation || entries.count < c.shownCount {
            let all = NSMutableAttributedString()
            for e in entries { all.append(LogLineStyle.attributed(e)) }
            storage.setAttributedString(all)
            c.shownGeneration = generation
            c.shownCount = entries.count
        } else if entries.count > c.shownCount {
            let more = NSMutableAttributedString()
            for e in entries[c.shownCount...] { more.append(LogLineStyle.attributed(e)) }
            storage.append(more)
            c.shownCount = entries.count
        }
        let turnedOn = follow.on && !c.wasFollowing
        c.wasFollowing = follow.on
        if follow.on || turnedOn { text.scrollToEndOfDocument(nil) }
    }
}
