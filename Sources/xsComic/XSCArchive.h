#pragma once

#import <Foundation/Foundation.h>
#include <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

/*
 XSCArchive owns the boundary between xsComic and the host filesystem/archives.

 Design principles:
   1. Zero third-party dependencies — only POSIX, Apple libcompression (-lcompression),
      and the macOS system libarchive (-larchive) are used.
   2. Zero upfront disk extraction for CBZ/ZIP and CBT/TAR — opening parses only
      the Central Directory or 512-byte TAR headers via stateless pread(2), so
      even a 500-page 128 MiB volume opens in ~1 ms with zero disk writes.
   3. In-process streaming for CBR/RAR4/RAR5/CB7/7z — avoids spawning /usr/bin/bsdtar
      and keeps archives <= 256 MiB in RAM, spilling larger archives to a private
      per-process temp directory cleaned by both dealloc and atexit(3).
   4. Immutable, lock-free thread safety — once +openURL:cancelFlag:error: returns
      an XSCBook, its entry table and byte arena never mutate, and copyPageDataAtIndex:
      may be called concurrently from any number of decode threads.
 */

extern NSErrorDomain const XSCArchiveErrorDomain;

typedef NS_ENUM(NSInteger, XSCArchiveErrorCode) {
    XSCArchiveErrorMissingFile = 1,
    XSCArchiveErrorUnsupportedFormat = 2,
    XSCArchiveErrorNoImages = 3,
    XSCArchiveErrorCorruptArchive = 4,
    XSCArchiveErrorUnsafePath = 5,
    XSCArchiveErrorEncrypted = 6,
    XSCArchiveErrorCancelled = 7,
    XSCArchiveErrorIOFailure = 8,
};

/// Immutable, thread-safe representation of an opened comic book (directory, CBZ, CBT, CBR, CB7).
/// CBZ and CBT use zero-extraction random-access `pread`; CBR/CB7 use in-process `libarchive`.
@interface XSCBook : NSObject

@property (nonatomic, readonly) NSURL *sourceURL;
@property (nonatomic, readonly) NSString *displayTitle;
@property (nonatomic, readonly) NSUInteger pageCount;
/// Process-wide monotonically increasing identifier used as part of cache keys in XSCImageStore.
@property (nonatomic, readonly) uint64_t bookID;

+ (BOOL)isSupportedArchiveExtension:(NSString *)ext;
+ (BOOL)isSupportedImageExtension:(NSString *)ext;

/// Zero-allocation ASCII-fast natural comparison ("2" before "10", case-insensitive,
/// with deterministic raw-byte tie-breaking). Falls back to CFString localized numeric
/// comparison automatically whenever either operand contains a non-ASCII UTF-8 byte (>= 0x80).
+ (NSComparisonResult)naturalCompareBytes:(const char *)a
                                   length:(size_t)aLen
                                withBytes:(const char *)b
                                   length:(size_t)bLen;

/// Opens a directory or archive file. Safe to call off the main thread.
/// If `cancelFlag` becomes true, aborts promptly with `XSCArchiveErrorCancelled`.
+ (nullable instancetype)openURL:(NSURL *)url
                      cancelFlag:(nullable const _Atomic(bool) *)cancelFlag
                           error:(NSError * _Nullable * _Nullable)error;

/// Finds the next (+1) or previous (-1) readable sibling archive or image directory in natural order.
/// Archive siblings are accepted by extension without opening them; directory siblings are probed
/// recursively until the first readable image is found (skipping hidden items and packages).
+ (nullable NSURL *)adjacentVolumeURLFor:(NSURL *)currentURL
                                    step:(NSInteger)step
                              cancelFlag:(nullable const _Atomic(bool) *)cancelFlag;

/// Returns the display name (relative path or filename) of page at `index`.
- (NSString *)pageNameAtIndex:(NSUInteger)index;

/// Returns YES if the page at `index` has a `.gif` extension.
- (BOOL)isGIFAtIndex:(NSUInteger)index;

/// Thread-safe random-access read of raw encoded image bytes for page `index`.
/// Safe to call concurrently from background decode queues without external locking.
- (nullable NSData *)copyPageDataAtIndex:(NSUInteger)index
                                   error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
