#if DEBUG
import AppKit
import SwiftUI

/// `--render-demo <dir>`: renders the README demo animation frame by frame (PNG, 25 fps) using the app's
/// real `BubbleView`. A scripted dictation: hold ⌃⌥ → waveform + live words → spinner → formatted text
/// pasted into a compose window → ✓. Debug builds only.
@MainActor
enum DemoRender {
    static let size = CGSize(width: 760, height: 460)
    static let duration = 8.6
    static let fps = 25.0

    static func run(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = BubbleModel()
        model.showLiveText = true
        let frames = Int(duration * fps)
        for i in 0..<frames {
            let t = Double(i) / fps
            Script.apply(t, to: model)
            let renderer = ImageRenderer(content: DemoScene(t: t, model: model).frame(width: size.width, height: size.height))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(String(format: "frame-%04d.png", i)))
        }
        NSLog("Openflow demo: rendered %d frames", frames)
        NSApp.terminate(nil)
    }

    /// What was said, when (seconds), and the email that comes out.
    enum Script {
        static let talkStart = 0.6, talkEnd = 4.9, pasteAt = 5.8, doneAt = 6.5
        static let words: [(Double, String)] = [
            (0.9, "Hi"), (1.1, "Priya,"), (1.5, "the"), (1.65, "launch"), (1.85, "moves"), (2.0, "to"), (2.2, "Monday,"),
            (2.55, "no"), (2.7, "wait,"), (2.95, "Tuesday."), (3.35, "Three"), (3.55, "things:"), (3.85, "update"),
            (4.0, "the"), (4.1, "docs,"), (4.3, "ping"), (4.45, "sales,"), (4.6, "and"), (4.7, "ship"), (4.8, "it."),
        ]
        static let email = ["Hi Priya,", "", "The launch moves to Tuesday. Three things before then:", "",
                            "1. Update the docs", "2. Ping sales", "3. Ship it"]

        @MainActor static func apply(_ t: Double, to m: BubbleModel) {
            m.fixedTime = t
            m.hovering = false
            m.liveText = words.filter { $0.0 <= t }.map(\.1).joined(separator: " ")
            switch t {
            case ..<talkStart: m.look = .hidden
            case ..<(talkEnd + 0.15): m.look = .listening
            case ..<pasteAt: m.look = .thinking
            case ..<(doneAt + 0.5): m.look = .pasted
            default: m.look = .hidden
            }
            // Voice level: syllable-like bursts while talking, quiet between phrases.
            let speaking = words.contains { abs($0.0 + 0.08 - t) < 0.16 }
            m.level = speaking ? Float(0.55 + 0.35 * abs(sin(t * 17)) * (0.7 + 0.3 * sin(t * 5))) : (t > talkStart && t < talkEnd ? 0.08 : 0)
        }
    }
}

private struct DemoScene: View {
    var t: Double
    @ObservedObject var model: BubbleModel
    private typealias S = DemoRender.Script

    // Window geometry (points).
    private let window = CGRect(x: 80, y: 34, width: 600, height: 340)
    private static let bodyTop: CGFloat = 70     // room above the caret for the bubble
    private static let bubbleScale: CGFloat = 1.6
    private var bodyOrigin: CGPoint { CGPoint(x: window.minX + 72, y: window.minY + 37 + 2 * 34 + Self.bodyTop) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            composeWindow
                .frame(width: window.width, height: window.height)
                .offset(x: window.minX, y: window.minY)
            bubble
            keycaps
        }
        .frame(width: DemoRender.size.width, height: DemoRender.size.height, alignment: .topLeading)
        .clipped()
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.07, blue: 0.13), Color(red: 0.16, green: 0.14, blue: 0.36),
                                    Color(red: 0.24, green: 0.33, blue: 0.72)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.10), .clear], center: .init(x: 0.5, y: 0.35), startRadius: 0, endRadius: 420)
        }
    }

    private var pasted: Double { min(1, max(0, (t - S.pasteAt) / 0.15)) * (1 - min(1, max(0, (t - 8.25) / 0.3))) }

    private var composeWindow: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                    Spacer()
                }
                Text("New Message").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.3))
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(Color(white: 0.965))
            hairline
            field("To:", "Priya Raman")
            field("Subject:", "Launch update")
            VStack(alignment: .leading, spacing: 5) {
                if pasted > 0 {
                    ForEach(Array(S.email.enumerated()), id: \.offset) { i, line in
                        HStack(spacing: 1) {
                            Text(line.isEmpty ? " " : line).font(.system(size: 14)).foregroundStyle(Color(white: 0.11))
                            if i == S.email.count - 1 { caret }
                        }
                    }
                    .opacity(pasted)
                } else {
                    caret
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 72).padding(.trailing, 22).padding(.top, Self.bodyTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Shadow on the frame only, so text inside never gets a halo.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12))
    }

    private var hairline: some View { Rectangle().fill(Color(white: 0.88)).frame(height: 1) }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13)).foregroundStyle(Color(white: 0.55))
                Text(value).font(.system(size: 13)).foregroundStyle(Color(white: 0.15))
                Spacer()
            }
            .padding(.horizontal, 22).frame(height: 33)
            hairline
        }
        .background(Color.white)
    }

    private var caret: some View {
        Rectangle().fill(Color(red: 0.0, green: 0.48, blue: 1.0))
            .frame(width: 2, height: 18)
            .opacity(t.truncatingRemainder(dividingBy: 1.0) < 0.55 ? 1 : 0.15)
    }

    /// The real bubble, just above the caret at the start of the body (where dictation began).
    private var bubble: some View {
        let appear = min(1, max(0, (t - S.talkStart) / 0.18))
        let vanish = 1 - min(1, max(0, (t - (S.doneAt + 0.2)) / 0.3))
        let caretTop = bodyOrigin.y
        let panel = CGSize(width: 300, height: 74)
        let k = Self.bubbleScale
        return BubbleView(model: model, onClose: {})
            .frame(width: panel.width, height: panel.height)
            .scaleEffect(k * (0.6 + 0.4 * appear), anchor: .bottom)
            .opacity(appear * vanish)
            // Pill bottom (8 pt above the panel's bottom, scaled) sits 8 pt above the caret, centered on it.
            .offset(x: bodyOrigin.x + 1 - panel.width / 2, y: caretTop - 8 - panel.height + 8 * k)
    }

    private var keycaps: some View {
        let holding = t >= S.talkStart && t < S.talkEnd + 0.15
        let caption: String = {
            if t < S.talkStart { return "Click where you want to type" }
            if holding { return "Holding ⌃⌥ and talking" }
            if t < S.pasteAt { return "Released · writing it up" }
            return "Pasted, ready to send"
        }()
        return HStack(spacing: 10) {
            ForEach(["⌃", "⌥"], id: \.self) { k in
                Text(k).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(holding ? Color.black : .white.opacity(0.85))
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(holding ? Color.white : .white.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
            }
            Text(caption).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: DemoRender.size.width)
        .offset(y: window.maxY + 26)
    }
}
#endif
