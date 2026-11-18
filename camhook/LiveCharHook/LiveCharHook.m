// LiveCharHook — an eSign-injectable dylib that replaces the camera in the host app with a LiveChar
// live feed (https://server/watch/<id>).
//
//   * Hooks AVCaptureVideoDataOutput's frame delegate: apps that read camera frames get LiveChar frames.
//   * Overlays an AVSampleBufferDisplayLayer on every AVCaptureVideoPreviewLayer: the on-screen preview
//     shows LiveChar (this is what Cam Test shows).
//   * Same phone first: reads LiveChar's local feed at http://127.0.0.1:8765 (no internet, ~instant).
//     Falls back to the watch link (asked once, remembered in the host app's NSUserDefaults key
//     "livechar.hooklink", or a Documents/livechar.txt file) when LiveChar is not running on this phone.
//   * Frames are played out on their own timestamps through a small buffer, so the picture moves
//     evenly instead of skipping/freezing when frames arrive in bursts.
//
// Video only (no voice): a camera has no audio. Built unsigned; eSign signs it when it injects.
//
// Honest scope: proven to compile. On-device behaviour (does a given app's camera actually get replaced)
// depends on that app and must be tested on the phone. Cam Test's preview is the reference case.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <Network/Network.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kLinkKey = @"livechar.hooklink";

// one decoded frame waiting to be shown at its timestamp
@interface LCFrame : NSObject
@property (nonatomic) CVPixelBufferRef px;
@property (nonatomic) double pts;
@end
@implementation LCFrame
- (void)dealloc { if (_px) CVPixelBufferRelease(_px); }
@end

#pragma mark - feed (download + H.264 decode -> latest CVPixelBuffer)

@interface LCFeed : NSObject <NSURLSessionDataDelegate>
@property (class, readonly) LCFeed *shared;
- (void)ensureRunning;
- (CVPixelBufferRef)copyLatest CF_RETURNS_RETAINED;   // nil if nothing decoded yet
- (CVPixelBufferRef)copyLatestSeq:(uint64_t *)seq CF_RETURNS_RETAINED;
// transformed voice (16 kHz mono s16le) for the virtual mic
- (void)appendAudio:(const int16_t *)s count:(NSUInteger)n;
- (BOOL)pullAudio:(int16_t *)out frames:(int)frames rate:(double)rate;   // YES = real audio written, NO = underflow (out zeroed)
- (BOOL)audioActive;   // voice heard within the last ~2 s
@property (atomic, copy) NSString *state;
@property (atomic) NSInteger localFails;   // consecutive failed tries of the same-phone feed
@end

static void lcDecodeCB(void *outRef, void *srcRef, OSStatus status, VTDecodeInfoFlags flags,
                       CVImageBufferRef image, CMTime pts, CMTime dur);

@implementation LCFeed {
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSMutableData *_buf;
    BOOL _running;
    NSData *_sps, *_pps;
    CMVideoFormatDescriptionRef _format;
    VTDecompressionSessionRef _decoder;
    BOOL _needKey;
    CVPixelBufferRef _latest;      // frame on screen now
    uint64_t _seq;
    NSLock *_lock;
    NSMutableArray<LCFrame *> *_queue;   // decoded, waiting for their time
    double _offset;                // host time - media time (+ delay)
    BOOL _haveClock;
    double _delay;                 // playout buffer, adapts to the connection
    BOOL _usingLocal, _gotData;
    NSUInteger _attempt;
    nw_connection_t _local;        // same-phone feed: raw TCP to 127.0.0.1 (not subject to ATS)
    BOOL _headerDone;
    dispatch_queue_t _netQ;
    NSMutableData *_audio;         // transformed voice, int16 mono @16k, FIFO
    double _resPos;                // fractional read index into _audio (resampler)
    double _lastAudio;             // host time of the last voice packet
    NSLock *_audioLock;
}

+ (LCFeed *)shared {
    static LCFeed *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LCFeed new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _needKey = YES;
        _queue = [NSMutableArray array];
        _delay = 0.08;
        _audio = [NSMutableData data];
        _audioLock = [NSLock new];
        _netQ = dispatch_queue_create("livechar.hook.net", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        c.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    }
    return self;
}

- (NSURL *)linkURL {
    NSString *link = [[NSUserDefaults standardUserDefaults] stringForKey:kLinkKey];
    if (link.length == 0) {
        NSString *file = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/livechar.txt"];
        link = [[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (link.length == 0) return nil;
    NSURL *u = [NSURL URLWithString:link];
    if (!u.host || !([u.scheme isEqualToString:@"https"] || [u.scheme isEqualToString:@"http"])) return nil;
    NSArray *parts = u.pathComponents;
    NSUInteger i = [parts indexOfObject:@"watch"];
    if (i == NSNotFound || i + 1 >= parts.count) return nil;
    NSURLComponents *c = [NSURLComponents new];
    c.scheme = u.scheme; c.host = u.host; c.port = u.port;
    c.path = [NSString stringWithFormat:@"/api/share/%@/stream", parts[i + 1]];
    return c.URL;
}

- (void)ensureRunning {
    @synchronized (self) {
        if (_running) return;
        NSURL *link = [self linkURL];
        // same phone first; while LiveChar isn't serving here, alternate with the internet link
        BOOL local = !link || self.localFails < 2 || (_attempt % 2 == 0);
        _attempt++;
        _usingLocal = local; _gotData = NO;
        _delay = local ? 0.08 : 0.25;
        _haveClock = NO;
        _running = YES;
        self.state = local ? @"waiting for LiveChar on this phone \u2026" : @"connecting to your live link\u2026";
        if (local) { dispatch_async(_netQ, ^{ [self startLocal]; }); return; }
        _buf = [NSMutableData data];
        _task = [_session dataTaskWithURL:link];
        [_task resume];
    }
}

#pragma mark same-phone feed (raw TCP, so App Transport Security in the host app can't block it)

- (void)startLocal {
    _buf = [NSMutableData data];
    _headerDone = NO;
    nw_endpoint_t ep = nw_endpoint_create_host("127.0.0.1", "8765");
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_connection_t c = nw_connection_create(ep, params);
    _local = c;
    nw_connection_set_queue(c, _netQ);
    __weak LCFeed *weakSelf = self;
    nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t st, nw_error_t err) {
        LCFeed *me = weakSelf; if (!me) return;
        if (st == nw_connection_state_ready) {
            const char *req = "GET /api/share/local/stream HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            dispatch_data_t d = dispatch_data_create(req, strlen(req), nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            nw_connection_send(c, d, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t e) {});
            me.state = @"this phone \u2014 press Go live in LiveChar";
            [me receiveLocal:c];
        } else if (st == nw_connection_state_waiting || st == nw_connection_state_failed) {
            [me endLocal:c];          // nothing listening (LiveChar not live here)
        } else if (st == nw_connection_state_cancelled) {
            [me endLocal:c];
        }
    });
    nw_connection_start(c);
}

- (void)receiveLocal:(nw_connection_t)c {
    __weak LCFeed *weakSelf = self;
    nw_connection_receive(c, 1, 1 << 18, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
        LCFeed *me = weakSelf; if (!me || c != me->_local) return;
        if (content) {
            NSMutableData *chunk = [NSMutableData data];
            dispatch_data_apply(content, ^bool(dispatch_data_t r, size_t off, const void *b, size_t n) { [chunk appendBytes:b length:n]; return true; });
            if (!me->_headerDone) {
                [me->_buf appendData:chunk];
                NSRange end = [me->_buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, me->_buf.length)];
                if (end.location == NSNotFound) { [me receiveLocal:c]; return; }
                NSData *rest = [me->_buf subdataWithRange:NSMakeRange(NSMaxRange(end), me->_buf.length - NSMaxRange(end))];
                me->_buf = [NSMutableData data];
                me->_headerDone = YES;
                me.localFails = 0;
                if (rest.length) [me ingest:rest];
            } else {
                [me ingest:chunk];
            }
        }
        if (complete || err) { [me endLocal:c]; return; }
        [me receiveLocal:c];
    });
}

- (void)endLocal:(nw_connection_t)c {
    if (c != _local) return;
    _local = nil;
    nw_connection_cancel(c);
    [self streamEnded];
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t
                                     didReceiveResponse:(NSURLResponse *)resp
                                      completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
    NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
    if (code == 200) { self.state = _usingLocal ? @"this phone \u2014 press Go live in LiveChar" : @"live link \u2014 waiting for LiveChar"; if (_usingLocal) self.localFails = 0; }
    else if (code == 404) self.state = @"link not found (update server / reset link)";
    else self.state = [NSString stringWithFormat:@"server error %ld", (long)code];
    done(code == 200 ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    [self ingest:data];
}

- (void)ingest:(NSData *)data {
    _gotData = YES;
    [_buf appendData:data];
    const uint8_t *b = _buf.bytes;
    NSUInteger n = _buf.length, o = 0;
    while (n - o >= 4) {
        uint32_t len = (b[o] << 24) | (b[o+1] << 16) | (b[o+2] << 8) | b[o+3];
        if (n - o - 4 < len) break;
        if (len >= 9) [self packet:b + o + 4 length:len];
        o += 4 + len;
    }
    if (o > 0) { [_buf replaceBytesInRange:NSMakeRange(0, o) withBytes:NULL length:0]; }
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    [self streamEnded];
}

- (void)streamEnded {
    @synchronized (self) { _running = NO; }
    if (_usingLocal && !_gotData) self.localFails++;
    [self dropDecoder]; _needKey = YES; _sps = nil; _pps = nil;
    self.state = (_usingLocal && ![self linkURL]) ? @"open LiveChar on this phone and press Go live" : @"reconnecting\u2026";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        [self ensureRunning];
    });
}

- (void)packet:(const uint8_t *)p length:(NSUInteger)len {
    uint8_t flags = p[0];
    if (flags & 2) { _needKey = YES; return; }   // stream ended
    if (flags & 4) {                              // transformed voice for the virtual mic
        if (len > 9) [self appendAudio:(const int16_t *)(p + 9) count:(len - 9) / 2];
        return;
    }
    BOOL key = (flags & 1) != 0;
    uint64_t tsus = 0;
    for (int i = 0; i < 8; i++) tsus = (tsus << 8) | p[1 + i];
    const uint8_t *data = p + 9;
    NSUInteger dlen = len - 9;
    // split Annex B into NAL units
    NSMutableArray<NSData *> *slices = [NSMutableArray array];
    NSInteger start = -1;
    for (NSUInteger i = 0; i + 3 <= dlen; ) {
        if (data[i] == 0 && data[i+1] == 0 && (data[i+2] == 1 || (i + 3 < dlen && data[i+2] == 0 && data[i+3] == 1))) {
            NSUInteger sc = data[i+2] == 1 ? 3 : 4;
            if (start >= 0) [self classify:[NSData dataWithBytes:data + start length:i - start] into:slices];
            start = i + sc; i += sc;
        } else i++;
    }
    if (start >= 0 && (NSUInteger)start < dlen) [self classify:[NSData dataWithBytes:data + start length:dlen - start] into:slices];
    if (!_decoder && _sps && _pps) [self buildDecoder];
    if (key) _needKey = NO;
    if (_needKey || !_decoder || slices.count == 0) return;

    NSMutableData *avcc = [NSMutableData data];
    for (NSData *s in slices) {
        uint32_t l = CFSwapInt32HostToBig((uint32_t)s.length);
        [avcc appendBytes:&l length:4];
        [avcc appendData:s];
    }
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, avcc.length, NULL, NULL, 0, avcc.length, 0, &block) != noErr) return;
    CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);
    CMSampleBufferRef sb = NULL;
    size_t sizes[1] = { avcc.length };
    CMSampleTimingInfo timing = { kCMTimeInvalid, CMTimeMake((int64_t)tsus, 1000000), kCMTimeInvalid };
    if (CMSampleBufferCreateReady(NULL, block, _format, 1, 1, &timing, 1, sizes, &sb) == noErr && sb) {
        VTDecompressionSessionDecodeFrame(_decoder, sb, kVTDecodeFrame_EnableAsynchronousDecompression, NULL, NULL);
        CFRelease(sb);
    }
    CFRelease(block);
}

- (void)classify:(NSData *)nal into:(NSMutableArray<NSData *> *)slices {
    if (nal.length == 0) return;
    uint8_t type = ((const uint8_t *)nal.bytes)[0] & 0x1f;
    if (type == 7) { if (![nal isEqualToData:_sps]) { _sps = nal; [self dropDecoder]; } }
    else if (type == 8) { if (![nal isEqualToData:_pps]) { _pps = nal; [self dropDecoder]; } }
    else [slices addObject:nal];
}

- (void)dropDecoder {
    if (_decoder) { VTDecompressionSessionInvalidate(_decoder); CFRelease(_decoder); _decoder = NULL; }
    if (_format) { CFRelease(_format); _format = NULL; }
}

- (void)buildDecoder {
    const uint8_t *ps[2] = { _sps.bytes, _pps.bytes };
    size_t sz[2] = { _sps.length, _pps.length };
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ps, sz, 4, &fmt) != noErr) return;
    _format = fmt;
    NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                             (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    VTDecompressionOutputCallbackRecord cb = { lcDecodeCB, (__bridge void *)self };
    VTDecompressionSessionRef dec = NULL;
    if (VTDecompressionSessionCreate(NULL, fmt, NULL, (__bridge CFDictionaryRef)attrs, &cb, &dec) == noErr) {
        VTSessionSetProperty(dec, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
        _decoder = dec;
    }
}

- (void)storeFrame:(CVImageBufferRef)image pts:(CMTime)pts {
    if (!image) return;
    CVPixelBufferRef px = (CVPixelBufferRef)image;
    self.state = [NSString stringWithFormat:@"live %zu\u00d7%zu%@", CVPixelBufferGetWidth(px), CVPixelBufferGetHeight(px), _usingLocal ? @" \u00b7 this phone" : @""];
    LCFrame *f = [LCFrame new];
    f.px = CVPixelBufferRetain(px);
    f.pts = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : CACurrentMediaTime();
    [_lock lock];
    if (_queue.count && f.pts + 0.5 < _queue.lastObject.pts) { [_queue removeAllObjects]; _haveClock = NO; }   // stream restarted
    [_queue addObject:f];
    while (_queue.count > 20) [_queue removeObjectAtIndex:0];
    [_lock unlock];
}

- (CVPixelBufferRef)copyLatest {
    return [self copyLatestSeq:NULL];
}

// The frame whose time has come: frames are shown on their own timestamps, `_delay` behind real time.
- (CVPixelBufferRef)copyLatestSeq:(uint64_t *)seq {
    double now = CACurrentMediaTime();
    [_lock lock];
    if (_queue.count) {
        if (!_haveClock) { _offset = now - _queue.firstObject.pts + _delay; _haveClock = YES; }
        double t = now - _offset;                       // media time to show now
        double newest = _queue.lastObject.pts;
        if (newest - t > _delay + 0.4) {                 // fell far behind (stall): jump to live
            _offset = now - newest + _delay; t = now - _offset;
        }
        LCFrame *pick = nil;
        while (_queue.count && _queue.firstObject.pts <= t) { pick = _queue.firstObject; [_queue removeObjectAtIndex:0]; }
        if (pick) {
            CVPixelBufferRef old = _latest; _latest = CVPixelBufferRetain(pick.px); _seq++;
            if (old) CVPixelBufferRelease(old);
        }
    } else if (_haveClock && _latest && now - _offset > 0) {
        // ran dry: wait a little longer next time (smoother, slightly more delay), up to 0.5 s
        static double lastGrow = 0;
        if (now - lastGrow > 1.0 && _delay < 0.5) { _delay += 0.04; _offset += 0.04; lastGrow = now; }
    }
    CVPixelBufferRef px = _latest ? (CVPixelBufferRef)CVPixelBufferRetain(_latest) : NULL;
    if (seq) *seq = _seq;
    [_lock unlock];
    return px;
}

#pragma mark voice buffer (for the virtual mic)

- (void)appendAudio:(const int16_t *)s count:(NSUInteger)n {
    if (n == 0) return;
    [_audioLock lock];
    [_audio appendBytes:s length:n * 2];
    NSUInteger cap = 16000 * 2 * 2;                 // keep at most ~2 s
    if (_audio.length > cap) {
        NSUInteger drop = _audio.length - cap;
        uint8_t *buf = _audio.mutableBytes;
        memmove(buf, buf + drop, cap);
        _audio.length = cap;
    }
    _lastAudio = CACurrentMediaTime();
    [_audioLock unlock];
}

- (BOOL)audioActive {
    [_audioLock lock];
    BOOL on = (CACurrentMediaTime() - _lastAudio) < 2.0;
    [_audioLock unlock];
    return on;
}

// Resample the mono 16 kHz FIFO to `frames` samples at `rate`. YES if enough was buffered.
- (BOOL)pullAudio:(int16_t *)out frames:(int)frames rate:(double)rate {
    if (frames <= 0 || rate <= 0) return NO;
    double ratio = 16000.0 / rate;
    [_audioLock lock];
    NSUInteger have = _audio.length / 2;
    double endPos = _resPos + ratio * (frames - 1);
    if (have < (NSUInteger)ceil(endPos) + 2) {      // underflow (between words or not live)
        [_audioLock unlock];
        memset(out, 0, (size_t)frames * 2);
        return NO;
    }
    int16_t *src = (int16_t *)_audio.mutableBytes;
    double pos = _resPos;
    for (int j = 0; j < frames; j++) {
        NSUInteger i0 = (NSUInteger)pos;
        double frac = pos - (double)i0;
        int a = src[i0];
        int b = (i0 + 1 < have) ? src[i0 + 1] : a;
        out[j] = (int16_t)(a + (int)((b - a) * frac));
        pos += ratio;
    }
    NSUInteger consumed = (NSUInteger)pos;
    if (consumed > 0 && consumed <= have) {
        NSUInteger remain = have - consumed;
        memmove(src, src + consumed, remain * 2);
        _audio.length = remain * 2;
        _resPos = pos - (double)consumed;
    } else {
        _resPos = pos;
    }
    [_audioLock unlock];
    return YES;
}

@end

static void lcDecodeCB(void *outRef, void *srcRef, OSStatus status, VTDecodeInfoFlags flags,
                       CVImageBufferRef image, CMTime pts, CMTime dur) {
    if (status == noErr && image) [(__bridge LCFeed *)outRef storeFrame:image pts:pts];
}

#pragma mark - format conversion (match what the host app asked the camera for)

// WhatsApp/Zoom configure the camera output for a specific pixel format (usually NV12). Our decoder
// produces BGRA, so each substituted frame is converted to the format/size of the real frame it replaces,
// scaled aspect-fill. Without this the app's encoder gets a mismatched buffer and sends black/green.
static CIContext *gCI;
static CVPixelBufferPoolRef gPool;
static OSType gPF; static size_t gPW, gPH;
static NSLock *gConvLock;
static CVPixelBufferRef gPlaceholder; static NSString *gPlaceholderText; static NSLock *gPhLock;
static CVPixelBufferRef gConvCache; static uint64_t gCacheSeq; static OSType gCacheFmt; static size_t gCacheW, gCacheH; static CGFloat gCacheDeg; static NSLock *gCacheLock;

static CVPixelBufferRef LCConvert(CVPixelBufferRef src, OSType fmt, size_t w, size_t h, CGFloat rotateDeg) CF_RETURNS_RETAINED {
    if (w == 0 || h == 0) return NULL;
    if (!gConvLock) gConvLock = [NSLock new];
    [gConvLock lock];
    if (!gCI) gCI = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
    if (!gPool || gPF != fmt || gPW != w || gPH != h) {
        if (gPool) { CVPixelBufferPoolRelease(gPool); gPool = NULL; }
        NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
                                 (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                                 (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &gPool) != kCVReturnSuccess) { [gConvLock unlock]; return NULL; }
        gPF = fmt; gPW = w; gPH = h;
    }
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, gPool, &dst) != kCVReturnSuccess || !dst) { [gConvLock unlock]; return NULL; }
    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    if (rotateDeg != 0) {   // pre-rotate so the frame lands upright after the app/receiver rotates it back
        CGAffineTransform r = CGAffineTransformMakeRotation(rotateDeg * (CGFloat)M_PI / 180.0);
        img = [img imageByApplyingTransform:r];
        CGRect re = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-re.origin.x, -re.origin.y)];
    }
    size_t sw = (size_t)img.extent.size.width, sh = (size_t)img.extent.size.height;
    CGFloat scale = MAX((CGFloat)w / sw, (CGFloat)h / sh);                 // aspect-fill
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect e = img.extent;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x - (e.size.width - w) / 2,
                                                                         -e.origin.y - (e.size.height - h) / 2)];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [gCI render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, w, h) colorSpace:cs];
    CGColorSpaceRelease(cs);
    [gConvLock unlock];
    return dst;
}

// How much to pre-rotate so the substitute matches how the app will display the real camera.
static CGFloat LCRotationFor(AVCaptureConnection *conn, size_t w, size_t h) {
    CGFloat deg = 0;
    if (@available(iOS 17.0, *)) { if (conn) deg = conn.videoRotationAngle; }
    else if (conn && conn.isVideoOrientationSupported) {
        switch (conn.videoOrientation) {
            case AVCaptureVideoOrientationPortrait: deg = 90; break;
            case AVCaptureVideoOrientationPortraitUpsideDown: deg = 270; break;
            case AVCaptureVideoOrientationLandscapeLeft: deg = 180; break;
            default: deg = 0; break;   // landscapeRight
        }
    }
    if (deg == 0 && w > h) deg = 90;   // landscape buffer with no hint: assume the receiver rotates 90
    return 180 - deg;                  // cancel the app's rotation (was upside down at -deg)
}

// A black frame with the hook's status text — sent to the call when there is no live feed, so the
// outgoing video is always the hook (and never the real camera) even before you go live.
static CVPixelBufferRef LCMakeText(NSString *full, size_t w, size_t h) CF_RETURNS_RETAINED {
    NSDictionary *attrs = @{ (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                             (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                             (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8, CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
        CGContextSetRGBFillColor(ctx, 0, 0, 0, 1); CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
        CGContextSetRGBFillColor(ctx, 1.0, 0.36, 0.54, 1); CGContextFillEllipseInRect(ctx, CGRectMake(w / 2 - 16, h * 0.40, 32, 32));
        CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, 1, -1);     // flip to UIKit coords for text
        UIGraphicsPushContext(ctx);
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
        NSDictionary *ta = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:w * 0.06],
                              NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: ps };
        [full drawInRect:CGRectMake(20, h * 0.46, w - 40, h * 0.30) withAttributes:ta];
        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static CVPixelBufferRef LCPlaceholder(void) CF_RETURNS_RETAINED {
    if (!gPhLock) gPhLock = [NSLock new];
    NSString *full = [NSString stringWithFormat:@"LiveChar\n%@", LCFeed.shared.state ?: @"starting\u2026"];
    [gPhLock lock];
    if (!gPlaceholder || ![full isEqualToString:gPlaceholderText]) {
        if (gPlaceholder) { CVPixelBufferRelease(gPlaceholder); gPlaceholder = NULL; }
        gPlaceholder = LCMakeText(full, 720, 1280);
        gPlaceholderText = [full copy];
    }
    CVPixelBufferRef out = gPlaceholder ? (CVPixelBufferRef)CVPixelBufferRetain(gPlaceholder) : NULL;
    [gPhLock unlock];
    return out;
}

#pragma mark - helpers

// Wrap a pixel buffer as a CMSampleBuffer, reusing timing from `orig` when given.
static CMSampleBufferRef LCWrap(CVPixelBufferRef px, CMSampleBufferRef orig) {
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, px, &fmt) != noErr) return NULL;
    CMSampleTimingInfo timing;
    if (orig) { CMSampleBufferGetSampleTimingInfo(orig, 0, &timing); }
    else { timing.duration = kCMTimeInvalid; timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()); timing.decodeTimeStamp = kCMTimeInvalid; }
    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(NULL, px, fmt, &timing, &out);
    CFRelease(fmt);
    return st == noErr ? out : NULL;
}

static UIViewController *LCTopVC(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { key = w; break; }
            if (!key) key = ((UIWindowScene *)scene).windows.firstObject;
        }
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// Ask for the watch link once, then start the feed.
static void LCEnsureLink(void) {
    static BOOL asking = NO;
    [LCFeed.shared ensureRunning];   // same-phone feed needs no link
    if ([[NSUserDefaults standardUserDefaults] stringForKey:kLinkKey].length > 0) return;
    static BOOL askedOnce = NO;
    if (LCFeed.shared.localFails < 30 || askedOnce) return;   // ~30 s without LiveChar here; ask once per launch
    if (asking) return;
    askedOnce = YES;
    asking = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = LCTopVC();
        if (!top) { asking = NO; return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"LiveChar camera"
            message:@"LiveChar isn't live on this phone. Open LiveChar and press Go live (keep PiP on) \u2014 or paste your live link to use LiveChar from another device." preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.placeholder = @"https://…/watch/…"; f.keyboardType = UIKeyboardTypeURL;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo;
            NSString *clip = UIPasteboard.generalPasteboard.string;
            if ([clip containsString:@"/watch/"]) f.text = clip;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"Use" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *link = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (link.length) { [[NSUserDefaults standardUserDefaults] setObject:link forKey:kLinkKey]; [LCFeed.shared ensureRunning]; }
            asking = NO;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { asking = NO; }]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

static void LCSwizzle(Class cls, SEL a, SEL b) {
    Method ma = class_getInstanceMethod(cls, a), mb = class_getInstanceMethod(cls, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

#pragma mark - preview overlay (AVCaptureVideoPreviewLayer)

static const void *kDispKey = &kDispKey;
static const void *kTextKey = &kTextKey;
static NSHashTable *gPreviews;      // weak set of live preview layers
static CADisplayLink *gLink;

@interface LCDriver : NSObject
+ (void)tick;
@end
@implementation LCDriver
+ (void)tick {
    LCEnsureLink();
    CVPixelBufferRef px = [LCFeed.shared copyLatest];
    CMSampleBufferRef sb = NULL;
    if (px) {
        sb = LCWrap(px, NULL);
        CVPixelBufferRelease(px);
        if (sb) {
            CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, true);
            if (att && CFArrayGetCount(att)) {
                CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
                CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            }
        }
    }
    NSString *state = LCFeed.shared.state ?: @"starting\u2026";
    @synchronized (gPreviews) {
        for (AVCaptureVideoPreviewLayer *pl in gPreviews.allObjects) {
            AVSampleBufferDisplayLayer *disp = objc_getAssociatedObject(pl, kDispKey);
            CATextLayer *text = objc_getAssociatedObject(pl, kTextKey);
            if (!disp) {
                disp = [AVSampleBufferDisplayLayer layer];
                disp.videoGravity = AVLayerVideoGravityResizeAspectFill;
                disp.backgroundColor = [UIColor blackColor].CGColor;   // covers the real camera, so the hook is visibly active
                [pl addSublayer:disp];
                objc_setAssociatedObject(pl, kDispKey, disp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                text = [CATextLayer layer];
                text.fontSize = 15; text.alignmentMode = kCAAlignmentCenter; text.truncationMode = kCATruncationEnd;
                text.foregroundColor = [UIColor whiteColor].CGColor;
                text.contentsScale = UIScreen.mainScreen.scale;
                [pl addSublayer:text];
                objc_setAssociatedObject(pl, kTextKey, text, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            disp.frame = pl.bounds;
            text.frame = CGRectMake(8, pl.bounds.size.height / 2 - 12, pl.bounds.size.width - 16, 24);
            if (sb) {
                if (disp.status == AVQueuedSampleBufferRenderingStatusFailed) [disp flush];
                [disp enqueueSampleBuffer:sb];
                text.hidden = YES;
            } else {
                text.string = [NSString stringWithFormat:@"LiveChar hook \u2014 %@", state];
                text.hidden = NO;
            }
            [CATransaction commit];
        }
    }
    if (sb) CFRelease(sb);
}
@end

static void LCRegisterPreview(AVCaptureVideoPreviewLayer *pl) {
    if (!pl) return;
    @synchronized (gPreviews) { [gPreviews addObject:pl]; }
    LCEnsureLink();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLink) {
            gLink = [CADisplayLink displayLinkWithTarget:LCDriver.class selector:@selector(tick)];
            gLink.preferredFramesPerSecond = 30;
            [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }
    });
}

@interface AVCaptureVideoPreviewLayer (LiveChar)
@end
@implementation AVCaptureVideoPreviewLayer (LiveChar)
- (void)lc_setSession:(AVCaptureSession *)session { [self lc_setSession:session]; LCRegisterPreview(self); }
- (instancetype)lc_initWithSession:(AVCaptureSession *)session { id s = [self lc_initWithSession:session]; LCRegisterPreview(s); return s; }
@end

#pragma mark - frame delegate (AVCaptureVideoDataOutput / AVCaptureAudioDataOutput)

static SEL kCbSel;   // captureOutput:didOutputSampleBuffer:fromConnection:

// Overwrite a captured mic buffer in place with the transformed voice, matched to the app's audio format.
static void lc_fillAudio(CMSampleBufferRef sb) {
    if (![LCFeed.shared audioActive]) return;                 // not live: leave the real mic alone
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (!fd) return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM) return;
    CMItemCount frames = CMSampleBufferGetNumSamples(sb);
    if (frames <= 0) return;
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL nonInter = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bits = asbd->mBitsPerChannel;

    int16_t *mono = malloc(sizeof(int16_t) * (size_t)frames);
    if (!mono) return;
    [LCFeed.shared pullAudio:mono frames:(int)frames rate:asbd->mSampleRate];   // underflow -> silence (zeroed)

    CMBlockBufferRef bb = NULL;
    AudioBufferList abl;
    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, NULL, &abl, sizeof(abl),
                                                                          NULL, NULL, 0, &bb);
    if (st != noErr || !bb) { free(mono); return; }
    for (UInt32 bi = 0; bi < abl.mNumberBuffers; bi++) {
        void *dst = abl.mBuffers[bi].mData;
        UInt32 ch = abl.mBuffers[bi].mNumberChannels ?: 1;    // interleaved: all channels; planar: 1
        if (!dst) continue;
        for (CMItemCount f = 0; f < frames; f++) {
            int16_t v = mono[f];
            for (UInt32 c = 0; c < ch; c++) {
                size_t idx = nonInter ? (size_t)f : (size_t)f * ch + c;
                if (isFloat && bits == 32) ((float *)dst)[idx] = (float)v / 32768.0f;
                else if (!isFloat && bits == 16) ((int16_t *)dst)[idx] = v;
                else if (!isFloat && bits == 32) ((int32_t *)dst)[idx] = (int32_t)v << 16;
            }
        }
    }
    CFRelease(bb);
    free(mono);
}

static void lc_didOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {
    if ([output isKindOfClass:AVCaptureAudioDataOutput.class]) {
        lc_fillAudio(sb);
        void (*origA)(id, SEL, id, CMSampleBufferRef, id) = (__bridge void *)objc_getAssociatedObject([self class], kCbSel);
        if (origA) origA(self, _cmd, output, sb, conn);
        return;
    }
    LCEnsureLink();
    CVPixelBufferRef px = [LCFeed.shared copyLatest];
    void (*orig)(id, SEL, id, CMSampleBufferRef, id) = (__bridge void *)objc_getAssociatedObject([self class], kCbSel);
    if (px) {
        CVImageBufferRef ob = CMSampleBufferGetImageBuffer(sb);
        OSType fmt = ob ? CVPixelBufferGetPixelFormatType(ob) : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        size_t w = ob ? CVPixelBufferGetWidth(ob) : CVPixelBufferGetWidth(px);
        size_t h = ob ? CVPixelBufferGetHeight(ob) : CVPixelBufferGetHeight(px);
        CVPixelBufferRef conv = LCConvert(px, fmt, w, h, LCRotationFor(conn, w, h));
        CVPixelBufferRelease(px);
        if (conv) {
            CMSampleBufferRef nb = LCWrap(conv, sb);
            CVPixelBufferRelease(conv);
            if (nb) { if (orig) orig(self, _cmd, output, nb, conn); CFRelease(nb); return; }
        }
    } else {
        // no live feed: send the waiting panel, never the real camera
        CVImageBufferRef ob = CMSampleBufferGetImageBuffer(sb);
        OSType fmt = ob ? CVPixelBufferGetPixelFormatType(ob) : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        size_t w = ob ? CVPixelBufferGetWidth(ob) : 720, h = ob ? CVPixelBufferGetHeight(ob) : 1280;
        CVPixelBufferRef ph = LCPlaceholder();
        if (ph) {
            CVPixelBufferRef conv = LCConvert(ph, fmt, w, h, LCRotationFor(conn, w, h));
            CVPixelBufferRelease(ph);
            if (conv) {
                CMSampleBufferRef nb = LCWrap(conv, sb);
                CVPixelBufferRelease(conv);
                if (nb) { if (orig) orig(self, _cmd, output, nb, conn); CFRelease(nb); return; }
            }
        }
    }
    if (orig) orig(self, _cmd, output, sb, conn);
}

// Replace captureOutput:didOutputSampleBuffer:fromConnection: on a delegate's class (once).
static void LCHookDelegateClass(Class cls) {
    if (!cls) return;
    @synchronized (cls) {
        if (!objc_getAssociatedObject(cls, kCbSel)) {
            Method m = class_getInstanceMethod(cls, kCbSel);
            if (m) {
                IMP old = method_getImplementation(m);
                objc_setAssociatedObject(cls, kCbSel, (__bridge id)(void *)old, OBJC_ASSOCIATION_ASSIGN);
                class_replaceMethod(cls, kCbSel, (IMP)lc_didOutput, method_getTypeEncoding(m));
            } else {
                objc_setAssociatedObject(cls, kCbSel, (__bridge id)(void *)NULL, OBJC_ASSOCIATION_ASSIGN);
                class_addMethod(cls, kCbSel, (IMP)lc_didOutput, "v@:@@@");
            }
        }
    }
}

@interface AVCaptureVideoDataOutput (LiveChar)
@end
@implementation AVCaptureVideoDataOutput (LiveChar)
- (void)lc_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate) LCHookDelegateClass([delegate class]);
    [self lc_setSampleBufferDelegate:delegate queue:queue];
    LCEnsureLink();
}
@end

@interface AVCaptureAudioDataOutput (LiveChar)
@end
@implementation AVCaptureAudioDataOutput (LiveChar)
- (void)lc_setAudioSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate) LCHookDelegateClass([delegate class]);
    [self lc_setAudioSampleBufferDelegate:delegate queue:queue];   // swizzled: calls the real setter
    LCEnsureLink();
}
@end

#pragma mark - load

__attribute__((constructor))
static void LiveCharHookInit(void) {
    @autoreleasepool {
        gPreviews = [NSHashTable weakObjectsHashTable];
        kCbSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        LCSwizzle(AVCaptureVideoPreviewLayer.class, @selector(setSession:), @selector(lc_setSession:));
        LCSwizzle(AVCaptureVideoPreviewLayer.class, @selector(initWithSession:), @selector(lc_initWithSession:));
        LCSwizzle(AVCaptureVideoDataOutput.class, @selector(setSampleBufferDelegate:queue:), @selector(lc_setSampleBufferDelegate:queue:));
        LCSwizzle(AVCaptureAudioDataOutput.class, @selector(setSampleBufferDelegate:queue:), @selector(lc_setAudioSampleBufferDelegate:queue:));
        NSLog(@"[LiveCharHook] loaded");
    }
}
