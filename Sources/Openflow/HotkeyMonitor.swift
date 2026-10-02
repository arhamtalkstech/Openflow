import AppKit
import CoreGraphics
import OpenflowCore

/// System-wide keyboard listener built on a CGEvent tap (needs Accessibility permission).
/// Reports press/release of the configured hotkey, Esc, and "another key while the hotkey is held"
/// (so ⌃C with a Control hotkey does not leave a dictation running).
@MainActor
final class HotkeyMonitor {
    var hotkey: Hotkey = .eitherControl
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onOtherKeyWhileHeld: (() -> Void)?
    var onEscape: (() -> Bool)?   // return true to swallow Esc
    /// Shortcut recorder: receives the next shortcut the user presses.
    private var recorder: ((Hotkey?) -> Void)?
    private var recordMaxMods: UInt64 = 0
    private var recordModKeyCode: Int = 0
    private var recordModCount = 0

    private(set) var isInstalled = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var comboHeld = false

    func install() -> Bool {
        if isInstalled { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback,
                                          userInfo: refcon) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isInstalled = true
        return true
    }

    func beginRecording(_ done: @escaping (Hotkey?) -> Void) {
        recorder = done
        recordMaxMods = 0
        recordModCount = 0
        held = false
    }

    func cancelRecording() { recorder = nil }
    var isRecording: Bool { recorder != nil }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue & Hotkey.allModifiers
        if recorder != nil { return record(type: type, code: code, flags: flags) }

        switch type {
        case .flagsChanged:
            switch hotkey.kind {
            case .modifierOnly:
                let isOurKey = hotkey.keyCode == -1 ? (code == 59 || code == 62) : code == hotkey.keyCode
                guard isOurKey, let m = Hotkey.mask(forModifierKeyCode: hotkey.keyCode) else {
                    // Another modifier pressed while ours is held → it's a shortcut like ⌃⌘…, not dictation.
                    if held && flags & ~(Hotkey.mask(forModifierKeyCode: hotkey.keyCode) ?? 0) != 0 { onOtherKeyWhileHeld?() }
                    return false
                }
                let down = flags & m != 0
                if down && !held {
                    // Only a lone press counts (no other modifiers already held).
                    guard flags & ~m == 0 else { return false }
                    held = true
                    onPress?()
                } else if !down && held {
                    held = false
                    onRelease?()
                }
            case .modifierChord:
                let active = flags == hotkey.modifiers
                if active && !held { held = true; onPress?() }
                else if !active && held {
                    held = false
                    onRelease?()
                }
            case .combo:
                break
            }
            return false

        case .keyDown:
            if code == 53 {  // Esc
                return onEscape?() ?? false
            }
            if hotkey.kind == .combo && code == hotkey.keyCode && flags == hotkey.modifiers {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
                comboHeld = true
                onPress?()
                return true
            }
            if held { onOtherKeyWhileHeld?() }
            return false

        case .keyUp:
            if hotkey.kind == .combo && code == hotkey.keyCode && comboHeld {
                comboHeld = false
                onRelease?()
                return true
            }
            return false

        default:
            return false
        }
    }

    private func record(type: CGEventType, code: Int, flags: UInt64) -> Bool {
        switch type {
        case .keyDown:
            if code == 53 && flags == 0 {  // Esc cancels recording
                finishRecording(nil)
                return true
            }
            // Regular key: needs a modifier unless it's an F-key.
            if flags != 0 || Hotkey.isFunctionKey(code) {
                let display = Hotkey.symbols(for: flags) + (flags != 0 ? " " : "") + Hotkey.keyName(code)
                finishRecording(Hotkey(kind: .combo, keyCode: code, modifiers: flags, display: display))
            }
            return true
        case .keyUp:
            return true
        case .flagsChanged:
            if flags != 0 {
                if flags.nonzeroBitCount > recordMaxMods.nonzeroBitCount || recordMaxMods == 0 {
                    recordMaxMods = flags
                }
                recordModKeyCode = code
                recordModCount = recordMaxMods.nonzeroBitCount
            } else if recordMaxMods != 0 {
                // All modifiers released without a regular key → modifier-only or chord.
                if recordModCount == 1 {
                    finishRecording(Hotkey(kind: .modifierOnly, keyCode: recordModKeyCode,
                                           modifiers: Hotkey.mask(forModifierKeyCode: recordModKeyCode) ?? recordMaxMods,
                                           display: Hotkey.modifierKeyName(recordModKeyCode)))
                } else {
                    finishRecording(Hotkey(kind: .modifierChord, keyCode: 0, modifiers: recordMaxMods,
                                           display: Hotkey.symbols(for: recordMaxMods).trimmingCharacters(in: .whitespaces)))
                }
            }
            return false
        default:
            return false
        }
    }

    private func finishRecording(_ h: Hotkey?) {
        let r = recorder
        recorder = nil
        recordMaxMods = 0
        r?(h)
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    // Ignore our own synthetic paste/arrow events.
    if event.getIntegerValueField(.eventSourceUserData) == syntheticEventTag {
        return Unmanaged.passUnretained(event)
    }
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Marker set on events Openflow posts itself.
let syntheticEventTag: Int64 = 0x0F10_F10F
