import AVFoundation
import Combine

/// Captures the microphone the way a streaming app does — through an AVCaptureAudioDataOutput with a
/// sample-buffer delegate — so the LiveChar dylib's mic hook has something to replace. Shows a live
/// level and can play what it captures (use earphones). When the hook is active and LiveChar's voice
/// is live, this level/sound is the transformed voice, not the real mic.
final class MicMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, ObservableObject {
    @Published var level: Float = 0          // 0…1, smoothed RMS
    @Published var monitorOn = false { didSet { monitorOn ? startEngine() : stopEngine() } }

    let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "camtest.mic")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var toEngine: AVAudioConverter?
    private var started = false

    override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    private func startEngine() {
        guard !started else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: engine.mainMixerNode.outputFormat(forBus: 0))
        do { try engine.start(); player.play(); started = true }
        catch { DispatchQueue.main.async { self.monitorOn = false } }
    }

    private func stopEngine() {
        guard started else { return }
        player.stop(); engine.stop(); engine.detach(player); started = false; toEngine = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let srcFormat = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let input = AVAudioPCMBuffer(pcmFormat: srcFormat, bufferListNoCopy: &abl, deallocator: nil) else { return }
        input.frameLength = AVAudioFrameCount(frames)

        // level (RMS) from channel 0, handling float or int16
        var sum: Float = 0
        let n = Int(input.frameLength)
        if let f = input.floatChannelData {
            for i in 0..<n { let v = f[0][i]; sum += v * v }
        } else if let s = input.int16ChannelData {
            for i in 0..<n { let v = Float(s[0][i]) / 32768; sum += v * v }
        }
        let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
        DispatchQueue.main.async { self.level = max(rms, self.level * 0.85) }

        guard monitorOn, started else { return }
        let outFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        if toEngine == nil { toEngine = AVAudioConverter(from: srcFormat, to: outFormat) }
        guard let conv = toEngine,
              let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(frames) * outFormat.sampleRate / srcFormat.sampleRate + 64)) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if err == nil, out.frameLength > 0 { player.scheduleBuffer(out, completionHandler: nil) }
    }
}
