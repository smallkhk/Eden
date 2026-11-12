import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

/// Encodes the output to H.264 on the hardware encoder and uploads it to the user's watch link.
/// One upload in flight at a time; frames that pile up meanwhile go in the next one, so order is kept
/// and a slow uplink costs delay, never corruption (it skips to the next keyframe instead).
final class ShareStreamer {
    private let queue = DispatchQueue(label: "livechar.share", qos: .userInitiated)
    private var session: VTCompressionSession?
    private var size = CGSize.zero
    private var pending = Data()
    private var inFlight = false
    private var forceKey = true
    private var waitKey = true
    private var stopped = false
    private var failures = 0

    /// main thread
    var onViewers: ((Int) -> Void)?
    var onProblem: ((String?) -> Void)?

    func encode(_ pb: CVPixelBuffer) {
        queue.async { self.encodeOnQueue(pb) }
    }

    private func encodeOnQueue(_ pb: CVPixelBuffer) {
        guard !stopped else { return }
        let s = FrameOps.size(pb)
        if session == nil || s != size { makeSession(s) }
        guard let session else { return }
        var props: CFDictionary?
        if forceKey { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary; forceKey = false }
        let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.queue.async { self.packetize(sb) }
        }
    }

    private func makeSession(_ s: CGSize) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; size = s
        var vt: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(s.width), height: Int32(s.height), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &vt)
        guard st == noErr, let vt else { return }
        let pixels = s.width * s.height
        let bitrate = pixels >= 900_000 ? 3_500_000 : 2_000_000
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(vt, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8 * 3 / 2, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(vt)
        session = vt
        forceKey = true; waitKey = true
    }

    private func packetize(_ sb: CMSampleBuffer) {
        guard !stopped, let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if waitKey && !isKey { return }
        if isKey { waitKey = false }

        var annexB = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            // SPS + PPS in front of every keyframe, so a viewer can start from any keyframe
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &len, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    annexB.append(contentsOf: startCode); annexB.append(ptr, count: len)
                }
            }
        }
        var total = 0
        var raw: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &raw) == noErr, let raw else { return }
        raw.withMemoryRebound(to: UInt8.self, capacity: total) { p in
            var o = 0
            while o + 4 <= total {
                let n = Int(p[o]) << 24 | Int(p[o + 1]) << 16 | Int(p[o + 2]) << 8 | Int(p[o + 3])
                o += 4
                guard n > 0, o + n <= total else { break }
                annexB.append(contentsOf: startCode); annexB.append(p + o, count: n)
                o += n
            }
        }

        let ts = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sb).seconds) * 1_000_000)
        var header = Data(count: 13)
        let length = UInt32(9 + annexB.count)
        header[0] = UInt8(length >> 24); header[1] = UInt8(length >> 16 & 0xff); header[2] = UInt8(length >> 8 & 0xff); header[3] = UInt8(length & 0xff)
        header[4] = isKey ? 1 : 0
        for i in 0..<8 { header[5 + i] = UInt8(ts >> (56 - 8 * UInt64(i)) & 0xff) }
        pending.append(header); pending.append(annexB)

        if pending.count > 4_000_000 {      // uplink can't keep up: drop and restart from a keyframe
            pending.removeAll(); forceKey = true; waitKey = true
            DispatchQueue.main.async { self.onProblem?("Your connection is slow, the live link is skipping") }
            return
        }
        flush()
    }

    private func flush() {
        guard !inFlight, !pending.isEmpty, !stopped else { return }
        guard var req = try? API.shared.request("/api/share/frames", method: "POST") else { return }
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body = pending
        pending = Data()
        inFlight = true
        API.shared.session.uploadTask(with: req, from: body) { [weak self] data, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let viewers = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["viewers"] as? Int
            self.queue.async {
                self.inFlight = false
                if err != nil || code != 200 {
                    self.failures += 1
                    self.forceKey = true; self.waitKey = true
                    let msg = code == 401 ? "Log in again to share live" : "Live link: can't reach the server"
                    if self.failures == 3 { DispatchQueue.main.async { self.onProblem?(msg) } }
                } else {
                    if self.failures >= 3 { DispatchQueue.main.async { self.onProblem?(nil) } }
                    self.failures = 0
                    if let viewers { DispatchQueue.main.async { self.onViewers?(viewers) } }
                }
                self.flush()
            }
        }.resume()
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            if let s = self.session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(s) }
            self.session = nil
            self.pending.removeAll()
            Task { try? await API.shared.post("/api/share/stop") }
        }
    }
}
