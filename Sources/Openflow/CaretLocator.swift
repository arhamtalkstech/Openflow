import AppKit
import ApplicationServices
import OpenflowCore

/// Remembers where the user last clicked and whether the caret has moved away since.
/// Uses passive global monitors (never delays the user's clicks or keys).
@MainActor
final class ClickTracker {
    private(set) var anchor: ClickAnchor?
    /// The user's own clicks and key presses so far (synthetic events excluded).
    private(set) var inputCount = 0
    private var monitors: [Any] = []

    var isRunning: Bool { !monitors.isEmpty }

    /// Needs Accessibility for key events; call once trusted.
    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .scrollWheel, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        // Clicks and typing inside Openflow's own windows (e.g. the setup assistant's practice box).
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(l) }
    }

    private func handle(_ e: NSEvent) {
        if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventTag { return }
        if e.type == .leftMouseDown || e.type == .keyDown { inputCount += 1 }
        switch e.type {
        case .leftMouseDown:
            let p = NSEvent.mouseLocation
            anchor = ClickAnchor(point: p, time: ProcessInfo.processInfo.systemUptime, pid: Self.ownerPID(at: p) ?? -1)
        case .scrollWheel:
            guard let a = anchor, Self.ownerPID(at: NSEvent.mouseLocation) == a.pid else { return }
            anchor?.invalidated = true
        case .keyDown:
            noteKey(code: Int(e.keyCode), flags: e.modifierFlags, chars: e.characters ?? "")
        default:
            break
        }
    }

    private func noteKey(code: Int, flags: NSEvent.ModifierFlags, chars: String) {
        guard anchor != nil else { return }
        let navigation: Set<Int> = [123, 124, 125, 126, 36, 76, 48, 115, 116, 119, 121, 117]
        if navigation.contains(code) || flags.contains(.command) || flags.contains(.control) {
            anchor?.invalidated = true
        } else if code == 51 {
            let typed = anchor?.typedSince ?? 0
            anchor?.typedSince = max(0, typed - 1)
        } else if !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            anchor?.typedSince += chars.count
        }
    }

    /// Openflow pasted `text` at the caret: single-line text moves the caret right, multi-line is unknowable.
    func notePaste(_ text: String) {
        guard anchor != nil else { return }
        if text.contains("\n") { anchor?.invalidated = true } else { anchor?.typedSince += text.count }
    }

    /// Owner process of the topmost window at a Cocoa screen point (no Screen Recording permission needed).
    static func ownerPID(at p: NSPoint) -> Int32? {
        let num = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        guard num > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(num)) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        return pid
    }
}

/// Finds the text caret on screen, trying the most precise sources first and validating each.
@MainActor
enum CaretLocator {
    static func locate(clicks: ClickTracker?) -> CaretResult {
        let front = NSWorkspace.shared.frontmostApplication
        let el = SystemInserter.focusedElement()
        let window = el.flatMap(windowElement(of:)) ?? front.flatMap { focusedWindow(pid: $0.processIdentifier) }
        let title = window.flatMap { string($0, kAXTitleAttribute) }
        let preferClick = CaretResolver.prefersClick(bundleID: front?.bundleIdentifier, windowTitle: title)
        var inputs = CaretInputs(
            markerCaret: el.flatMap(markerCaret),
            rangeCaret: el.flatMap(rangeCaret),
            elementFrame: el.flatMap(frame),
            windowFrame: window.flatMap(frame),
            screens: NSScreen.screens.map(\.frame),
            frontPID: front?.processIdentifier ?? -1,
            click: clicks?.anchor,
            mouse: NSEvent.mouseLocation,
            now: ProcessInfo.processInfo.systemUptime,
            preferClick: preferClick,
            clickMovesCaret: !CaretResolver.terminals.contains(front?.bundleIdentifier ?? ""))
        if preferClick, let window {
            inputs.domCaret = editorCaret(in: window, near: CaretResolver.clickRect(inputs).map { CGPoint(x: $0.midX, y: $0.midY) })
        }
        let result = CaretResolver.resolve(inputs)
        CaretLog.write(result: result, inputs: inputs, bundleID: front?.bundleIdentifier)
        return result
    }

    /// Google Docs draws its own caret (`div.kix-cursor-caret`) and keeps the real input offscreen.
    /// Chrome exposes that div in the accessibility tree; find it (≈400 nodes, ~50 ms).
    /// While Docs re-renders, an old caret element can linger: prefer the one nearest the click/typing estimate.
    static func editorCaret(in window: AXUIElement, near hint: CGPoint?) -> CGRect? {
        var found: [CGRect] = []
        var queue: [AXUIElement] = [window]
        var visited = 0
        let deadline = Date().addingTimeInterval(0.25)
        while !queue.isEmpty, visited < 4_000, Date() < deadline {
            let el = queue.removeFirst()
            visited += 1
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXDOMClassList" as CFString, &v) == .success,
               let classes = v as? [String], classes.contains("kix-cursor-caret"),
               let f = frame(el), f.height >= 6, f.width <= 8 {
                found.append(f)
                continue
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] { queue.append(contentsOf: arr) }
        }
        guard !found.isEmpty else { return nil }
        if let h = hint {
            return found.min { hypot($0.midX - h.x, $0.midY - h.y) < hypot($1.midX - h.x, $1.midY - h.y) }
        }
        return found.last
    }

    // MARK: Accessibility reads (all converted to Cocoa coordinates)

    /// Chrome, Safari, and Electron: `AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`.
    static func markerCaret(_ el: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, range, &out) == .success,
              let r = rect(from: out) else { return nil }
        return caretShaped(SystemInserter.flip(r))
    }

    /// Native text views: `AXSelectedTextRange` → `AXBoundsForRange` (collapsed to the selection start).
    static func rangeCaret(_ el: AXUIElement) -> CGRect? {
        guard var range = SystemInserter.selectedRange(el) else { return nil }
        range.length = 0
        func bounds(_ r: CFRange) -> CGRect? {
            var rr = r
            guard let v = AXValueCreate(.cfRange, &rr) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, v, &out) == .success
            else { return nil }
            return rect(from: out)
        }
        var r = bounds(range)
        if r == nil || r!.height < 1, range.location > 0,
           let prev = bounds(CFRange(location: range.location - 1, length: 1)), prev.height >= 1 {
            r = CGRect(x: prev.maxX, y: prev.minY, width: 1, height: prev.height)
        }
        guard let r, r.height >= 1 else { return nil }
        return caretShaped(SystemInserter.flip(r))
    }

    /// Selections come back as wide (or multi-line) rects: keep a caret at the start of the first line.
    static func caretShaped(_ r: CGRect) -> CGRect {
        guard r.width > 4 || r.height > 40 else { return r }
        let h = min(r.height, 24)
        return CGRect(x: r.minX, y: r.maxY - h, width: 1, height: h)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        guard s.width > 0, s.height > 0 else { return nil }
        return SystemInserter.flip(CGRect(origin: p, size: s))
    }

    static func windowElement(of el: AXUIElement) -> AXUIElement? {
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &w) == .success,
              let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return (w as! AXUIElement)
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &w) == .success,
              let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return (w as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func rect(from v: CFTypeRef?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r) else { return nil }
        return r
    }
}

/// `~/Library/Logs/Openflow/caret.log`: which source placed the bubble, for diagnosing new apps.
/// Records app bundle IDs and coordinates only (no window titles or text).
enum CaretLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Openflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("caret.log")
    }()

    static func write(result: CaretResult, inputs c: CaretInputs, bundleID: String?) {
        func f(_ r: CGRect?) -> String { r.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-" }
        let click = c.click.map {
            String(format: "%.0f,%.0f age=%.0fs typed=%d stale=%@ samePID=%@", $0.point.x, $0.point.y, c.now - $0.time,
                   $0.typedSince, $0.invalidated ? "y" : "n", $0.pid == c.frontPID ? "y" : "n")
        } ?? "-"
        let line = "\(ISO8601DateFormatter().string(from: Date())) app=\(bundleID ?? "?") source=\(result.source.rawValue) "
            + "at=[\(f(result.rect))] dom=[\(f(c.domCaret))] marker=[\(f(c.markerCaret))] range=[\(f(c.rangeCaret))] field=[\(f(c.elementFrame))] "
            + "window=[\(f(c.windowFrame))] click=[\(click)] preferClick=\(c.preferClick)\n"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 1_000_000 { try? FileManager.default.removeItem(at: url) }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
