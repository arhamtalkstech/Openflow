import AppKit
import Combine
import OpenflowCore
import SwiftUI

/// What the bubble shows.
@MainActor
final class BubbleModel: ObservableObject {
    enum Look: Equatable {
        case hidden, connecting, listening, thinking, pasted, error(String)
        /// Listening, but nothing heard for ~2 s.
        case noAudio
        /// The stream dropped; audio is still being recorded.
        case offline
        /// Something to fix after speaking: message + action button ("Paste" / "Retry") + dismiss.
        case issue(message: String, action: String)
    }
    @Published var look: Look = .hidden
    @Published var level: Float = 0
    @Published var hovering = false
    @Published var liveText = ""
    @Published var showLiveText = true
    @Published var handsFree = false
    /// Fixed animation time for deterministic frames (README demo rendering); nil = live.
    @Published var fixedTime: Double?

    /// Width of the pill for a look (also used for the clickable area).
    func pillWidth(hovering: Bool) -> CGFloat {
        switch look {
        case .hidden: return pillHeight
        case .connecting: return 52 + (hovering ? 22 : 0)
        case .listening: return 80 + (hovering ? 22 : 0)
        case .thinking, .pasted: return pillHeight
        case .error: return 230
        case .noAudio: return 168 + (hovering ? 22 : 0)
        case .offline: return 200 + (hovering ? 22 : 0)
        case .issue: return 272
        }
    }

    /// The last 2–3 words heard, shown tiny inside the pill ("…moved to Tuesday").
    var liveTail: String {
        let words = liveText.split(whereSeparator: { $0.isWhitespace })
        let tail = words.suffix(3).joined(separator: " ")
        return words.count > 3 ? "…" + tail : tail
    }

    var showsLiveWords: Bool { showLiveText && look == .listening && !liveTail.isEmpty }

    /// The pill grows a little taller (same width) once words are recognized.
    var pillHeightNow: CGFloat { showsLiveWords ? 39 : pillHeight }
}

let pillHeight: CGFloat = 28

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    var onClose: () -> Void
    var onAction: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var showClose: Bool {
        guard model.hovering else { return false }
        switch model.look {
        case .listening, .connecting, .noAudio, .offline: return true
        default: return false
        }
    }


    var body: some View {
        VStack(spacing: 5) {
            Spacer(minLength: 0)
            ZStack {
                Capsule(style: .continuous)
                    .fill(Color(white: 0.07).opacity(0.94))
                    .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
                content
            }
            .frame(width: model.pillWidth(hovering: showClose), height: model.pillHeightNow)
            .scaleEffect(model.look == .hidden ? 0.4 : 1)
            .opacity(model.look == .hidden ? 0 : 1)
            .animation(.spring(response: 0.36, dampingFraction: 0.74), value: model.look)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: showClose)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.showsLiveWords)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private let amber = Color(red: 1, green: 0.78, blue: 0.35)

    @ViewBuilder private var content: some View {
        switch model.look {
        case .hidden:
            EmptyView()
        case .connecting:
            HStack(spacing: 6) {
                BreathingDots()
                if showClose { closeButton }
            }
        case .listening:
            HStack(spacing: 7) {
                VStack(spacing: 1) {
                    if model.showsLiveWords {
                        // Proof that words are being heard: the last 2–3, tiny, newest always visible.
                        Text(model.liveTail)
                            .font(.system(size: 8.5, weight: .regular).italic())
                            .foregroundStyle(.white.opacity(0.58))  // quieter than the waveform
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 64)
                            .transition(.opacity)
                            .animation(.easeOut(duration: 0.12), value: model.liveTail)
                    }
                    Waveform(level: model.level, fixedTime: model.fixedTime)
                        .scaleEffect(model.showsLiveWords ? 0.8 : 1)
                }
                if showClose { closeButton.transition(.scale.combined(with: .opacity)) }
            }
        case .noAudio:
            HStack(spacing: 6) {
                Image(systemName: "mic.slash.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(amber)
                Text("No audio detected").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                if showClose { closeButton }
            }
        case .offline:
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1, green: 0.35, blue: 0.35)).frame(width: 6, height: 6)
                Text("Offline · still recording").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                if showClose { closeButton }
            }
        case .thinking:
            Spinner(fixedTime: model.fixedTime).transition(.scale.combined(with: .opacity))
        case .pasted:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.7))
                .transition(.scale.combined(with: .opacity))
        case .error(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                Text(msg).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
        case .issue(let message, let action):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(amber)
                Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Button(action: onAction) {
                    Text(action).font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .black)).foregroundStyle(.white)
                        .frame(width: 17, height: 17).background(Circle().fill(.white.opacity(0.2))).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.leading, 11).padding(.trailing, 6)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.white.opacity(0.2)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop dictation")
    }
}

/// Nine rounded bars that dance with the voice level.
struct Waveform: View {
    var level: Float
    /// Fixed animation time for deterministic frames (README demo rendering); nil = live.
    var fixedTime: Double? = nil
    private let envelope: [CGFloat] = [0.38, 0.6, 0.8, 0.95, 1, 0.95, 0.8, 0.6, 0.38]

    var body: some View {
        Group {
            if let fixedTime {
                bars(fixedTime)
            } else {
                TimelineView(.animation) { ctx in bars(ctx.date.timeIntervalSinceReferenceDate) }
            }
        }
        .frame(height: 18)
    }

    private func bars(_ t: Double) -> some View {
        HStack(spacing: 2.2) {
            ForEach(0..<envelope.count, id: \.self) { i in
                let wobble = 0.55 + 0.45 * sin(t * 10.5 + Double(i) * 0.9) * cos(t * 3.1 + Double(i) * 1.7)
                let idle = 0.5 + 0.5 * sin(t * 2.6 + Double(i) * 0.7)  // gentle breathing when quiet
                let lv = CGFloat(min(1, max(0, level)) * 1.25)
                let h = 3 + envelope[i] * (lv * 15 * CGFloat(wobble) + 1.6 * CGFloat(idle))
                Capsule()
                    .fill(LinearGradient(colors: [.white, Color(red: 0.72, green: 0.86, blue: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.6, height: min(18, h))
            }
        }
        .animation(fixedTime == nil ? .easeOut(duration: 0.08) : nil, value: level)
    }
}

/// Rotating arc loader inside the circle.
struct Spinner: View {
    var fixedTime: Double? = nil
    var body: some View {
        if let fixedTime {
            arc(fixedTime)
        } else {
            TimelineView(.animation) { ctx in arc(ctx.date.timeIntervalSinceReferenceDate) }
        }
    }

    private func arc(_ t: Double) -> some View {
        Circle()
            .trim(from: 0.08, to: 0.72)
            .stroke(AngularGradient(colors: [.white.opacity(0.1), .white], center: .center),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
    }
}

struct BreathingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(.white)
                        .frame(width: 4, height: 4)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 6 - Double(i) * 0.9)))
                }
            }
        }
    }
}

/// Click-through-friendly floating panel that never takes focus from the app you are typing in.
final class BubblePanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Positions the bubble above the text caret and mirrors the engine state into it.
@MainActor
final class OverlayController {
    let model = BubbleModel()
    private let panel: BubblePanel
    private let size = NSSize(width: 300, height: 74)
    private var cancellables: Set<AnyCancellable> = []
    private var hoverTimer: Timer?
    private var hideWork: DispatchWorkItem?
    var placement: BubblePlacement = .nearCaret
    var contentView: NSView? { panel.contentView }
    var onClose: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    init() {
        panel = BubblePanel(size: size)
        let view = FirstMouseHostingView(rootView: BubbleView(model: model,
                                                              onClose: { [weak self] in self?.onClose?() },
                                                              onAction: { [weak self] in self?.onAction?() },
                                                              onDismiss: { [weak self] in self?.onDismiss?() }))
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
    }

    private weak var boundEngine: DictationEngine?

    func bind(_ engine: DictationEngine) {
        boundEngine = engine
        engine.$phase.receive(on: RunLoop.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        engine.$noAudio.receive(on: RunLoop.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        engine.$offline.receive(on: RunLoop.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        engine.$issue.receive(on: RunLoop.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        engine.$level.receive(on: RunLoop.main).sink { [weak self] l in self?.model.level = l }.store(in: &cancellables)
        engine.$liveText.receive(on: RunLoop.main).sink { [weak self] t in self?.model.liveText = t }.store(in: &cancellables)
        engine.$mode.receive(on: RunLoop.main).sink { [weak self] m in self?.model.handsFree = (m == .handsFree) }.store(in: &cancellables)
    }

    /// While set, showing the bubble is deferred (a modifier hotkey might turn out to be ⌃C).
    private var suppressUntil: TimeInterval = 0
    private var deferredWork: DispatchWorkItem?

    func suppressBriefly(_ seconds: TimeInterval) {
        suppressUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    /// Combines the engine's phase, mic/offline flags, and any open issue into one bubble look.
    private func recompute() {
        guard let e = boundEngine else { return }
        // Publishers fire before the new value is stored; read the engine on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let issue = e.issue, e.phase != .thinking {
                    self.issueShownAt = ProcessInfo.processInfo.systemUptime
                    self.show(.issue(message: issue.message, action: issue.actionTitle))
                    return
                }
                switch e.phase {
                case .listening where e.offline, .connecting where e.offline: self.show(.offline)
                case .listening where e.noAudio, .connecting where e.noAudio: self.show(.noAudio)
                default: self.apply(phase: e.phase)
                }
            }
        }
    }
    private var issueShownAt: TimeInterval = 0

    private func show(_ look: BubbleModel.Look) {
        hideWork?.cancel()
        if !panel.isVisible {
            reposition()
            panel.orderFrontRegardless()
            startHoverTracking()
        }
        model.look = look
    }

    private func apply(phase: DictationEngine.Phase) {
        let wait = suppressUntil - ProcessInfo.processInfo.systemUptime
        if wait > 0, phase != .idle, !panel.isVisible {
            deferredWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let engine = self.boundEngine, engine.phase != .idle else { return }
                    self.recompute()
                }
            }
            deferredWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        let look: BubbleModel.Look
        switch phase {
        case .idle: look = .hidden
        case .connecting: look = .connecting
        case .listening: look = .listening
        case .thinking: look = .thinking
        case .pasted: look = .pasted
        case .error(let m): look = .error(m)
        }
        if look == .hidden {
            model.look = .hidden
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.look == .hidden else { return }
                    self.panel.orderOut(nil)
                    self.stopHoverTracking()
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            return
        }
        hideWork?.cancel()
        if !panel.isVisible {
            reposition()
            panel.orderFrontRegardless()
            startHoverTracking()
        }
        if case .pasted = look {
            // Editors redraw their caret after the paste lands (Docs takes ~100 ms).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.repositionAfterPaste() }
        }
        model.look = look
    }

    #if DEBUG
    /// `--demo-bubble`: plays every bubble state at screen center (for screenshots and design checks).
    func runDemo(log: @escaping (String) -> Void) {
        placement = .bottomCenter
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY))
        panel.orderFrontRegardless()
        var t: Double = 0
        func at(_ dt: Double, _ label: String, _ f: @escaping @MainActor () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { f(); log(label) } }
        }
        at(0.3, "connecting") { self.model.look = .connecting }
        at(1.2, "listening") { self.model.look = .listening }
        // Fake a voice envelope for the waveform.
        let levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let x = Date().timeIntervalSinceReferenceDate
                self.model.level = Float(max(0, 0.55 + 0.45 * sin(x * 3.3)) * (0.7 + 0.3 * sin(x * 11)))
            }
        }
        at(2.5, "hover") { self.model.hovering = true }
        at(2.0, "unhover") { self.model.hovering = false }
        at(0.8, "thinking") { levelTimer.invalidate(); self.model.level = 0; self.model.look = .thinking }
        at(2.2, "pasted") { self.model.look = .pasted }
        at(1.5, "error") { self.model.look = .error("Add your SpaceXAI API key in Openflow") }
        at(2.5, "hidden") { self.model.look = .hidden }
        at(0.6, "done") { self.panel.orderOut(nil) }
    }

    #endif

    /// Show a short error without a dictation session (missing key, mic denied …).
    func flash(error msg: String) {
        apply(phase: .error(msg))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, case .error = self.model.look else { return }
            self.apply(phase: .idle)
        }
    }

    /// The caret source used for the current bubble position.
    private(set) var lastCaret: CaretResult?
    var clicks: ClickTracker?

    /// Anchor: validated accessibility caret → last click (Google Docs & co.) → focused field → mouse pointer.
    func reposition() {
        let mouse = NSEvent.mouseLocation
        if placement == .bottomCenter {
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 40))
            return
        }
        let caret = CaretLocator.locate(clicks: clicks)
        lastCaret = caret
        let anchor = caret.rect
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bubbleBottomPad: CGFloat = 8
        var y = anchor.maxY + 6 - bubbleBottomPad                    // just above the caret line
        if y + bubbleBottomPad + pillHeight > vf.maxY {                // no room → below
            y = anchor.minY - 6 - pillHeight - bubbleBottomPad
        }
        // Center the pill on the caret; keep it fully on screen.
        var x = anchor.midX - size.width / 2
        x = min(max(x, vf.minX - size.width / 2 + 50), vf.maxX - size.width / 2 - 50)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// After a paste the caret moved: follow it only when the position came from the app itself.
    private func repositionAfterPaste() {
        guard placement == .nearCaret, lastCaret?.tracksEdits == true else { return }
        reposition()
    }

    // Hover is polled: the panel never becomes key, so tracking areas are unreliable.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        model.hovering = false
    }

    private func updateHover() {
        let f = panel.frame
        let w = model.pillWidth(hovering: model.hovering) + 8
        let bubble = NSRect(x: f.midX - w / 2, y: f.minY + 8 - 4, width: w, height: model.pillHeightNow + 8)
        let inside = bubble.contains(NSEvent.mouseLocation)
        if inside != model.hovering { model.hovering = inside }
        // Let clicks pass through the transparent parts of the panel.
        panel.ignoresMouseEvents = !inside
    }
}
