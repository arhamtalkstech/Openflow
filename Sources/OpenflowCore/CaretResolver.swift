import CoreGraphics
import Foundation

/// Where the user last clicked, plus what happened since (keys, scrolling) — the fallback anchor for
/// apps whose accessibility caret is missing or wrong (Google Docs draws on a canvas and reports a hidden input).
public struct ClickAnchor: Sendable, Equatable {
    /// Cocoa screen coordinates (origin bottom-left).
    public var point: CGPoint
    public var time: TimeInterval
    public var pid: Int32
    /// Printable characters typed since the click (backspace subtracts).
    public var typedSince: Int = 0
    /// Arrow keys, Return, Tab, ⌘/⌃ shortcuts, or scrolling happened: the caret is no longer at the click.
    public var invalidated = false

    public init(point: CGPoint, time: TimeInterval, pid: Int32) {
        self.point = point; self.time = time; self.pid = pid
    }
}

/// Everything known about the caret at the moment the bubble is placed.
public struct CaretInputs: Sendable {
    /// The editor's own visible caret element (Google Docs `kix-cursor-caret`), Cocoa coordinates.
    public var domCaret: CGRect? = nil
    /// Caret rect from the browser text-marker API (Chrome, Safari, Electron), Cocoa coordinates.
    public var markerCaret: CGRect?
    /// Caret rect from `AXBoundsForRange` (native text views), Cocoa coordinates.
    public var rangeCaret: CGRect?
    public var elementFrame: CGRect?
    public var windowFrame: CGRect?
    public var screens: [CGRect]
    public var frontPID: Int32
    public var click: ClickAnchor?
    public var mouse: CGPoint
    public var now: TimeInterval
    /// The accessibility caret is known to be unreliable here (Google Docs/Sheets/Slides).
    public var preferClick: Bool
    /// Clicking moves the text cursor in this app (false for terminals).
    public var clickMovesCaret: Bool

    public init(markerCaret: CGRect? = nil, rangeCaret: CGRect? = nil, elementFrame: CGRect? = nil,
                windowFrame: CGRect? = nil, screens: [CGRect], frontPID: Int32, click: ClickAnchor? = nil,
                mouse: CGPoint, now: TimeInterval, preferClick: Bool = false, clickMovesCaret: Bool = true) {
        self.markerCaret = markerCaret; self.rangeCaret = rangeCaret; self.elementFrame = elementFrame
        self.windowFrame = windowFrame; self.screens = screens; self.frontPID = frontPID; self.click = click
        self.mouse = mouse; self.now = now; self.preferClick = preferClick; self.clickMovesCaret = clickMovesCaret
    }
}

public struct CaretResult: Sendable, Equatable {
    public enum Source: String, Sendable { case domCaret, textMarker, textRange, click, field, window, mouse }
    public var rect: CGRect
    public var source: Source
    /// Precise enough to follow the caret after a paste (true for accessibility carets).
    public var tracksEdits: Bool { source == .domCaret || source == .textMarker || source == .textRange }
}

public enum CaretResolver {
    /// Average character advance used to nudge a click anchor after typing (points).
    static let charAdvance: CGFloat = 6.5
    /// A click older than this is not trusted as the caret position.
    static let clickMaxAge: TimeInterval = 15 * 60

    public static func resolve(_ c: CaretInputs) -> CaretResult {
        // The blinking caret the editor draws is the ground truth when an app exposes it.
        if let d = c.domCaret, isPlausibleCaret(d, c) { return CaretResult(rect: d, source: .domCaret) }
        let ax = [(c.markerCaret, CaretResult.Source.textMarker), (c.rangeCaret, .textRange)]
            .compactMap { r, s in r.flatMap { isPlausibleCaret($0, c) ? CaretResult(rect: $0, source: s) : nil } }
            .first
        let click = clickRect(c)

        if c.preferClick, let click { return CaretResult(rect: click, source: .click) }
        // A plausible caret from the app is the truth: clicks past the end of a line or below the text
        // put the caret somewhere other than the click, and terminals ignore clicks entirely.
        if let ax { return ax }
        if let click { return CaretResult(rect: click, source: .click) }
        // Ignore hidden inputs (Google Docs reports a 938×1 offscreen box as the focused field).
        if let f = c.elementFrame, f.width >= 8, f.height >= 8 {
            // Single-line field: the caret is usually near the start of the text. Multi-line: its first line.
            let guess = f.height < 60
                ? CGRect(x: f.minX + min(24, f.width / 2), y: f.minY, width: 1, height: f.height)
                : CGRect(x: f.minX + 16, y: f.maxY - 26, width: 1, height: 18)
            // Scroll views (e.g. a terminal's scrollback) can be far bigger than the window: only use a visible point.
            if visible(CGPoint(x: guess.midX, y: guess.midY), c) { return CaretResult(rect: guess, source: .field) }
        }
        if let w = c.windowFrame, c.screens.contains(where: { $0.intersects(w) }) {
            return CaretResult(rect: CGRect(x: w.midX, y: w.minY + 70, width: 1, height: 18), source: .window)
        }
        return CaretResult(rect: CGRect(x: c.mouse.x, y: c.mouse.y - 10, width: 1, height: 20), source: .mouse)
    }

    /// Caret-shaped, on a screen, inside the focused window, and not just the whole field's frame.
    static func isPlausibleCaret(_ r: CGRect, _ c: CaretInputs) -> Bool {
        guard r.height >= 4, r.height <= 150, r.width <= 60, r.minX > -20_000, r.minY > -20_000 else { return false }
        guard c.screens.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(r) }) else { return false }
        if let w = c.windowFrame, !w.insetBy(dx: -4, dy: -4).intersects(r) { return false }
        if let e = c.elementFrame, e.height > 60, abs(e.minX - r.minX) < 1, abs(e.minY - r.minY) < 1,
           abs(e.height - r.height) < 1 { return false }  // the app returned its own frame
        return true
    }

    public static func clickRect(_ c: CaretInputs) -> CGRect? {
        guard c.clickMovesCaret, let a = c.click, !a.invalidated, a.pid == c.frontPID, c.now - a.time <= clickMaxAge else { return nil }
        if let w = c.windowFrame, !w.contains(a.point) { return nil }
        var x = a.point.x + CGFloat(max(0, min(a.typedSince, 80))) * charAdvance
        if let w = c.windowFrame { x = min(x, w.maxX - 12) }
        return CGRect(x: x, y: a.point.y - 9, width: 1, height: 18)
    }

    static func visible(_ p: CGPoint, _ c: CaretInputs) -> Bool {
        guard c.screens.contains(where: { $0.contains(p) }) else { return false }
        if let w = c.windowFrame { return w.contains(p) }
        return true
    }

    static func contained(_ r: CGRect, in c: CaretInputs) -> Bool {
        guard c.screens.contains(where: { $0.intersects(r) }) else { return false }
        if let w = c.windowFrame { return w.insetBy(dx: -4, dy: -4).intersects(r) }
        return true
    }

    /// Terminals keep the cursor where the shell or TUI put it; clicks don't move it.
    public static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                                "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
                                                "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio"]

    /// Chromium browsers build their web accessibility tree only for assistive apps (AXEnhancedUserInterface).
    public static let chromiumBrowsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
                                                       "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
                                                       "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.openai.atlas"]

    /// Google Docs/Sheets/Slides (and similar canvas editors) report a hidden input as the caret.
    public static func prefersClick(bundleID: String?, windowTitle: String?) -> Bool {
        let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
                                     "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
                                     "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.apple.Safari",
                                     "org.mozilla.firefox", "com.openai.atlas"]
        guard let b = bundleID, browsers.contains(b) || b.hasPrefix("com.google.Chrome.app.") else { return false }
        let t = windowTitle ?? ""
        return ["Google Docs", "Google Sheets", "Google Slides", "Google Drawings"].contains { t.contains($0) }
    }
}
