#pragma once

#include "XSCBase.h"
#include "XSCArchive.h"

/*
 XSCImageStore owns decoded comic pages on Linux:
   - Page-aligned mmap(MAP_PRIVATE | MAP_ANONYMOUS) pixel storage so off-screen
     cached pages can be marked MADV_FREE (reclaimable by Linux without swap).
   - Monochrome fast path (8-bit L8) and 32x32 chroma probe repacking visually
     grayscale manga from RGBA8 to L8 (4x memory reduction).
   - Native Linux codecs (libjpeg-turbo, libpng, libwebp, giflib, libtiff,
     built-in BMP, plus libavif/libheif when available) with EXIF 1..8 parsing.
   - Bounded LRU cache (12 entries / 64 MiB default), request coalescing,
     negative cache, and 4-lane priority pthread decode pool (1 lane reserved
     for visible demand).
 */

typedef struct XSCSizeF {
    float width;
    float height;
} XSCSizeF;

/// Decoded page backed by a page-aligned purgeable pixel buffer (L8 grayscale or RGBA8 color).
@interface XSCDecodedPage : XSCObject

@property (nonatomic, readonly) const uint8_t *pixels;
@property (nonatomic, readonly) size_t pixelWidth;
@property (nonatomic, readonly) size_t pixelHeight;
@property (nonatomic, readonly) size_t bytesPerRow;
@property (nonatomic, readonly) uint32_t exifOrientation; // 1..8
@property (nonatomic, readonly) bool isGrayscale;         // true = L8 (1 Bpp), false = RGBA8 (4 Bpp)
@property (nonatomic, readonly) size_t byteCount;
@property (nonatomic, readonly) bool isAnimatedGIF;
@property (nonatomic, readonly) size_t gifFrameCount;
@property (nonatomic, readonly) XSCOptData gifData;

/// Effective display dimensions after EXIF orientation (swaps width/height for orientations 5..8).
@property (nonatomic, readonly) XSCSizeF orientedPixelSize;

/// Returns RGBA8 pixel pointer for animated GIF frame `frameIndex` (same dimensions as page).
- (const uint8_t *)gifFramePixelsAtIndex:(size_t)frameIndex outDelayMs:(uint32_t *)outDelayMs;

/// Pins the page non-volatile before GPU upload/display. Returns false if purged.
- (bool)pinNonVolatile;

/// Marks the backing buffer volatile via madvise(MADV_FREE) for kernel reclaim under pressure.
- (void)markVolatile;

@end

typedef Optional(XSCDecodedPage *) XSCOptDecodedPage;
typedef void (^XSCPageCompletion)(XSCOptDecodedPage page, bool failed);

/// Bounded, purgeable, concurrent image decode store with a lock-protected synchronous fast path.
@interface XSCImageStore : XSCObject

@property (nonatomic, readonly) size_t maxEntryCount;
@property (nonatomic, readonly) size_t maxByteBudget;
@property (nonatomic, readonly) size_t currentEntryCount;
@property (nonatomic, readonly) size_t currentByteCount;

- (instancetype)init;
- (instancetype)initWithMaxEntryCount:(size_t)maxEntries maxByteBudget:(size_t)maxBytes;

/// Zero-hop synchronous cache lookup. Pins the returned page non-volatile.
/// Returns None on miss or if the page was purged.
- (XSCOptDecodedPage)cachedPageForBook:(XSCBook *)book index:(size_t)index;

/// Asynchronous decode request with coalescing and priority demand lane.
/// `completion` is ALWAYS invoked on the main queue via xsc_dispatch_main.
- (void)requestPageForBook:(XSCBook *)book
                     index:(size_t)index
                  priority:(bool)isVisible
                completion:(XSCPageCompletion)completion;

/// Marks cached entries outside `visibleIndices` volatile and prefetches `orderedIndices`.
- (void)updateRetentionAndPrefetchForBook:(XSCBook *)book
                           visibleIndices:(XSCIndexList *)visibleIndices
                           orderedIndices:(XSCIndexList *)orderedIndices;

/// Pre-decodes a single boundary page of an adjacent volume without evicting active visible pages.
- (void)prewarmPageForBook:(XSCBook *)book index:(size_t)index;

/// Cancels pending prefetch work and clears cached entries for books other than `keepBook` (or all if None).
- (void)resetKeepingBook:(XSCOptBook)keepBook;

/// Stops worker threads cleanly.
- (void)shutdown;

@end
