import AppKit
import ApplicationServices
import OpenflowCore

/// `--docs-probe <seconds>`: waits until a Google Docs window is frontmost, then records what Chrome's
/// accessibility tree exposes around the caret (DOM classes containing cursor/caret, text inputs, the
/// focused element, selection markers) to ~/Library/Logs/Openflow/docs-probe.log, and quits.
/// Records roles, DOM class names, and frames only — no document text.
@MainActor
enum DocsProbe {
    static func run(seconds: Int) {
        let url = CaretLog.url.deletingLastPathComponent().appendingPathComponent("docs-probe.log")
        var lines: [String] = ["probe start trusted=\(AXIsProcessTrusted())"]
        func flush() { try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        flush()
        var left = seconds
        var shots = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            MainActor.assumeIsolated {
                left -= 1
                if left <= 0 { lines.append("timeout"); flush(); t.invalidate(); NSApp.terminate(nil); return }
                guard let front = NSWorkspace.shared.frontmostApplication,
                      CaretResolver.chromiumBrowsers.contains(front.bundleIdentifier ?? "") else { return }
                SystemInserter.prepareAccessibility(for: front)
                guard let win = CaretLocator.focusedWindow(pid: front.processIdentifier),
                      let title = CaretLocator.string(win, kAXTitleAttribute), title.contains("Google Docs") else { return }
                shots += 1
                lines.append("=== shot \(shots) window=\(fmt(CaretLocator.frame(win)))")
                if let el = SystemInserter.focusedElement() {
                    lines.append("focused role=\(CaretLocator.string(el, kAXRoleAttribute) ?? "-") classes=\(classes(el)) frame=\(fmt(CaretLocator.frame(el))) marker=\(fmt(CaretLocator.markerCaret(el))) range=\(fmt(CaretLocator.rangeCaret(el)))")
                }
                let t0 = Date()
                var visited = 0
                var queue: [(AXUIElement, Int)] = [(win, 0)]
                while !queue.isEmpty, visited < 25_000 {
                    let (el, depth) = queue.removeFirst()
                    visited += 1
                    let cls = classes(el)
                    let role = CaretLocator.string(el, kAXRoleAttribute) ?? "-"
                    let lc = cls.lowercased()
                    if lc.contains("cursor") || lc.contains("caret") || lc.contains("texteventtarget")
                        || role == "AXTextArea" || role == "AXTextField" {
                        lines.append("node depth=\(depth) role=\(role) classes=\(cls) frame=\(fmt(CaretLocator.frame(el)))")
                    }
                    var kids: CFTypeRef?
                    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                       let arr = kids as? [AXUIElement] {
                        for k in arr { queue.append((k, depth + 1)) }
                    }
                }
                lines.append("visited=\(visited) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                flush()
                if shots >= 3 { lines.append("done"); flush(); t.invalidate(); NSApp.terminate(nil) }
            }
        }
    }

    static func classes(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXDOMClassList" as CFString, &v) == .success, let arr = v as? [String] else { return "-" }
        return arr.joined(separator: ".")
    }

    static func fmt(_ r: CGRect?) -> String {
        r.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-"
    }
}
