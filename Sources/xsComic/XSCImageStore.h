#pragma once

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import "XSCArchive.h"

NS_ASSUME_NONNULL_BEGIN

/// Decoded page backed by a unified-memory IOSurface (either 8-bit Gray 'L008' or 32-bit 'BGRA').
/// Off-screen cached pages are marked purgeableVolatile so macOS does not count them as dirty RAM.
@interface XSCDecodedPage : NSObject

@property (nonatomic, readonly) IOSurfaceRef surface;
@property (nonatomic, readonly) NSUInteger pixelWidth;
@property (nonatomic, readonly) NSUInteger pixelHeight;
@property (nonatomic, readonly) uint32_t exifOrientation; // 1..8
@property (nonatomic, readonly) BOOL isGrayscale;
@property (nonatomic, readonly) NSUInteger byteCount;
@property (nonatomic, readonly) BOOL isAnimatedGIF;
@property (nonatomic, readonly, nullable) NSData *gifData;

/// Effective display dimensions after EXIF orientation (swaps width/height for orientations 5..8).
@property (nonatomic, readonly) CGSize orientedPixelSize;

/// Pins the IOSurface non-volatile before GPU/display use. Returns NO if the OS purged its contents.
- (BOOL)pinNonVolatile;

/// Marks the IOSurface volatile so the kernel can reclaim it under memory pressure (0 dirty footprint).
- (void)markVolatile;

@end

/// Bounded, purgeable, concurrent image decode store with a lock-protected synchronous cache-hit fast path.
@interface XSCImageStore : NSObject

@property (nonatomic, readonly) NSUInteger maxEntryCount;
@property (nonatomic, readonly) NSUInteger maxByteBudget;
@property (nonatomic, readonly) NSUInteger currentEntryCount;
@property (nonatomic, readonly) NSUInteger currentByteCount;

- (instancetype)init;
- (instancetype)initWithMaxEntryCount:(NSUInteger)maxEntries maxByteBudget:(NSUInteger)maxBytes;

/// Zero-hop synchronous cache lookup (~100 ns). Pins the returned page non-volatile.
/// Returns nil on miss or if the kernel purged the surface.
- (nullable XSCDecodedPage *)cachedPageForBook:(XSCBook *)book index:(NSUInteger)index;

/// Asynchronous decode request with coalescing and priority demand lane.
/// `completion` is ALWAYS invoked on the main queue.
- (void)requestPageForBook:(XSCBook *)book
                     index:(NSUInteger)index
                  priority:(BOOL)isVisible
                completion:(void (^)(XSCDecodedPage * _Nullable page, BOOL failed))completion;

/// Marks all currently cached entries EXCEPT those in `visibleIndices` (for `book`) as volatile,
/// and concurrently prefetches `orderedIndices` across background decode lanes.
- (void)updateRetentionAndPrefetchForBook:(XSCBook *)book
                           visibleIndices:(NSIndexSet *)visibleIndices
                           orderedIndices:(NSArray<NSNumber *> *)orderedIndices;

/// Pre-decodes a single boundary page of an adjacent volume without evicting the active book's visible pages.
- (void)prewarmPageForBook:(XSCBook *)book index:(NSUInteger)index;

/// Cancels pending prefetch work and clears cached entries for books other than `keepBook` (or all if nil).
- (void)resetKeepingBook:(nullable XSCBook *)keepBook;

@end

NS_ASSUME_NONNULL_END
