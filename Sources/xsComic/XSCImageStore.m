/*
 XSCImageStore.m — Bounded, purgeable, concurrent image decode cache.

 Architecture & Memory Strategy:
   1. Zero-hop synchronous fast path: `cachedPageForBook:index:` acquires an
      uncontended `os_unfair_lock`, pins the page's IOSurface non-volatile, and
      returns in ~100 ns on the calling thread (no actor/queue hop).
   2. Direct hardware decode: `CGImageSourceCreateImageAtIndex` hits AppleJPEG
      and native decoders directly (2.5x–3.5x faster than ImageIO's CPU
      thumbnailer on Apple Silicon), falling back to a 16,384 px thumbnail only
      when a source exceeds Metal's maximum texture dimension.
   3. 4x grayscale compression for manga: monochrome sources decode straight
      into 1 byte/pixel `'L008'` IOSurfaces. RGB sources (common for scanned
      manga saved as RGB JPEG/PNG) are drawn into `'BGRA'`, probed on a 32×32
      grid (~1 µs), and—when opaque and visually grayscale (`|R-G| <= 2`,
      `|G-B| <= 2`)—repacked via `vImageExtractChannel_ARGB8888` (~0.3 ms) into
      `'L008'`, freeing the 4x buffer immediately.
   4. Purgeable volatile memory: only visible pages stay `NonVolatile`. All
      cached off-screen pages are marked `kIOSurfacePurgeableVolatile` so macOS
      excludes them from `phys_footprint` (Activity Monitor RAM) and can reclaim
      them cleanly under pressure without swapping.
   5. Dual-semaphore concurrency gate: 4 total decode permits on a concurrent
      GCD queue, with prefetch capped at 3 permits so at least 1 lane is always
      immediately available for visible on-demand page turns.
 */

#import "XSCImageStore.h"

#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <os/lock.h>
#import <stdatomic.h>

static const NSUInteger kXSCDefaultMaxEntries = 12;
static const NSUInteger kXSCDefaultMaxBytes = 64u * 1024u * 1024u;
static const size_t kXSCMaxTextureDimension = 16384u;
static const uint32_t kXSCPixelFormatL008 = 'L008';
static const uint32_t kXSCPixelFormatBGRA = 'BGRA';

static inline uint64_t XSCPageCacheKey(uint64_t bookID, NSUInteger index) {
    return (bookID << 32) | ((uint64_t)index & 0xFFFFFFFFull);
}

/* Metal requires 64-byte row alignment for zero-copy IOSurface textures. */
static inline size_t XSCAlign64(size_t value) {
    return (value + 63u) & ~(size_t)63u;
}

static IOSurfaceRef _Nullable XSCCreateIOSurface(size_t width,
                                                 size_t height,
                                                 uint32_t pixelFormat,
                                                 size_t bytesPerElement,
                                                 size_t *outBytesPerRow) {
    if (width == 0 || height == 0 || width > kXSCMaxTextureDimension || height > kXSCMaxTextureDimension) {
        return NULL;
    }
    size_t bpr = XSCAlign64(width * bytesPerElement);
    size_t allocSize = bpr * height;
    NSDictionary *props = @{
        (__bridge NSString *)kIOSurfaceWidth: @(width),
        (__bridge NSString *)kIOSurfaceHeight: @(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @(bytesPerElement),
        (__bridge NSString *)kIOSurfaceBytesPerRow: @(bpr),
        (__bridge NSString *)kIOSurfaceAllocSize: @(allocSize),
        (__bridge NSString *)kIOSurfacePixelFormat: @(pixelFormat),
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (surf && outBytesPerRow) {
        *outBytesPerRow = bpr;
    }
    return surf;
}

/*
 Samples a 32×32 grid across a premultiplied BGRA8888 buffer (byte order B,G,R,A).
 Returns YES only if every sampled pixel is effectively opaque (A >= 253) and
 neutral (|R-G| <= 2 and |G-B| <= 2, allowing minor JPEG chroma rounding noise).
 */
static BOOL XSCProbeBGRAIsGrayscale(const uint8_t *base, size_t width, size_t height, size_t bytesPerRow) {
    size_t stepY = height > 32u ? height / 32u : 1u;
    size_t stepX = width > 32u ? width / 32u : 1u;
    for (size_t y = 0; y < height; y += stepY) {
        const uint8_t *row = base + y * bytesPerRow;
        for (size_t x = 0; x < width; x += stepX) {
            const uint8_t *p = row + x * 4u;
            int b = (int)p[0];
            int g = (int)p[1];
            int r = (int)p[2];
            int a = (int)p[3];
            if (a < 253 || abs(r - g) > 2 || abs(g - b) > 2) {
                return NO;
            }
        }
    }
    return YES;
}

#pragma mark - XSCDecodedPage

@implementation XSCDecodedPage

- (instancetype)initWithSurface:(IOSurfaceRef)surface
                     pixelWidth:(NSUInteger)pixelWidth
                    pixelHeight:(NSUInteger)pixelHeight
                exifOrientation:(uint32_t)exifOrientation
                    isGrayscale:(BOOL)isGrayscale
                      byteCount:(NSUInteger)byteCount
                  isAnimatedGIF:(BOOL)isAnimatedGIF
                        gifData:(nullable NSData *)gifData {
    self = [super init];
    if (self) {
        _surface = (IOSurfaceRef)CFRetain(surface);
        _pixelWidth = pixelWidth;
        _pixelHeight = pixelHeight;
        _exifOrientation = (exifOrientation >= 1u && exifOrientation <= 8u) ? exifOrientation : 1u;
        _isGrayscale = isGrayscale;
        _byteCount = byteCount;
        _isAnimatedGIF = isAnimatedGIF;
        _gifData = gifData;
    }
    return self;
}

- (void)dealloc {
    if (_surface) {
        CFRelease(_surface);
        _surface = NULL;
    }
}

- (CGSize)orientedPixelSize {
    if (_exifOrientation >= 5u && _exifOrientation <= 8u) {
        return CGSizeMake((CGFloat)_pixelHeight, (CGFloat)_pixelWidth);
    }
    return CGSizeMake((CGFloat)_pixelWidth, (CGFloat)_pixelHeight);
}

- (BOOL)pinNonVolatile {
    uint32_t oldState = kIOSurfacePurgeableNonVolatile;
    kern_return_t kr = IOSurfaceSetPurgeable(_surface, kIOSurfacePurgeableNonVolatile, &oldState);
    return kr == KERN_SUCCESS && oldState != kIOSurfacePurgeableEmpty;
}

- (void)markVolatile {
    IOSurfaceSetPurgeable(_surface, kIOSurfacePurgeableVolatile, NULL);
}

@end

/*
 Decodes raw encoded image bytes into an IOSurface-backed XSCDecodedPage.
 Every CoreFoundation / CoreGraphics / IOSurface object is strictly balanced
 inside the autoreleasepool so transient decode memory is reclaimed per page.
 */
static XSCDecodedPage * _Nullable XSCDecodePageData(NSData *data) {
    if (!data || data.length == 0) {
        return nil;
    }
    @autoreleasepool {
        NSDictionary *srcOpts = @{ (__bridge NSString *)kCGImageSourceShouldCache: @NO };
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)srcOpts);
        if (!src) {
            return nil;
        }
        size_t imageCount = CGImageSourceGetCount(src);
        if (imageCount == 0) {
            CFRelease(src);
            return nil;
        }

        uint32_t orientation = 1u;
        size_t propW = 0, propH = 0;
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
        if (props) {
            NSNumber *orientNum = CFDictionaryGetValue(props, kCGImagePropertyOrientation);
            if (orientNum) {
                uint32_t v = orientNum.unsignedIntValue;
                if (v >= 1u && v <= 8u) {
                    orientation = v;
                }
            }
            NSNumber *wNum = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
            NSNumber *hNum = CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
            propW = wNum ? wNum.unsignedIntegerValue : 0u;
            propH = hNum ? hNum.unsignedIntegerValue : 0u;
            CFRelease(props);
        }

        BOOL isAnimatedGIF = (imageCount > 1u);

        CGImageRef cg = NULL;
        if (propW > kXSCMaxTextureDimension || propH > kXSCMaxTextureDimension) {
            NSDictionary *thumbOpts = @{
                (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @NO,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(kXSCMaxTextureDimension),
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
            };
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)thumbOpts);
        } else {
            NSDictionary *imgOpts = @{
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
                (__bridge NSString *)kCGImageSourceShouldCache: @NO,
            };
            cg = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)imgOpts);
        }
        CFRelease(src);

        if (!cg) {
            return nil;
        }

        size_t w = CGImageGetWidth(cg);
        size_t h = CGImageGetHeight(cg);
        if (w == 0 || h == 0 || w > kXSCMaxTextureDimension || h > kXSCMaxTextureDimension) {
            CGImageRelease(cg);
            return nil;
        }

        /*
         Only take the direct 8-bit monochrome path when the source has no
         alpha channel. Grayscale+Alpha PNGs fall through to BGRA so
         transparency is preserved (or repacked to L008 if all pixels are opaque).
         */
        CGColorSpaceRef srcCS = CGImageGetColorSpace(cg);
        CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(cg);
        BOOL hasAlpha = (alphaInfo != kCGImageAlphaNone &&
                         alphaInfo != kCGImageAlphaNoneSkipLast &&
                         alphaInfo != kCGImageAlphaNoneSkipFirst);
        BOOL isOpaqueMonochrome = (srcCS != NULL &&
                                   CGColorSpaceGetModel(srcCS) == kCGColorSpaceModelMonochrome &&
                                   !hasAlpha);

        IOSurfaceRef finalSurface = NULL;
        BOOL finalGrayscale = NO;
        size_t finalByteCount = 0;

        if (isOpaqueMonochrome) {
            size_t bpr = 0;
            IOSurfaceRef graySurf = XSCCreateIOSurface(w, h, kXSCPixelFormatL008, 1u, &bpr);
            if (!graySurf) {
                CGImageRelease(cg);
                return nil;
            }
            if (IOSurfaceLock(graySurf, 0, NULL) != kIOReturnSuccess) {
                CFRelease(graySurf);
                CGImageRelease(cg);
                return nil;
            }
            CGColorSpaceRef grayCS = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
            if (!grayCS) {
                grayCS = CGColorSpaceCreateDeviceGray();
            }
            CGContextRef ctx = CGBitmapContextCreate(IOSurfaceGetBaseAddress(graySurf),
                                                     w, h, 8u, bpr, grayCS,
                                                     (CGBitmapInfo)kCGImageAlphaNone);
            CGColorSpaceRelease(grayCS);
            if (ctx) {
                CGContextSetBlendMode(ctx, kCGBlendModeCopy);
                CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, (CGFloat)w, (CGFloat)h), cg);
                CGContextRelease(ctx);
                IOSurfaceUnlock(graySurf, 0, NULL);
                finalSurface = graySurf;
                finalGrayscale = YES;
                finalByteCount = bpr * h;
            } else {
                IOSurfaceUnlock(graySurf, 0, NULL);
                CFRelease(graySurf);
            }
        } else {
            size_t bgraBpr = 0;
            IOSurfaceRef bgraSurf = XSCCreateIOSurface(w, h, kXSCPixelFormatBGRA, 4u, &bgraBpr);
            if (!bgraSurf) {
                CGImageRelease(cg);
                return nil;
            }
            if (IOSurfaceLock(bgraSurf, 0, NULL) != kIOReturnSuccess) {
                CFRelease(bgraSurf);
                CGImageRelease(cg);
                return nil;
            }
            CGColorSpaceRef rgbCS = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            if (!rgbCS) {
                rgbCS = CGColorSpaceCreateDeviceRGB();
            }
            CGBitmapInfo bmi = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little;
            void *bgraBase = IOSurfaceGetBaseAddress(bgraSurf);
            CGContextRef ctx = CGBitmapContextCreate(bgraBase, w, h, 8u, bgraBpr, rgbCS, bmi);
            CGColorSpaceRelease(rgbCS);
            if (!ctx) {
                IOSurfaceUnlock(bgraSurf, 0, NULL);
                CFRelease(bgraSurf);
                CGImageRelease(cg);
                return nil;
            }
            CGContextSetBlendMode(ctx, kCGBlendModeCopy);
            CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, (CGFloat)w, (CGFloat)h), cg);
            CGContextRelease(ctx);

            BOOL detectedGray = XSCProbeBGRAIsGrayscale((const uint8_t *)bgraBase, w, h, bgraBpr);
            if (detectedGray) {
                size_t grayBpr = 0;
                IOSurfaceRef graySurf = XSCCreateIOSurface(w, h, kXSCPixelFormatL008, 1u, &grayBpr);
                if (graySurf && IOSurfaceLock(graySurf, 0, NULL) == kIOReturnSuccess) {
                    /*
                     In memory, BGRA8888 is [B, G, R, A]; channel 1 is G.
                     vImage handles arbitrary widths and 64-byte padded strides cleanly.
                     */
                    vImage_Buffer srcBuf = {
                        .data = bgraBase,
                        .height = (vImagePixelCount)h,
                        .width = (vImagePixelCount)w,
                        .rowBytes = bgraBpr,
                    };
                    vImage_Buffer dstBuf = {
                        .data = IOSurfaceGetBaseAddress(graySurf),
                        .height = (vImagePixelCount)h,
                        .width = (vImagePixelCount)w,
                        .rowBytes = grayBpr,
                    };
                    vImage_Error err = vImageExtractChannel_ARGB8888(&srcBuf, &dstBuf, 1, kvImageNoFlags);
                    IOSurfaceUnlock(graySurf, 0, NULL);
                    if (err == kvImageNoError) {
                        IOSurfaceUnlock(bgraSurf, 0, NULL);
                        CFRelease(bgraSurf);
                        finalSurface = graySurf;
                        finalGrayscale = YES;
                        finalByteCount = grayBpr * h;
                    } else {
                        CFRelease(graySurf);
                        IOSurfaceUnlock(bgraSurf, 0, NULL);
                        finalSurface = bgraSurf;
                        finalGrayscale = NO;
                        finalByteCount = bgraBpr * h;
                    }
                } else {
                    if (graySurf) {
                        CFRelease(graySurf);
                    }
                    IOSurfaceUnlock(bgraSurf, 0, NULL);
                    finalSurface = bgraSurf;
                    finalGrayscale = NO;
                    finalByteCount = bgraBpr * h;
                }
            } else {
                IOSurfaceUnlock(bgraSurf, 0, NULL);
                finalSurface = bgraSurf;
                finalGrayscale = NO;
                finalByteCount = bgraBpr * h;
            }
        }

        CGImageRelease(cg);
        if (!finalSurface) {
            return nil;
        }

        NSUInteger accountedBytes = finalByteCount + (isAnimatedGIF ? data.length : 0u);
        XSCDecodedPage *page = [[XSCDecodedPage alloc] initWithSurface:finalSurface
                                                            pixelWidth:w
                                                           pixelHeight:h
                                                       exifOrientation:orientation
                                                           isGrayscale:finalGrayscale
                                                             byteCount:accountedBytes
                                                         isAnimatedGIF:isAnimatedGIF
                                                               gifData:(isAnimatedGIF ? data : nil)];
        CFRelease(finalSurface);
        return page;
    }
}

#pragma mark - Cache Entry & Pending State

@interface XSCCacheEntry : NSObject
@property (nonatomic, strong) XSCDecodedPage *page;
@property (nonatomic, assign) uint64_t bookID;
@property (nonatomic, assign) NSUInteger rank;
@property (nonatomic, assign) uint64_t lastAccessSeq;
@end

@implementation XSCCacheEntry
@end

typedef void (^XSCPageCompletion)(XSCDecodedPage * _Nullable page, BOOL failed);

@interface XSCPendingDecode : NSObject
@property (nonatomic, strong) NSMutableArray<XSCPageCompletion> *completions;
@property (nonatomic, assign) BOOL isVisible;
@property (nonatomic, assign) NSUInteger rank;
@end

@implementation XSCPendingDecode
- (instancetype)init {
    self = [super init];
    if (self) {
        _completions = [NSMutableArray array];
    }
    return self;
}
@end

#pragma mark - XSCImageStore

@implementation XSCImageStore {
    os_unfair_lock _lock;
    NSMutableDictionary<NSNumber *, XSCCacheEntry *> *_cache;
    NSMutableSet<NSNumber *> *_failedKeys;
    NSMutableDictionary<NSNumber *, XSCPendingDecode *> *_pending;
    NSMutableDictionary<NSNumber *, NSNumber *> *_retentionRanks;
    uint64_t _accessSeq;
    NSUInteger _currentByteCount;
    uint64_t _resetGeneration;
    uint64_t _keptBookID;

    dispatch_queue_t _decodeQueue;
    dispatch_semaphore_t _totalDecodeSem;    // 4 permits total
    dispatch_semaphore_t _prefetchDecodeSem; // 3 permits max for prefetch (1 always reserved for visible demand)
    _Atomic(uint64_t) _prefetchGeneration;
}

- (instancetype)init {
    return [self initWithMaxEntryCount:kXSCDefaultMaxEntries maxByteBudget:kXSCDefaultMaxBytes];
}

- (instancetype)initWithMaxEntryCount:(NSUInteger)maxEntries maxByteBudget:(NSUInteger)maxBytes {
    self = [super init];
    if (self) {
        _maxEntryCount = maxEntries > 0 ? maxEntries : kXSCDefaultMaxEntries;
        _maxByteBudget = maxBytes > 0 ? maxBytes : kXSCDefaultMaxBytes;
        _lock = OS_UNFAIR_LOCK_INIT;
        _cache = [NSMutableDictionary dictionaryWithCapacity:_maxEntryCount + 2u];
        _failedKeys = [NSMutableSet setWithCapacity:_maxEntryCount];
        _pending = [NSMutableDictionary dictionaryWithCapacity:8u];
        _retentionRanks = [NSMutableDictionary dictionaryWithCapacity:_maxEntryCount + 2u];
        _decodeQueue = dispatch_queue_create("xscomic.decode", DISPATCH_QUEUE_CONCURRENT);
        _totalDecodeSem = dispatch_semaphore_create(4);
        _prefetchDecodeSem = dispatch_semaphore_create(3);
        atomic_init(&_prefetchGeneration, 0);
    }
    return self;
}

- (NSUInteger)currentEntryCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _cache.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (NSUInteger)currentByteCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger bytes = _currentByteCount;
    os_unfair_lock_unlock(&_lock);
    return bytes;
}

- (nullable XSCDecodedPage *)cachedPageForBook:(XSCBook *)book index:(NSUInteger)index {
    if (!book || index >= book.pageCount) {
        return nil;
    }
    NSNumber *key = @(XSCPageCacheKey(book.bookID, index));
    os_unfair_lock_lock(&_lock);
    XSCCacheEntry *entry = _cache[key];
    if (!entry) {
        os_unfair_lock_unlock(&_lock);
        return nil;
    }
    if (![entry.page pinNonVolatile]) {
        _currentByteCount -= entry.page.byteCount;
        [_cache removeObjectForKey:key];
        os_unfair_lock_unlock(&_lock);
        return nil;
    }
    entry.lastAccessSeq = ++_accessSeq;
    XSCDecodedPage *page = entry.page;
    os_unfair_lock_unlock(&_lock);
    return page;
}

- (void)requestPageForBook:(XSCBook *)book
                     index:(NSUInteger)index
                  priority:(BOOL)isVisible
                completion:(void (^)(XSCDecodedPage * _Nullable page, BOOL failed))completion {
    if (!book || index >= book.pageCount) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, YES); });
        }
        return;
    }

    NSNumber *key = @(XSCPageCacheKey(book.bookID, index));
    os_unfair_lock_lock(&_lock);

    // 1. Check cache hit
    XSCCacheEntry *hit = _cache[key];
    if (hit) {
        if ([hit.page pinNonVolatile]) {
            hit.lastAccessSeq = ++_accessSeq;
            if (isVisible) {
                hit.rank = 0;
            }
            XSCDecodedPage *page = hit.page;
            os_unfair_lock_unlock(&_lock);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(page, NO); });
            }
            return;
        } else {
            _currentByteCount -= hit.page.byteCount;
            [_cache removeObjectForKey:key];
        }
    }

    // 2. Check negative cache
    if ([_failedKeys containsObject:key]) {
        os_unfair_lock_unlock(&_lock);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, YES); });
        }
        return;
    }

    // 3. Coalesce with in-flight decode
    XSCPendingDecode *existing = _pending[key];
    if (existing) {
        if (completion) {
            [existing.completions addObject:[completion copy]];
        }
        if (isVisible) {
            existing.isVisible = YES;
            existing.rank = 0;
        }
        os_unfair_lock_unlock(&_lock);
        return;
    }

    // 4. Start new decode
    XSCPendingDecode *pending = [[XSCPendingDecode alloc] init];
    pending.isVisible = isVisible;
    NSNumber *rankNum = _retentionRanks[key];
    pending.rank = isVisible ? 0u : (rankNum ? rankNum.unsignedIntegerValue : NSUIntegerMax);
    if (completion) {
        [pending.completions addObject:[completion copy]];
    }
    _pending[key] = pending;
    uint64_t expectedGen = atomic_load_explicit(&_prefetchGeneration, memory_order_relaxed);
    uint64_t resetGen = _resetGeneration;
    os_unfair_lock_unlock(&_lock);

    [self dispatchDecodeForBook:book
                          index:index
                            key:key
                      isVisible:isVisible
                    prefetchGen:expectedGen
                       resetGen:resetGen
                      isPrewarm:NO];
}

- (void)dispatchDecodeForBook:(XSCBook *)book
                        index:(NSUInteger)index
                          key:(NSNumber *)key
                    isVisible:(BOOL)isVisible
                  prefetchGen:(uint64_t)expectedGen
                     resetGen:(uint64_t)resetGen
                    isPrewarm:(BOOL)isPrewarm {
    qos_class_t qos = isVisible ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
    dispatch_block_t work = dispatch_block_create_with_qos_class(0, qos, 0, ^{
        if (!isVisible && !isPrewarm) {
            if (atomic_load_explicit(&self->_prefetchGeneration, memory_order_relaxed) != expectedGen) {
                [self finishDecodeForKey:key bookID:book.bookID page:nil cancelled:YES resetGen:resetGen isPrewarm:isPrewarm];
                return;
            }
            dispatch_semaphore_wait(self->_prefetchDecodeSem, DISPATCH_TIME_FOREVER);
            if (atomic_load_explicit(&self->_prefetchGeneration, memory_order_relaxed) != expectedGen) {
                dispatch_semaphore_signal(self->_prefetchDecodeSem);
                [self finishDecodeForKey:key bookID:book.bookID page:nil cancelled:YES resetGen:resetGen isPrewarm:isPrewarm];
                return;
            }
        } else if (isPrewarm) {
            dispatch_semaphore_wait(self->_prefetchDecodeSem, DISPATCH_TIME_FOREVER);
        }

        dispatch_semaphore_wait(self->_totalDecodeSem, DISPATCH_TIME_FOREVER);

        XSCDecodedPage *decoded = nil;
        BOOL cancelled = NO;
        if (!isVisible && !isPrewarm && atomic_load_explicit(&self->_prefetchGeneration, memory_order_relaxed) != expectedGen) {
            cancelled = YES;
        } else {
            @autoreleasepool {
                NSData *rawData = [book copyPageDataAtIndex:index error:NULL];
                if (rawData) {
                    decoded = XSCDecodePageData(rawData);
                }
            }
        }

        dispatch_semaphore_signal(self->_totalDecodeSem);
        if (!isVisible) {
            dispatch_semaphore_signal(self->_prefetchDecodeSem);
        }

        [self finishDecodeForKey:key bookID:book.bookID page:decoded cancelled:cancelled resetGen:resetGen isPrewarm:isPrewarm];
    });
    dispatch_async(_decodeQueue, work);
}

- (void)finishDecodeForKey:(NSNumber *)key
                    bookID:(uint64_t)bookID
                      page:(nullable XSCDecodedPage *)page
                 cancelled:(BOOL)cancelled
                  resetGen:(uint64_t)resetGen
                 isPrewarm:(BOOL)isPrewarm {
    os_unfair_lock_lock(&_lock);
    XSCPendingDecode *pending = _pending[key];
    [_pending removeObjectForKey:key];

    /*
     If resetKeepingBook: ran while this decode was in flight and dropped this
     bookID, discard the stale result rather than repopulating the cache.
     */
    BOOL staleBook = (resetGen != _resetGeneration) && (_keptBookID == 0ull || bookID != _keptBookID);
    BOOL effectiveCancelled = cancelled || staleBook;

    if (page && !effectiveCancelled) {
        NSNumber *rankNum = _retentionRanks[key];
        NSUInteger rank;
        BOOL keepPinned = NO;
        if (pending && pending.isVisible) {
            rank = 0u;
            keepPinned = YES;
        } else if (rankNum) {
            rank = rankNum.unsignedIntegerValue;
            keepPinned = (rank == 0u);
        } else if (isPrewarm) {
            rank = 1000u;
            keepPinned = NO;
        } else {
            rank = NSUIntegerMax;
            keepPinned = NO;
        }

        if (!keepPinned) {
            [page markVolatile];
        }
        [self lockedInsertPage:page forKey:key bookID:bookID rank:rank];
    } else if (!page && !effectiveCancelled) {
        if (_failedKeys.count >= _maxEntryCount) {
            NSNumber *anyKey = [_failedKeys anyObject];
            if (anyKey) {
                [_failedKeys removeObject:anyKey];
            }
        }
        [_failedKeys addObject:key];
    }

    NSArray<XSCPageCompletion> *completions = pending.completions;
    os_unfair_lock_unlock(&_lock);

    if (completions.count > 0) {
        XSCDecodedPage *deliverPage = effectiveCancelled ? nil : page;
        BOOL failed = (deliverPage == nil && !effectiveCancelled);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (XSCPageCompletion block in completions) {
                block(deliverPage, failed);
            }
        });
    }
}

- (void)lockedInsertPage:(XSCDecodedPage *)page
                  forKey:(NSNumber *)key
                  bookID:(uint64_t)bookID
                    rank:(NSUInteger)incomingRank {
    if (page.byteCount > _maxByteBudget) {
        return;
    }

    XSCCacheEntry *existing = _cache[key];
    if (existing) {
        _currentByteCount -= existing.page.byteCount;
        [_cache removeObjectForKey:key];
    }

    while (_cache.count >= _maxEntryCount || _currentByteCount + page.byteCount > _maxByteBudget) {
        NSNumber *victimKey = [self lockedEvictionVictimForIncomingRank:incomingRank];
        if (!victimKey) {
            return;
        }
        XSCCacheEntry *victim = _cache[victimKey];
        _currentByteCount -= victim.page.byteCount;
        [_cache removeObjectForKey:victimKey];
    }

    XSCCacheEntry *entry = [[XSCCacheEntry alloc] init];
    entry.page = page;
    entry.bookID = bookID;
    entry.rank = incomingRank;
    entry.lastAccessSeq = ++_accessSeq;
    _cache[key] = entry;
    _currentByteCount += page.byteCount;
}

/*
 Retention-aware LRU victim selection: lower rank is more valuable (0 = visible).
 Evicts the highest-rank (least useful) entry, breaking ties by oldest access.
 Admission control refuses eviction if every resident outranks the incoming page.
 */
- (nullable NSNumber *)lockedEvictionVictimForIncomingRank:(NSUInteger)incomingRank {
    NSNumber *victimKey = nil;
    NSUInteger worstRank = 0;
    uint64_t oldestSeq = UINT64_MAX;

    for (NSNumber *candidateKey in _cache) {
        XSCCacheEntry *entry = _cache[candidateKey];
        if (!victimKey || entry.rank > worstRank || (entry.rank == worstRank && entry.lastAccessSeq < oldestSeq)) {
            victimKey = candidateKey;
            worstRank = entry.rank;
            oldestSeq = entry.lastAccessSeq;
        }
    }

    if (!victimKey || worstRank < incomingRank) {
        return nil;
    }
    return victimKey;
}

- (void)updateRetentionAndPrefetchForBook:(XSCBook *)book
                           visibleIndices:(NSIndexSet *)visibleIndices
                           orderedIndices:(NSArray<NSNumber *> *)orderedIndices {
    if (!book) {
        return;
    }

    uint64_t gen = atomic_fetch_add_explicit(&_prefetchGeneration, 1u, memory_order_relaxed) + 1u;
    NSMutableArray<NSNumber *> *toPrefetch = [NSMutableArray arrayWithCapacity:orderedIndices.count];
    uint64_t resetGen = 0;

    os_unfair_lock_lock(&_lock);
    resetGen = _resetGeneration;
    [_retentionRanks removeAllObjects];

    NSMutableSet<NSNumber *> *visibleKeys = [NSMutableSet setWithCapacity:visibleIndices.count];
    [visibleIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        (void)stop;
        NSNumber *k = @(XSCPageCacheKey(book.bookID, idx));
        [visibleKeys addObject:k];
        self->_retentionRanks[k] = @0;
    }];

    NSUInteger rank = 1u;
    for (NSNumber *idxNum in orderedIndices) {
        NSUInteger idx = idxNum.unsignedIntegerValue;
        if (idx >= book.pageCount) {
            continue;
        }
        NSNumber *k = @(XSCPageCacheKey(book.bookID, idx));
        if (!self->_retentionRanks[k]) {
            self->_retentionRanks[k] = @(rank);
        }
        rank++;
    }

    // Update retention ranks and purgeable states across cached entries.
    NSMutableArray<NSNumber *> *purgedVisibleKeys = nil;
    for (NSNumber *k in _cache) {
        XSCCacheEntry *entry = _cache[k];
        NSNumber *newRank = _retentionRanks[k];
        if (newRank) {
            entry.rank = newRank.unsignedIntegerValue;
        } else if (entry.bookID != book.bookID) {
            // Keep prewarmed adjacent-volume pages below active window but evictable.
            entry.rank = 1000u;
        } else {
            entry.rank = NSUIntegerMax;
        }

        if ([visibleKeys containsObject:k]) {
            if (![entry.page pinNonVolatile]) {
                if (!purgedVisibleKeys) {
                    purgedVisibleKeys = [NSMutableArray array];
                }
                [purgedVisibleKeys addObject:k];
            }
        } else {
            [entry.page markVolatile];
        }
    }
    for (NSNumber *pk in purgedVisibleKeys) {
        XSCCacheEntry *removed = _cache[pk];
        if (removed) {
            _currentByteCount -= removed.page.byteCount;
            [_cache removeObjectForKey:pk];
        }
    }

    // Register missing prefetch targets before releasing the lock to prevent duplicates.
    for (NSNumber *idxNum in orderedIndices) {
        NSUInteger idx = idxNum.unsignedIntegerValue;
        if (idx >= book.pageCount) {
            continue;
        }
        NSNumber *k = @(XSCPageCacheKey(book.bookID, idx));
        if (_cache[k] || [_failedKeys containsObject:k] || _pending[k]) {
            continue;
        }
        XSCPendingDecode *pending = [[XSCPendingDecode alloc] init];
        pending.isVisible = NO;
        pending.rank = _retentionRanks[k] ? _retentionRanks[k].unsignedIntegerValue : NSUIntegerMax;
        _pending[k] = pending;
        [toPrefetch addObject:idxNum];
    }
    os_unfair_lock_unlock(&_lock);

    for (NSNumber *idxNum in toPrefetch) {
        NSUInteger idx = idxNum.unsignedIntegerValue;
        NSNumber *k = @(XSCPageCacheKey(book.bookID, idx));
        [self dispatchDecodeForBook:book
                              index:idx
                                key:k
                          isVisible:NO
                        prefetchGen:gen
                           resetGen:resetGen
                          isPrewarm:NO];
    }
}

- (void)prewarmPageForBook:(XSCBook *)book index:(NSUInteger)index {
    if (!book || index >= book.pageCount) {
        return;
    }
    NSNumber *key = @(XSCPageCacheKey(book.bookID, index));
    os_unfair_lock_lock(&_lock);
    if (_cache[key] || [_failedKeys containsObject:key] || _pending[key]) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    XSCPendingDecode *pending = [[XSCPendingDecode alloc] init];
    pending.isVisible = NO;
    pending.rank = 1000u;
    _pending[key] = pending;
    uint64_t gen = atomic_load_explicit(&_prefetchGeneration, memory_order_relaxed);
    uint64_t resetGen = _resetGeneration;
    os_unfair_lock_unlock(&_lock);

    [self dispatchDecodeForBook:book
                          index:index
                            key:key
                      isVisible:NO
                    prefetchGen:gen
                       resetGen:resetGen
                      isPrewarm:YES];
}

- (void)resetKeepingBook:(nullable XSCBook *)keepBook {
    atomic_fetch_add_explicit(&_prefetchGeneration, 1u, memory_order_relaxed);
    uint64_t keepID = keepBook ? keepBook.bookID : 0ull;

    os_unfair_lock_lock(&_lock);
    _resetGeneration++;
    _keptBookID = keepID;
    if (!keepBook) {
        [_cache removeAllObjects];
        [_failedKeys removeAllObjects];
        [_retentionRanks removeAllObjects];
        _currentByteCount = 0u;
    } else {
        NSMutableArray<NSNumber *> *dropKeys = [NSMutableArray array];
        for (NSNumber *k in _cache) {
            if (_cache[k].bookID != keepID) {
                [dropKeys addObject:k];
            }
        }
        for (NSNumber *k in dropKeys) {
            _currentByteCount -= _cache[k].page.byteCount;
            [_cache removeObjectForKey:k];
        }
        NSMutableArray<NSNumber *> *dropFailed = [NSMutableArray array];
        for (NSNumber *k in _failedKeys) {
            if ((k.unsignedLongLongValue >> 32) != keepID) {
                [dropFailed addObject:k];
            }
        }
        for (NSNumber *k in dropFailed) {
            [_failedKeys removeObject:k];
        }
    }
    os_unfair_lock_unlock(&_lock);
}

@end
