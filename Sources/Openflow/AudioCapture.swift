import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Microphone → 16 kHz mono PCM16, delivered on the main thread in ~20–100 ms chunks.
final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    /// Input device to record from; nil = the system default input.
    var deviceID: AudioDeviceID?
    /// The device actually used by the running session (for diagnostics).
    private(set) var activeDeviceID: AudioDeviceID?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private(set) var isRunning = false
    var onSamples: (@MainActor ([Int16]) -> Void)?

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    func start() throws {
        guard !isRunning else { return }
        // A fresh engine per session, so a newly chosen microphone takes effect cleanly.
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let id = deviceID, let unit = input.audioUnit {
            var dev = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            activeDeviceID = status == noErr ? id : AudioDevices.defaultInputID()
        } else {
            activeDeviceID = AudioDevices.defaultInputID()
        }
        // After switching devices the node's output format can still describe the previous device; the
        // input side reflects the hardware actually selected (sample rate, channels).
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Openflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            let cb = self.onSamples
            DispatchQueue.main.async { MainActor.assumeIsolated { cb?(samples) } }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }
}
