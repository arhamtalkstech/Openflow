import AppKit
import ApplicationServices
import OpenflowCore

/// Reads the focused text field through the Accessibility API and inserts text by pasting
/// (⌘V) with the user's clipboard restored afterwards.
@MainActor
final class SystemInserter: TextInserting {
    /// The app that was frontmost when dictation started (paste goes back there).
    private(set) var targetApp: NSRunningApplication?
    /// Called with the exact text pasted (keeps the click anchor in step with the caret).
    var onPasted: ((String) -> Void)?

    func rememberTarget() {
        // Includes Openflow itself (the setup assistant's practice box).
        targetApp = NSWorkspace.shared.frontmostApplication
        if let app = targetApp { Self.prepareAccessibility(for: app) }
    }

    // MARK: TextInserting

    func captureContext(includeFieldText: Bool) -> InsertionContext {
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        var ctx = InsertionContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier)
        ctx.field = Self.fieldInfo()  // field type, placeholder, window title: metadata, not your text
        // Only the last few words are sent (GrokFormatter trims to ≤ 12 words), never the whole field.
        if includeFieldText { ctx.textBeforeCursor = textBefore(limit: 200) }
        return ctx
    }

    func captureSelection() -> String? {
        guard let el = Self.focusedElement(), !Self.isSecure(el) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &value) == .success,
              let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        lastSelection = s
        return s
    }
    private var lastSelection: String?

    /// What Openflow last pasted in each app (in memory only). Exact while the user hasn't clicked or typed there.
    private var recent: [Int32: RecentInsert] = [:]
    /// Count of the user's own clicks and key presses (from ClickTracker).
    var inputCount: () -> Int = { 0 }

    /// Text right before the cursor: our own last paste if nothing changed since, else what the app reports.
    func textBefore(limit: Int) -> String? {
        let pid = (targetApp ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier ?? -1
        if let m = recent[pid], m.isValid(pid: pid, inputCount: inputCount(), now: ProcessInfo.processInfo.systemUptime) {
            return String(m.text.suffix(limit))
        }
        return Self.textBeforeCursor(limit: limit)
    }

    @discardableResult
    func insert(_ text: String, action: InsertAction, pastedEarlierInSession: Bool,
                completion: ((InsertOutcome) -> Void)?) -> String {
        var prefix = ""
        switch action {
        case .replaceSelection:
            break  // pasting over the selection replaces it
        case .insertAfterSelection:
            Self.postKey(124)  // → collapses the selection to its end
            prefix = SmartSpacing.prefix(before: lastSelection ?? "", insertion: text, pastedEarlierInSession: true)
        case .insertAtCursor:
            prefix = SmartSpacing.prefix(before: textBefore(limit: 8), insertion: text, pastedEarlierInSession: pastedEarlierInSession)
        }
        lastSelection = nil
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        var body = prefix + text
        var typedSpace = false
        if prefix == " ", CaretResolver.terminals.contains(app?.bundleIdentifier ?? "") {
            // Terminal apps (and CLIs running in them) often trim leading whitespace from pasted text:
            // type the joining space as a real key press instead.
            typedSpace = true
            body = text
        }
        let payload = prefix + text
        // What the field looked like before, to confirm the paste landed (nil if the app hides its text).
        let fieldBefore = Self.fieldSnapshot()
        Self.whenModifiersReleased { [weak self] in
            guard let self else { return }
            if typedSpace { Self.postKey(49) }
            self.paste(body) { [weak self] restore in
                self?.verify(before: fieldBefore, body: body, attempt: 1, restore: restore, completion: completion)
            }
        }
        if let pid = app?.processIdentifier {
            let previous = recent[pid].flatMap { $0.isValid(pid: pid, inputCount: inputCount(), now: ProcessInfo.processInfo.systemUptime) ? $0.text : nil }
            let known = action == .replaceSelection ? text : (previous ?? "") + payload
            recent[pid] = RecentInsert(pid: pid, text: String(known.suffix(400)), time: ProcessInfo.processInfo.systemUptime,
                                       inputCount: inputCount())
        }
        onPasted?(action == .replaceSelection ? "\n" : payload)  // a replaced selection moves the caret unpredictably
        return payload
    }

    /// The paste is checked twice before it counts as failed (an app may apply it, or update its
    /// accessibility text, a little late); only then is ⌘V sent a second time.
    private func verify(before: String?, body: String, attempt: Int, restore: @escaping (Bool) -> Void,
                        completion: ((InsertOutcome) -> Void)?) {
        guard let before else {
            restore(true)
            completion?(.unverified)
            return
        }
        func changed() -> Bool? { Self.fieldSnapshot().map { $0 != before } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                if changed() != false { restore(true); completion?(changed() == nil ? .unverified : .inserted); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated {
                        if changed() != false { restore(true); completion?(changed() == nil ? .unverified : .inserted); return }
                        guard attempt == 1, let self else {
                            // Still unchanged after a second ⌘V: leave the text on the clipboard for the user.
                            restore(false)
                            completion?(.failed)
                            return
                        }
                        Self.whenModifiersReleased {
                            Self.sendPaste()
                            self.verify(before: before, body: body, attempt: 2, restore: restore, completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// Text before the cursor plus the field's length, as a cheap "did anything change" fingerprint.
    static func fieldSnapshot() -> String? {
        guard let el = focusedElement(), !isSecure(el) else { return nil }
        if let f = CaretLocator.frame(el), f.width < 8 || f.height < 8 { return nil }  // hidden inputs
        var count: CFTypeRef?
        let n = AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &count) == .success
            ? (count as? Int) : nil
        let before = textBeforeCursor(limit: 120)
        guard n != nil || before != nil else { return nil }
        return "\(n ?? -1)|\(before ?? "")"
    }

    /// Wait (≤ 1.5 s) until no modifier keys are physically held: a still-held ⌃⌥ hotkey would turn
    /// ⌘V into ⌃⌥⌘V, which apps ignore.
    static func whenModifiersReleased(_ f: @escaping @MainActor () -> Void, deadline: TimeInterval? = nil) {
        let end = deadline ?? ProcessInfo.processInfo.systemUptime + 1.5
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn])
        if held.isEmpty || ProcessInfo.processInfo.systemUptime >= end {
            f()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                MainActor.assumeIsolated { whenModifiersReleased(f, deadline: end) }
            }
        }
    }

    /// Re-paste arbitrary text (menu: "Paste last dictation").
    func pasteRaw(_ text: String) {
        let before = Self.textBeforeCursor(limit: 4)
        let body = SmartSpacing.prefix(before: before, insertion: text, pastedEarlierInSession: false) + text
        Self.whenModifiersReleased { [weak self] in self?.paste(body) { restore in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { restore(true) }
        } }
    }

    // MARK: Paste with clipboard restore

    /// Puts `s` on the clipboard and sends ⌘V. `then` receives a `restore(Bool)` closure: call it with true
    /// to put the user's previous clipboard back (once the paste is confirmed), false to leave the text there.
    private func paste(_ s: String, then: @escaping (_ restore: @escaping (Bool) -> Void) -> Void) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        // Ask clipboard managers not to record this transient write.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        let ourChange = pb.changeCount

        Self.sendPaste()

        var done = false
        let restore: (Bool) -> Void = { putBack in
            guard !done else { return }
            done = true
            guard putBack, pb.changeCount == ourChange else { return }  // user copied something meanwhile
            // Give slow apps a moment to finish reading the pasteboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard pb.changeCount == ourChange else { return }
                pb.clearContents()
                guard !saved.isEmpty else { return }
                let items = saved.map { dict -> NSPasteboardItem in
                    let it = NSPasteboardItem()
                    for (t, data) in dict { it.setData(data, forType: t) }
                    return it
                }
                pb.writeObjects(items)
            }
        }
        then(restore)
    }

    /// ⌘V into the frontmost app. Openflow's own windows (About you, practice box, API key) get the paste
    /// action directly: no synthetic key event, no dependence on keyboard routing.
    static func sendPaste() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
            return
        }
        postKey(9, flags: .maskCommand)
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Keep physically held modifiers (e.g. a hotkey still down) from leaking into the shortcut.
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                        state: .eventSuppressionStateSuppressionInterval)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            e.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: Accessibility helpers

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Field kind, placeholder/label, and window title for the cleanup prompt.
    static func fieldInfo() -> FieldInfo? {
        guard let el = focusedElement(), !isSecure(el) else { return nil }
        let role = CaretLocator.string(el, kAXRoleAttribute) ?? ""
        let kind: FieldInfo.Kind
        switch role {
        case kAXTextFieldRole, kAXComboBoxRole, "AXSearchField": kind = .singleLine
        case kAXTextAreaRole: kind = .multiLine
        default: kind = .unknown
        }
        let label = [kAXPlaceholderValueAttribute as String, kAXDescriptionAttribute, kAXTitleAttribute]
            .lazy.compactMap { CaretLocator.string(el, $0) }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let title = CaretLocator.windowElement(of: el).flatMap { CaretLocator.string($0, kAXTitleAttribute) }
        return FieldInfo(kind: kind, label: label, windowTitle: title)
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &role)
        return (role as? String) == (kAXSecureTextFieldSubrole as String)
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Text immediately before the caret (or selection start), if the app exposes it.
    static func textBeforeCursor(limit: Int) -> String? {
        guard let el = focusedElement(), !isSecure(el), let range = selectedRange(el) else { return nil }
        // Hidden inputs (Google Docs' 938×1 offscreen box) report an empty field: unknown, not "start of text".
        if let f = CaretLocator.frame(el), f.width < 8 || f.height < 8 { return nil }
        if range.location == 0 { return "" }
        let start = max(0, range.location - limit)
        var r = CFRange(location: start, length: range.location - start)
        if let axRange = AXValueCreate(.cfRange, &r) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                          axRange, &out) == .success, let s = out as? String {
                return s
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let full = value as? String else { return nil }
        let ns = full as NSString
        guard range.location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: range.location - start))
    }

    /// AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
    static func flip(_ r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private static var enabledPIDs: Set<pid_t> = []

    /// Electron apps honour AXManualAccessibility; Chromium browsers need AXEnhancedUserInterface (what
    /// VoiceOver sets) before they expose the caret in web pages. Done once per process, on activation,
    /// so the tree is ready by the time the shortcut is pressed.
    static func prepareAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !enabledPIDs.contains(pid), pid != ProcessInfo.processInfo.processIdentifier else { return }
        enabledPIDs.insert(pid)
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if CaretResolver.chromiumBrowsers.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}
