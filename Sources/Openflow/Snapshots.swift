#if DEBUG
import AppKit
import OpenflowCore

/// `--snapshots <dir>`: renders the bubble states and every dashboard section to PNG offscreen
/// (no Screen Recording permission needed), then quits.
@MainActor
enum Snapshots {
    static func run(state: AppState, delegate: AppDelegate, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Offscreen captures don't paint the window background; dark appearance keeps text readable.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        var steps: [(String, () -> Void)] = []
        let model = state.overlay.model
        // Warm-up: the first render of a never-shown panel can be empty.
        steps.append(("warm-up", { model.look = .listening }))
        let looks: [(String, BubbleModel.Look, Float, Bool)] = [
            ("bubble-1-connecting", .connecting, 0, false),
            ("bubble-2-listening-quiet", .listening, 0.1, false),
            ("bubble-3-listening-loud", .listening, 0.85, false),
            ("bubble-4-listening-hover-x", .listening, 0.6, true),
            ("bubble-5-thinking", .thinking, 0, false),
            ("bubble-6-pasted", .pasted, 0, false),
            ("bubble-7-error", .error("Add your SpaceXAI API key in Openflow"), 0, false),
            ("bubble-8-no-audio", .noAudio, 0, false),
            ("bubble-9-offline", .offline, 0.5, false),
            ("bubble-10-issue-paste", .issue(message: "Didn't paste · copied", action: "Paste"), 0, false),
            ("bubble-11-issue-retry", .issue(message: "SpaceXAI unreachable · audio kept", action: "Retry"), 0, false),
            ("bubble-12-live-words", .listening, 0.7, false),
            ("bubble-13-live-first-word", .listening, 0.5, false),
        ]
        for (name, look, level, hover) in looks {
            steps.append(("set \(name)", {
                model.look = look; model.level = level; model.hovering = hover
                model.showLiveText = true
                model.liveText = name == "bubble-12-live-words" ? "Hey team, quick update on the launch, we moved it to Tuesday"
                    : name == "bubble-13-live-first-word" ? "Hey" : ""
            }))
            steps.append((name, { capture(state.overlay.contentView, to: dir.appendingPathComponent("\(name).png"), scale: 3) }))
        }
        for section in DashboardSection.allCases {
            steps.append(("open \(section.rawValue)", { delegate.openDashboardWindow(section) }))
            steps.append(("dashboard-\(section.rawValue)", {
                if let v = delegate.dashboardWindow?.contentView {
                    capture(v, to: dir.appendingPathComponent("dashboard-\(section.rawValue).png"), scale: 1)
                }
            }))
        }
        for step in OnboardingModel.Step.allCases {
            steps.append(("onboarding \(step.rawValue)", { delegate.openOnboarding(at: step) }))
            if step == .apiKey { for _ in 0..<4 { steps.append(("wait for key check", {})) } }
            steps.append(("onboarding-\(step.rawValue)", {
                capture(delegate.onboardingContentView, to: dir.appendingPathComponent(String(format: "onboarding-%d-%@.png", step.rawValue, "\(step)")), scale: 1)
            }))
        }
        // Updates page in each state (no feed contacted).
        let u = state.updates
        let previews: [(String, UpdateController.Status, Bool, Date?)] = [
            ("updates-1-unknown", .unknown, false, nil),
            ("updates-2-checking", .unknown, true, nil),
            ("updates-3-uptodate", .upToDate, false, Date().addingTimeInterval(-180)),
            ("updates-4-available", .available("1.1.2"), false, Date().addingTimeInterval(-60)),
            ("updates-5-failed", .failed("An error occurred in retrieving update information."), false, Date()),
        ]
        for (name, st, checking, last) in previews {
            steps.append(("set \(name)", { u.preview(enabled: true, status: st, checking: checking, lastCheck: last); delegate.openDashboardWindow(.updates) }))
            steps.append((name, {
                if let v = delegate.dashboardWindow?.contentView { capture(v, to: dir.appendingPathComponent("\(name).png"), scale: 1) }
            }))
        }
        // `--only home,account`: render just those dashboard sections (keeps the window on screen briefly).
        let args = ProcessInfo.processInfo.arguments
        if let j = args.firstIndex(of: "--only"), j + 1 < args.count {
            let want = args[j + 1].split(separator: ",").map(String.init)
            steps = steps.filter { s in want.contains { s.0.contains($0) } }
        }
        var i = 0
        func next() {
            guard i < steps.count else { NSApp.terminate(nil); return }
            let (name, f) = steps[i]
            i += 1
            f()
            NSLog("Openflow snapshot step: %@", name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { MainActor.assumeIsolated { next() } }
        }
        next()
    }

    static func capture(_ view: NSView?, to url: URL, scale: CGFloat) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()
        let b = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
