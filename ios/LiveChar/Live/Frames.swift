import AVFoundation
import CoreImage
import CoreVideo
import Metal
import UIKit

/// One GPU context for all frame work (crop, rotate, zoom, photo).
enum GPU {
    static let device = MTLCreateSystemDefaultDevice()
    static let ci: CIContext = {
        var opts: [CIContextOption: Any] = [.cacheIntermediates: false, .priorityRequestLow: false]
        opts[.outputColorSpace] = CGColorSpace(name: CGColorSpace.sRGB)
        if let device { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: opts)
    }()
}

/// Reusable IOSurface-backed pixel buffers of one size/format.
final class PixelPool {
    private var pool: CVPixelBufferPool?
    private var w = 0, h = 0
    private var format: OSType = 0
    private let lock = NSLock()

    func buffer(_ width: Int, _ height: Int, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        if pool == nil || width != w || height != h || format != self.format {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
            pool = p; w = width; h = height; self.format = format
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        if let pb, format != kCVPixelFormatType_32BGRA {
            // tell CoreImage / encoders which YUV matrix the pixels use
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        return pb
    }
}

/// Normalised crop of the output (top-left origin, 0...1). `.full` = no zoom.
struct Framing: Equatable {
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let full = Framing()
    var zoom: CGFloat { 1 / max(rect.width, 0.0001) }
    var isFull: Bool { rect.width >= 0.999 }

    /// zoom 1...4 around a normalised centre, kept inside the frame
    static func make(zoom: CGFloat, center: CGPoint) -> Framing {
        let z = min(4, max(1, zoom)), s = 1 / z
        let x = min(1 - s, max(0, center.x - s / 2)), y = min(1 - s, max(0, center.y - s / 2))
        return Framing(rect: CGRect(x: x, y: y, width: s, height: s))
    }
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

enum FrameOps {
    /// Scale + crop `image` to fill exactly w x h (like CSS object-fit: cover).
    static func cover(_ image: CIImage, _ w: Int, _ h: Int) -> CIImage {
        let e = image.extent
        let s = max(CGFloat(w) / e.width, CGFloat(h) / e.height)
        var o = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        o = o.transformed(by: CGAffineTransform(translationX: -(o.extent.width - CGFloat(w)) / 2, y: -(o.extent.height - CGFloat(h)) / 2))
        return o.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Apply output zoom: the framing's rect of the frame, scaled back up to full size.
    static func framed(_ image: CIImage, _ f: Framing) -> CIImage {
        guard !f.isFull else { return image }
        let e = image.extent
        // CoreImage has a bottom-left origin
        let r = CGRect(x: e.minX + f.rect.minX * e.width, y: e.minY + (1 - f.rect.maxY) * e.height,
                       width: f.rect.width * e.width, height: f.rect.height * e.height)
        return image.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: e.width / r.width, y: e.height / r.height))
            .cropped(to: CGRect(x: 0, y: 0, width: e.width, height: e.height))
    }

    static func render(_ image: CIImage, into pool: PixelPool, _ w: Int, _ h: Int,
                       format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) -> CVPixelBuffer? {
        guard let out = pool.buffer(w, h, format: format) else { return nil }
        GPU.ci.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }

    static func size(_ pb: CVPixelBuffer) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
    }

    static func sampleBuffer(_ pb: CVPixelBuffer, time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> CMSampleBuffer? {
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    static func jpeg(_ pb: CVPixelBuffer, maxSide: CGFloat = 1280, quality: CGFloat = 0.85) -> Data? {
        var img = CIImage(cvPixelBuffer: pb)
        let s = min(1, maxSide / max(img.extent.width, img.extent.height))
        if s < 1 { img = img.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return GPU.ci.jpegRepresentation(of: img, colorSpace: cs, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}

extension UIImage {
    /// JPEG for the character reference: at most `maxSide`, upright.
    func referenceJPEG(maxSide: CGFloat = 1024) -> Data? {
        let s = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return img.jpegData(compressionQuality: 0.9)
    }
}
