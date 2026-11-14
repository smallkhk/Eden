// LiveCharHook — an eSign-injectable dylib that replaces the camera in the host app with a LiveChar
// live feed (https://server/watch/<id>).
//
//   * Hooks AVCaptureVideoDataOutput's frame delegate: apps that read camera frames get LiveChar frames.
//   * Overlays an AVSampleBufferDisplayLayer on every AVCaptureVideoPreviewLayer: the on-screen preview
//     shows LiveChar (this is what Cam Test shows).
//   * On the first camera use, asks for the watch link and remembers it (host app's NSUserDefaults,
//     key "livechar.hooklink"; or a Documents/livechar.txt file).
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
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kLinkKey = @"livechar.hooklink";

#pragma mark - feed (download + H.264 decode -> latest CVPixelBuffer)

@interface LCFeed : NSObject <NSURLSessionDataDelegate>
@property (class, readonly) LCFeed *shared;
- (void)ensureRunning;
- (CVPixelBufferRef)copyLatest CF_RETURNS_RETAINED;   // nil if nothing decoded yet
- (CVPixelBufferRef)copyLatestSeq:(uint64_t *)seq CF_RETURNS_RETAINED;
@property (atomic, copy) NSString *state;
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
    CVPixelBufferRef _latest;
    uint64_t _seq;
    NSLock *_lock;
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
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        c.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    }
    return self;
}

- (NSURL *)streamURL {
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
        NSURL *url = [self streamURL];
        if (!url) { self.state = @"paste your live link"; return; }
        _running = YES;
        self.state = @"connecting\u2026";
        _buf = [NSMutableData data];
        _task = [_session dataTaskWithURL:url];
        [_task resume];
    }
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t
                                     didReceiveResponse:(NSURLResponse *)resp
                                      completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
    NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
    if (code == 200) self.state = @"connected \u2014 waiting for LiveChar";
    else if (code == 404) self.state = @"link not found (update server / reset link)";
    else self.state = [NSString stringWithFormat:@"server error %ld", (long)code];
    done(code == 200 ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
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
    @synchronized (self) { _running = NO; }
    self.state = @"reconnecting\u2026";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        [self ensureRunning];
    });
}

- (void)packet:(const uint8_t *)p length:(NSUInteger)len {
    uint8_t flags = p[0];
    if (flags & 2) { _needKey = YES; return; }   // stream ended
    if (flags & 4) return;                        // audio — a camera has no sound
    BOOL key = (flags & 1) != 0;
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
    if (CMSampleBufferCreateReady(NULL, block, _format, 1, 0, NULL, 1, sizes, &sb) == noErr && sb) {
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

- (void)storeFrame:(CVImageBufferRef)image {
    if (!image) return;
    CVPixelBufferRef px = (CVPixelBufferRef)image;
    self.state = [NSString stringWithFormat:@"live %zu\u00d7%zu", CVPixelBufferGetWidth(px), CVPixelBufferGetHeight(px)];
    CVPixelBufferRetain(px);
    [_lock lock];
    CVPixelBufferRef old = _latest; _latest = px; _seq++;
    [_lock unlock];
    if (old) CVPixelBufferRelease(old);
}

- (CVPixelBufferRef)copyLatest {
    return [self copyLatestSeq:NULL];
}

- (CVPixelBufferRef)copyLatestSeq:(uint64_t *)seq {
    [_lock lock];
    CVPixelBufferRef px = _latest ? (CVPixelBufferRef)CVPixelBufferRetain(_latest) : NULL;
    if (seq) *seq = _seq;
    [_lock unlock];
    return px;
}

@end

static void lcDecodeCB(void *outRef, void *srcRef, OSStatus status, VTDecodeInfoFlags flags,
                       CVImageBufferRef image, CMTime pts, CMTime dur) {
    if (status == noErr && image) [(__bridge LCFeed *)outRef storeFrame:image];
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
    return -deg;                       // cancel the app's rotation
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
    if ([[NSUserDefaults standardUserDefaults] stringForKey:kLinkKey].length > 0) { [LCFeed.shared ensureRunning]; return; }
    if (asking) return;
    asking = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = LCTopVC();
        if (!top) { asking = NO; return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"LiveChar camera"
            message:@"Paste your LiveChar live link (from the app: Account → Live link). Turn on “Share live to my link” there." preferredStyle:UIAlertControllerStyleAlert];
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

#pragma mark - frame delegate (AVCaptureVideoDataOutput)

static SEL kCbSel;   // captureOutput:didOutputSampleBuffer:fromConnection:

static void lc_didOutput(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sb, AVCaptureConnection *conn) {
    LCEnsureLink();
    uint64_t seq = 0;
    CVPixelBufferRef px = [LCFeed.shared copyLatestSeq:&seq];
    void (*orig)(id, SEL, id, CMSampleBufferRef, id) = (__bridge void *)objc_getAssociatedObject([self class], kCbSel);
    if (px) {
        CVImageBufferRef ob = CMSampleBufferGetImageBuffer(sb);
        OSType fmt = ob ? CVPixelBufferGetPixelFormatType(ob) : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        size_t w = ob ? CVPixelBufferGetWidth(ob) : CVPixelBufferGetWidth(px);
        size_t h = ob ? CVPixelBufferGetHeight(ob) : CVPixelBufferGetHeight(px);
        CGFloat deg = LCRotationFor(conn, w, h);
        if (!gCacheLock) gCacheLock = [NSLock new];
        CVPixelBufferRef conv = NULL;
        [gCacheLock lock];
        if (gConvCache && gCacheSeq == seq && gCacheFmt == fmt && gCacheW == w && gCacheH == h && gCacheDeg == deg)
            conv = (CVPixelBufferRef)CVPixelBufferRetain(gConvCache);   // same decoded frame + geometry: reuse
        [gCacheLock unlock];
        if (!conv) {
            conv = LCConvert(px, fmt, w, h, deg);                       // new frame: convert once, then cache
            if (conv) {
                [gCacheLock lock];
                if (gConvCache) CVPixelBufferRelease(gConvCache);
                gConvCache = (CVPixelBufferRef)CVPixelBufferRetain(conv);
                gCacheSeq = seq; gCacheFmt = fmt; gCacheW = w; gCacheH = h; gCacheDeg = deg;
                [gCacheLock unlock];
            }
        }
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

@interface AVCaptureVideoDataOutput (LiveChar)
@end
@implementation AVCaptureVideoDataOutput (LiveChar)
- (void)lc_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate) {
        Class cls = [delegate class];
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
    [self lc_setSampleBufferDelegate:delegate queue:queue];
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
        NSLog(@"[LiveCharHook] loaded");
    }
}
