#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <compression.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "XSCArchive.h"
#import "XSCImageStore.h"
#import "XSCReaderModel.h"

static int gPassCount = 0;
static int gFailCount = 0;

#define XSC_ASSERT(cond, fmt, ...)                                                   \
    do {                                                                             \
        if (cond) {                                                                  \
            gPassCount++;                                                            \
        } else {                                                                     \
            gFailCount++;                                                            \
            fprintf(stderr, "  [FAIL] %s:%d: " fmt "\n", __func__, __LINE__,         \
                    ##__VA_ARGS__);                                                  \
        }                                                                            \
    } while (0)

static double nowMilliseconds(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1e6;
}

static uint64_t currentPhysFootprintBytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return info.phys_footprint;
    }
    return 0;
}

// MARK: - Synthetic Image & Archive Generators

static NSData *makeSyntheticImageData(size_t w, size_t h, BOOL grayscaleRGB, CFStringRef uti) {
    size_t bpr = w * 4;
    uint8_t *buf = calloc(h, bpr);
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            uint8_t *px = buf + y * bpr + x * 4;
            uint8_t v = (uint8_t)((x + y) & 0xFF);
            if (grayscaleRGB) {
                px[0] = v; px[1] = v; px[2] = v; px[3] = 255;
            } else {
                px[0] = (uint8_t)((x * 3) & 0xFF);
                px[1] = (uint8_t)((y * 5) & 0xFF);
                px[2] = (uint8_t)(((x ^ y) * 7) & 0xFF);
                px[3] = 255;
            }
        }
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, bpr, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                 uti, 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(buf);
    return out;
}

static NSData *makeAnimatedGIFData(size_t w, size_t h) {
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, (__bridge CFStringRef)UTTypeGIF.identifier, 2, NULL);
    NSDictionary *gifProps = @{
        (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
            (__bridge NSString *)kCGImagePropertyGIFLoopCount: @0
        }
    };
    CGImageDestinationSetProperties(dst, (__bridge CFDictionaryRef)gifProps);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    for (int f = 0; f < 2; f++) {
        uint8_t *buf = calloc(w * h, 4);
        for (size_t i = 0; i < w * h; i++) {
            buf[i * 4 + 0] = (f == 0) ? 200 : 40;
            buf[i * 4 + 1] = (f == 0) ? 40 : 200;
            buf[i * 4 + 2] = 100;
            buf[i * 4 + 3] = 255;
        }
        CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        NSDictionary *frameProps = @{
            (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                (__bridge NSString *)kCGImagePropertyGIFDelayTime: @0.1
            }
        };
        CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)frameProps);
        CGImageRelease(img);
        CGContextRelease(ctx);
        free(buf);
    }
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGColorSpaceRelease(cs);
    return out;
}

static uint32_t crc32Bytes(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(crc & 1u)));
        }
    }
    return ~crc;
}

static void appendU16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF) };
    [d appendBytes:b length:2];
}
static void appendU32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = {
        (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
        (uint8_t)((v >> 16) & 0xFF), (uint8_t)((v >> 24) & 0xFF)
    };
    [d appendBytes:b length:4];
}
static void appendU64(NSMutableData *d, uint64_t v) {
    appendU32(d, (uint32_t)(v & 0xFFFFFFFFu));
    appendU32(d, (uint32_t)(v >> 32));
}

typedef struct {
    const char *name;
    NSData *payload;
    BOOL deflate;
    BOOL isSymlink;
    uint64_t overrideUncompressedSize; // 0 => use payload.length
} TestZipEntry;

static BOOL writeTestZIP(NSString *path, const TestZipEntry *entries, size_t count, BOOL forceZip64) {
    NSMutableData *archive = [NSMutableData data];
    NSMutableData *central = [NSMutableData data];

    for (size_t i = 0; i < count; i++) {
        const TestZipEntry *e = &entries[i];
        NSData *raw = e->payload ?: [NSData data];
        NSData *comp = raw;
        uint16_t method = 0;
        if (e->deflate && raw.length > 0) {
            size_t cap = raw.length + 1024;
            uint8_t *dst = malloc(cap);
            size_t cLen = compression_encode_buffer(dst, cap, raw.bytes, raw.length,
                                                    NULL, COMPRESSION_ZLIB);
            if (cLen > 0) {
                comp = [NSData dataWithBytesNoCopy:dst length:cLen freeWhenDone:YES];
                method = 8;
            } else {
                free(dst);
            }
        }
        uint32_t crc = crc32Bytes(raw.bytes, raw.length);
        uint64_t uncompSize = e->overrideUncompressedSize ? e->overrideUncompressedSize : (uint64_t)raw.length;
        uint64_t compSize = (uint64_t)comp.length;
        uint64_t lfhOffset = (uint64_t)archive.length;
        size_t nameLen = strlen(e->name);

        BOOL useZ64Entry = forceZip64 || uncompSize >= 0xFFFFFFFFu || compSize >= 0xFFFFFFFFu;
        NSMutableData *extraLFH = [NSMutableData data];
        NSMutableData *extraCD = [NSMutableData data];
        if (useZ64Entry) {
            appendU16(extraLFH, 0x0001);
            appendU16(extraLFH, 16);
            appendU64(extraLFH, uncompSize);
            appendU64(extraLFH, compSize);

            appendU16(extraCD, 0x0001);
            appendU16(extraCD, 24);
            appendU64(extraCD, uncompSize);
            appendU64(extraCD, compSize);
            appendU64(extraCD, lfhOffset);
        }

        // Local file header
        appendU32(archive, 0x04034b50u);
        appendU16(archive, useZ64Entry ? 45 : 20);
        appendU16(archive, 0);
        appendU16(archive, method);
        appendU16(archive, 0);
        appendU16(archive, 0);
        appendU32(archive, crc);
        appendU32(archive, useZ64Entry ? 0xFFFFFFFFu : (uint32_t)compSize);
        appendU32(archive, useZ64Entry ? 0xFFFFFFFFu : (uint32_t)uncompSize);
        appendU16(archive, (uint16_t)nameLen);
        appendU16(archive, (uint16_t)extraLFH.length);
        [archive appendBytes:e->name length:nameLen];
        [archive appendData:extraLFH];
        [archive appendData:comp];

        // Central directory header
        appendU32(central, 0x02014b50u);
        appendU16(central, (3u << 8) | (useZ64Entry ? 45u : 20u)); // Unix creator
        appendU16(central, useZ64Entry ? 45 : 20);
        appendU16(central, 0);
        appendU16(central, method);
        appendU16(central, 0);
        appendU16(central, 0);
        appendU32(central, crc);
        appendU32(central, useZ64Entry ? 0xFFFFFFFFu : (uint32_t)compSize);
        appendU32(central, useZ64Entry ? 0xFFFFFFFFu : (uint32_t)uncompSize);
        appendU16(central, (uint16_t)nameLen);
        appendU16(central, (uint16_t)extraCD.length);
        appendU16(central, 0);
        appendU16(central, 0);
        appendU16(central, 0);
        uint32_t extAttr = e->isSymlink ? (0120777u << 16) : (0100644u << 16);
        appendU32(central, extAttr);
        appendU32(central, useZ64Entry ? 0xFFFFFFFFu : (uint32_t)lfhOffset);
        [central appendBytes:e->name length:nameLen];
        [central appendData:extraCD];
    }

    uint64_t cdOffset = (uint64_t)archive.length;
    uint64_t cdSize = (uint64_t)central.length;
    [archive appendData:central];

    if (forceZip64) {
        uint64_t z64EocdOffset = (uint64_t)archive.length;
        // Zip64 EOCD
        appendU32(archive, 0x06064b50u);
        appendU64(archive, 44);
        appendU16(archive, 45);
        appendU16(archive, 45);
        appendU32(archive, 0);
        appendU32(archive, 0);
        appendU64(archive, (uint64_t)count);
        appendU64(archive, (uint64_t)count);
        appendU64(archive, cdSize);
        appendU64(archive, cdOffset);
        // Zip64 EOCD Locator
        appendU32(archive, 0x07064b50u);
        appendU32(archive, 0);
        appendU64(archive, z64EocdOffset);
        appendU32(archive, 1);
    }

    // Classic EOCD
    appendU32(archive, 0x06054b50u);
    appendU16(archive, 0);
    appendU16(archive, 0);
    appendU16(archive, forceZip64 ? 0xFFFFu : (uint16_t)count);
    appendU16(archive, forceZip64 ? 0xFFFFu : (uint16_t)count);
    appendU32(archive, forceZip64 ? 0xFFFFFFFFu : (uint32_t)cdSize);
    appendU32(archive, forceZip64 ? 0xFFFFFFFFu : (uint32_t)cdOffset);
    appendU16(archive, 0);

    return [archive writeToFile:path atomically:YES];
}

static BOOL runCommand(NSString *launchPath, NSArray<NSString *> *args) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:launchPath];
    t.arguments = args;
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) return NO;
    [t waitUntilExit];
    return t.terminationStatus == 0;
}

// MARK: - Delegate Helper

@interface TestReaderDelegate : NSObject <XSCReaderModelDelegate>
@property (nonatomic) NSUInteger stateUpdates;
@property (nonatomic) NSUInteger displayUpdates;
@property (nonatomic, strong, nullable) XSCDecodedPage *lastLeft;
@property (nonatomic, strong, nullable) XSCDecodedPage *lastRight;
@property (nonatomic) BOOL lastShowEmpty;
@property (nonatomic) BOOL lastLoading;
@end

@implementation TestReaderDelegate
- (void)readerModelDidUpdateState:(XSCReaderModel *)model {
    (void)model;
    self.stateUpdates++;
}
- (void)readerModel:(XSCReaderModel *)model
    displayLeftPage:(XSCDecodedPage *)leftPage
          rightPage:(XSCDecodedPage *)rightPage
       showEmptyCTA:(BOOL)showEmptyCTA
          isLoading:(BOOL)isLoading
         statusText:(NSString *)statusText {
    (void)model;
    (void)statusText;
    self.displayUpdates++;
    self.lastLeft = leftPage;
    self.lastRight = rightPage;
    self.lastShowEmpty = showEmptyCTA;
    self.lastLoading = isLoading;
}
@end

// MARK: - Unit Tests

static void testExtensionsAndNaturalSort(void) {
    printf("[TEST] Extensions & Natural Sort\n");
    XSC_ASSERT([XSCBook isSupportedArchiveExtension:@"cbz"], "cbz supported");
    XSC_ASSERT([XSCBook isSupportedArchiveExtension:@"CB7"], "CB7 case-insensitive");
    XSC_ASSERT([XSCBook isSupportedArchiveExtension:@"cbt"], "cbt supported");
    XSC_ASSERT([XSCBook isSupportedArchiveExtension:@"cbr"], "cbr supported");
    XSC_ASSERT(![XSCBook isSupportedArchiveExtension:@"pdf"], "pdf not archive");
    XSC_ASSERT([XSCBook isSupportedImageExtension:@"png"], "png supported");
    XSC_ASSERT([XSCBook isSupportedImageExtension:@"WEBP"], "WEBP supported");
    XSC_ASSERT([XSCBook isSupportedImageExtension:@"gif"], "gif supported");
    XSC_ASSERT(![XSCBook isSupportedImageExtension:@"txt"], "txt not image");

    const char *a = "page2.png", *b = "page10.png";
    XSC_ASSERT([XSCBook naturalCompareBytes:a length:strlen(a) withBytes:b length:strlen(b)] == NSOrderedAscending,
               "page2 < page10");
    XSC_ASSERT([XSCBook naturalCompareBytes:b length:strlen(b) withBytes:a length:strlen(a)] == NSOrderedDescending,
               "page10 > page2");
    const char *u1 = "\xe7\xac\xac""2\xe8\xa9\xb1.png";
    const char *u2 = "\xe7\xac\xac""10\xe8\xa9\xb1.png";
    XSC_ASSERT([XSCBook naturalCompareBytes:u1 length:strlen(u1) withBytes:u2 length:strlen(u2)] == NSOrderedAscending,
               "UTF-8 natural sort works");
}

static void testCBZStoreDeflateZip64Security(NSString *tmpDir, NSData *png1, NSData *png2) {
    printf("[TEST] CBZ STORE, DEFLATE, Zip64, Security\n");

    // 1. STORE + DEFLATE + natural ordering
    NSString *cbzPath = [tmpDir stringByAppendingPathComponent:@"mixed.cbz"];
    TestZipEntry entries[] = {
        { "ch1/page10.png", png2, YES, NO, 0 },
        { "ch1/page2.png", png1, NO, NO, 0 },
        { "__MACOSX/._page2.png", png1, NO, NO, 0 },
        { "notes.txt", [@"hello" dataUsingEncoding:NSUTF8StringEncoding], NO, NO, 0 },
    };
    XSC_ASSERT(writeTestZIP(cbzPath, entries, 4, NO), "write mixed.cbz");

    NSError *err = nil;
    XSCBook *book = [XSCBook openURL:[NSURL fileURLWithPath:cbzPath] cancelFlag:NULL error:&err];
    XSC_ASSERT(book != nil && err == nil, "open mixed.cbz failed: %s", err.localizedDescription.UTF8String ?: "");
    XSC_ASSERT(book.pageCount == 2, "expected 2 pages, got %lu", (unsigned long)book.pageCount);
    XSC_ASSERT([[book pageNameAtIndex:0] hasSuffix:@"page2.png"], "natural sort page 0");
    XSC_ASSERT([[book pageNameAtIndex:1] hasSuffix:@"page10.png"], "natural sort page 1");
    NSData *d0 = [book copyPageDataAtIndex:0 error:&err];
    NSData *d1 = [book copyPageDataAtIndex:1 error:&err];
    XSC_ASSERT([d0 isEqualToData:png1], "STORE payload matches byte-for-byte");
    XSC_ASSERT([d1 isEqualToData:png2], "DEFLATE payload matches byte-for-byte");

    // 2. Zip64
    NSString *z64Path = [tmpDir stringByAppendingPathComponent:@"zip64.cbz"];
    TestZipEntry z64Entries[] = {
        { "001.png", png1, YES, NO, 0 },
        { "002.png", png2, NO, NO, 0 },
    };
    XSC_ASSERT(writeTestZIP(z64Path, z64Entries, 2, YES), "write zip64.cbz");
    XSCBook *z64Book = [XSCBook openURL:[NSURL fileURLWithPath:z64Path] cancelFlag:NULL error:&err];
    XSC_ASSERT(z64Book != nil && z64Book.pageCount == 2, "open zip64.cbz failed: %s", err.localizedDescription.UTF8String ?: "");
    XSC_ASSERT([[z64Book copyPageDataAtIndex:0 error:&err] isEqualToData:png1], "Zip64 DEFLATE read matches");

    // 3. Path traversal rejected
    NSString *travPath = [tmpDir stringByAppendingPathComponent:@"traversal.cbz"];
    TestZipEntry travEntries[] = { { "../evil.png", png1, NO, NO, 0 } };
    writeTestZIP(travPath, travEntries, 1, NO);
    err = nil;
    XSCBook *travBook = [XSCBook openURL:[NSURL fileURLWithPath:travPath] cancelFlag:NULL error:&err];
    XSC_ASSERT(travBook == nil, "path traversal archive must be rejected");

    // 4. Symlink entry skipped / rejected
    NSString *symPath = [tmpDir stringByAppendingPathComponent:@"symlink.cbz"];
    TestZipEntry symEntries[] = {
        { "link.png", [@"/etc/passwd" dataUsingEncoding:NSUTF8StringEncoding], NO, YES, 0 }
    };
    writeTestZIP(symPath, symEntries, 1, NO);
    err = nil;
    XSCBook *symBook = [XSCBook openURL:[NSURL fileURLWithPath:symPath] cancelFlag:NULL error:&err];
    XSC_ASSERT(symBook == nil, "symlink-only archive must have 0 valid images");

    // 5. Zip bomb (2 GiB declared uncompressed size)
    NSString *bombPath = [tmpDir stringByAppendingPathComponent:@"bomb.cbz"];
    TestZipEntry bombEntries[] = {
        { "bomb.png", png1, YES, NO, (uint64_t)2ULL * 1024ULL * 1024ULL * 1024ULL }
    };
    writeTestZIP(bombPath, bombEntries, 1, YES);
    err = nil;
    XSCBook *bombBook = [XSCBook openURL:[NSURL fileURLWithPath:bombPath] cancelFlag:NULL error:&err];
    if (bombBook != nil && bombBook.pageCount > 0) {
        NSData *bombData = [bombBook copyPageDataAtIndex:0 error:&err];
        XSC_ASSERT(bombData == nil, "zip bomb read must be rejected");
    } else {
        XSC_ASSERT(bombBook == nil, "zip bomb rejected at open");
    }
}

static void testCBTAndCB7(NSString *tmpDir, NSData *png1, NSData *png2) {
    printf("[TEST] CBT (tar) & CB7 (libarchive 7z)\n");
    NSString *stage = [tmpDir stringByAppendingPathComponent:@"tarstage"];
    [[NSFileManager defaultManager] createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];
    [png2 writeToFile:[stage stringByAppendingPathComponent:@"page10.png"] atomically:YES];
    [png1 writeToFile:[stage stringByAppendingPathComponent:@"page2.png"] atomically:YES];

    NSString *cbtPath = [tmpDir stringByAppendingPathComponent:@"sample.cbt"];
    XSC_ASSERT(runCommand(@"/usr/bin/bsdtar", @[@"-cf", cbtPath, @"--format", @"ustar", @"-C", stage, @"page10.png", @"page2.png"]),
               "create sample.cbt");
    NSError *err = nil;
    XSCBook *cbt = [XSCBook openURL:[NSURL fileURLWithPath:cbtPath] cancelFlag:NULL error:&err];
    XSC_ASSERT(cbt != nil && cbt.pageCount == 2, "open sample.cbt failed: %s", err.localizedDescription.UTF8String ?: "");
    XSC_ASSERT([[cbt copyPageDataAtIndex:0 error:&err] isEqualToData:png1], "CBT page 0 matches");
    XSC_ASSERT([[cbt copyPageDataAtIndex:1 error:&err] isEqualToData:png2], "CBT page 1 matches");

    NSString *cb7Path = [tmpDir stringByAppendingPathComponent:@"sample.cb7"];
    XSC_ASSERT(runCommand(@"/usr/bin/bsdtar", @[@"-cf", cb7Path, @"--format", @"7zip", @"-C", stage, @"page10.png", @"page2.png"]),
               "create sample.cb7");
    err = nil;
    XSCBook *cb7 = [XSCBook openURL:[NSURL fileURLWithPath:cb7Path] cancelFlag:NULL error:&err];
    XSC_ASSERT(cb7 != nil && cb7.pageCount == 2, "open sample.cb7 failed: %s", err.localizedDescription.UTF8String ?: "");
    XSC_ASSERT([[cb7 copyPageDataAtIndex:0 error:&err] isEqualToData:png1], "CB7 page 0 matches");
    XSC_ASSERT([[cb7 copyPageDataAtIndex:1 error:&err] isEqualToData:png2], "CB7 page 1 matches");
}

static void testDirectoryAndAdjacentVolumes(NSString *tmpDir, NSData *png1, NSData *png2) {
    printf("[TEST] Directory Scan, Symlink Escape, Cancellation & Adjacent Volumes\n");
    NSString *outsideFile = [tmpDir stringByAppendingPathComponent:@"outside.png"];
    [png1 writeToFile:outsideFile atomically:YES];

    NSString *dir = [tmpDir stringByAppendingPathComponent:@"dirbook"];
    NSString *sub = [dir stringByAppendingPathComponent:@"sub"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
    [png1 writeToFile:[dir stringByAppendingPathComponent:@"02.png"] atomically:YES];
    [png2 writeToFile:[sub stringByAppendingPathComponent:@"10.png"] atomically:YES];
    symlink(outsideFile.fileSystemRepresentation,
            [[dir stringByAppendingPathComponent:@"01_escape.png"] fileSystemRepresentation]);

    NSError *err = nil;
    XSCBook *book = [XSCBook openURL:[NSURL fileURLWithPath:dir] cancelFlag:NULL error:&err];
    XSC_ASSERT(book != nil && book.pageCount == 2, "dirbook has 2 safe pages (symlink skipped), got %lu",
               (unsigned long)book.pageCount);

    _Atomic(bool) cancelled = true;
    err = nil;
    XSCBook *cBook = [XSCBook openURL:[NSURL fileURLWithPath:dir] cancelFlag:&cancelled error:&err];
    XSC_ASSERT(cBook == nil && err.code == XSCArchiveErrorCancelled, "pre-cancelled open aborts");

    // Adjacent volumes
    NSString *seriesDir = [tmpDir stringByAppendingPathComponent:@"series"];
    [[NSFileManager defaultManager] createDirectoryAtPath:seriesDir withIntermediateDirectories:YES attributes:nil error:nil];
    TestZipEntry e[] = { { "p1.png", png1, NO, NO, 0 } };
    NSString *v1 = [seriesDir stringByAppendingPathComponent:@"vol1.cbz"];
    NSString *v2 = [seriesDir stringByAppendingPathComponent:@"vol2.cbz"];
    NSString *v10 = [seriesDir stringByAppendingPathComponent:@"vol10.cbz"];
    writeTestZIP(v1, e, 1, NO);
    writeTestZIP(v2, e, 1, NO);
    writeTestZIP(v10, e, 1, NO);
    [@"readme" writeToFile:[seriesDir stringByAppendingPathComponent:@"readme.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSURL *next = [XSCBook adjacentVolumeURLFor:[NSURL fileURLWithPath:v2] step:1 cancelFlag:NULL];
    NSURL *prev = [XSCBook adjacentVolumeURLFor:[NSURL fileURLWithPath:v2] step:-1 cancelFlag:NULL];
    NSURL *pastEnd = [XSCBook adjacentVolumeURLFor:[NSURL fileURLWithPath:v10] step:1 cancelFlag:NULL];
    XSC_ASSERT([next.lastPathComponent isEqualToString:@"vol10.cbz"], "next volume after vol2 is vol10");
    XSC_ASSERT([prev.lastPathComponent isEqualToString:@"vol1.cbz"], "prev volume before vol2 is vol1");
    XSC_ASSERT(pastEnd == nil, "no volume after vol10");
}

static void testReaderModelAndPredictor(NSString *tmpDir, NSData *png1) {
    printf("[TEST] ReaderModel Spread/RTL/LTR/Predictor/Jump\n");
    NSArray<NSNumber *> *fwd = [XSCReaderModel prefetchOrderForCurrentIndex:5 pageCount:20
                                                                   pageMode:XSCPageModeSingle
                                                   consecutiveBackwardTurns:0];
    XSC_ASSERT(fwd.count > 0 && fwd[0].unsignedIntegerValue == 6, "forward predictor starts at +1 (6)");

    NSArray<NSNumber *> *bwd = [XSCReaderModel prefetchOrderForCurrentIndex:10 pageCount:20
                                                                   pageMode:XSCPageModeSingle
                                                   consecutiveBackwardTurns:2];
    XSC_ASSERT(bwd.count > 0 && bwd[0].unsignedIntegerValue == 9, "2-turn backward predictor flips to -1 (9)");

    // Build a 6-page CBZ
    NSString *cbz = [tmpDir stringByAppendingPathComponent:@"nav.cbz"];
    TestZipEntry entries[6];
    char names[6][16];
    for (int i = 0; i < 6; i++) {
        snprintf(names[i], sizeof(names[i]), "p%02d.png", i + 1);
        entries[i] = (TestZipEntry){ names[i], png1, NO, NO, 0 };
    }
    writeTestZIP(cbz, entries, 6, NO);

    XSCImageStore *store = [[XSCImageStore alloc] initWithMaxEntryCount:12 maxByteBudget:32 * 1024 * 1024];
    XSCReaderModel *model = [[XSCReaderModel alloc] initWithImageStore:store];
    TestReaderDelegate *del = [[TestReaderDelegate alloc] init];
    model.delegate = del;

    [model openURL:[NSURL fileURLWithPath:cbz]];
    // Pump run loop until book loads
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (model.book == nil && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XSC_ASSERT(model.book != nil && model.book.pageCount == 6, "model opened 6-page book");
    XSC_ASSERT(model.currentIndex == 0, "starts at index 0");

    // Jump math
    XSC_ASSERT([model jumpToOneBasedPageNumber:3], "jump to page 3 succeeds");
    XSC_ASSERT(model.currentIndex == 2, "index is 2 after jump to 3");
    XSC_ASSERT(![model jumpToOneBasedPageNumber:0], "jump to 0 rejected");
    XSC_ASSERT(![model jumpToOneBasedPageNumber:99], "jump to 99 rejected");

    // Double-page LTR vs RTL visual order
    [model togglePageMode]; // Single -> Double
    XSC_ASSERT(model.pageMode == XSCPageModeDouble, "toggled to double mode");
    NSArray<NSNumber *> *ltrVis = model.visualPageIndices;
    XSC_ASSERT(ltrVis.count == 2 && ltrVis[0].unsignedIntegerValue < ltrVis[1].unsignedIntegerValue,
               "LTR double visual order is ascending");
    [model toggleDirection]; // LTR -> RTL
    XSC_ASSERT(model.direction == XSCReadingDirectionRTL, "toggled to RTL");
    NSArray<NSNumber *> *rtlVis = model.visualPageIndices;
    XSC_ASSERT(rtlVis.count == 2 && rtlVis[0].unsignedIntegerValue > rtlVis[1].unsignedIntegerValue,
               "RTL double visual order is reversed (right page on left)");
}

static void testImageStoreCachePurgeableGrayGIF(NSString *tmpDir) {
    printf("[TEST] XSCImageStore Cache, Purgeable IOSurface, Gray8 Repack, Coalescing & GIF\n");
    NSData *grayRGBPng = makeSyntheticImageData(256, 256, YES, (__bridge CFStringRef)UTTypePNG.identifier);
    NSData *colorPng = makeSyntheticImageData(256, 256, NO, (__bridge CFStringRef)UTTypePNG.identifier);
    NSData *gifData = makeAnimatedGIFData(64, 64);

    NSString *cbz = [tmpDir stringByAppendingPathComponent:@"imgstore.cbz"];
    TestZipEntry entries[] = {
        { "01_gray.png", grayRGBPng, NO, NO, 0 },
        { "02_color.png", colorPng, NO, NO, 0 },
        { "03_anim.gif", gifData, NO, NO, 0 },
        { "04_extra.png", colorPng, NO, NO, 0 },
    };
    writeTestZIP(cbz, entries, 4, NO);

    NSError *err = nil;
    XSCBook *book = [XSCBook openURL:[NSURL fileURLWithPath:cbz] cancelFlag:NULL error:&err];
    XSC_ASSERT(book != nil && book.pageCount == 4, "open imgstore.cbz");

    XSCImageStore *store = [[XSCImageStore alloc] initWithMaxEntryCount:3 maxByteBudget:64 * 1024 * 1024];

    // Coalescing + Gray8 repack
    __block int callbacks = 0;
    __block BOOL allOnMain = YES;
    __block XSCDecodedPage *grayPage = nil;
    for (int i = 0; i < 3; i++) {
        [store requestPageForBook:book index:0 priority:YES completion:^(XSCDecodedPage *page, BOOL failed) {
            if (![NSThread isMainThread]) allOnMain = NO;
            if (!failed && page) grayPage = page;
            callbacks++;
        }];
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (callbacks < 3 && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    XSC_ASSERT(callbacks == 3 && allOnMain, "coalesced requests all completed on main thread");
    XSC_ASSERT(grayPage != nil && grayPage.isGrayscale, "RGB-encoded grayscale PNG repacked to Gray8");
    XSC_ASSERT(grayPage.pixelWidth == 256 && grayPage.pixelHeight == 256, "grayPage dimensions 256x256");

    // Color PNG
    __block XSCDecodedPage *colorPage = nil;
    __block BOOL doneColor = NO;
    [store requestPageForBook:book index:1 priority:YES completion:^(XSCDecodedPage *page, BOOL failed) {
        (void)failed;
        colorPage = page;
        doneColor = YES;
    }];
    deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!doneColor && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    XSC_ASSERT(colorPage != nil && !colorPage.isGrayscale, "color PNG stays BGRA");

    // Animated GIF
    __block XSCDecodedPage *gifPage = nil;
    __block BOOL doneGif = NO;
    [store requestPageForBook:book index:2 priority:YES completion:^(XSCDecodedPage *page, BOOL failed) {
        (void)failed;
        gifPage = page;
        doneGif = YES;
    }];
    deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!doneGif && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    XSC_ASSERT(gifPage != nil && gifPage.isAnimatedGIF && gifPage.gifData.length > 0, "animated GIF detected");

    // Bounded eviction (maxEntryCount = 3, requesting 4th evicts 1)
    __block BOOL doneExtra = NO;
    [store requestPageForBook:book index:3 priority:YES completion:^(XSCDecodedPage *page, BOOL failed) {
        (void)page; (void)failed;
        doneExtra = YES;
    }];
    deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!doneExtra && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    XSC_ASSERT(store.currentEntryCount <= 3, "cache bounded to maxEntryCount=3 (got %lu)",
               (unsigned long)store.currentEntryCount);

    // Purgeable IOSurface check
    [colorPage markVolatile];
    uint64_t fpVol = currentPhysFootprintBytes();
    BOOL pinned = [colorPage pinNonVolatile];
    XSC_ASSERT(pinned, "pinNonVolatile succeeds under no memory pressure (footprint=%llu)", fpVol);

    // resetKeepingBook
    [store resetKeepingBook:nil];
    XSC_ASSERT(store.currentEntryCount == 0, "resetKeepingBook:nil clears cache");
}

// MARK: - Benchmarks

static void runBenchmarks(NSString *tmpDir) {
    printf("\n[BENCHMARKS]\n");

    // 1. 4,096-file directory scan
    NSString *dir4k = [tmpDir stringByAppendingPathComponent:@"bench4k"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir4k withIntermediateDirectories:YES attributes:nil error:nil];
    const uint8_t tiny = 0;
    for (int i = 0; i < 4096; i++) {
        char p[512];
        snprintf(p, sizeof(p), "%s/page_%04d.jpg", dir4k.fileSystemRepresentation, i);
        FILE *f = fopen(p, "wb");
        if (f) { fwrite(&tiny, 1, 1, f); fclose(f); }
    }
    double t0 = nowMilliseconds();
    NSError *err = nil;
    XSCBook *b4k = [XSCBook openURL:[NSURL fileURLWithPath:dir4k] cancelFlag:NULL error:&err];
    double dt4k = nowMilliseconds() - t0;
    printf("  4,096-file dir scan : %6.2f ms (pages=%lu)\n", dt4k, (unsigned long)b4k.pageCount);
    XSC_ASSERT(b4k.pageCount == 4096, "4k dir scan found 4096 pages");

    // 2. 128-page & 500-page CBZ open
    NSData *pageImg = makeSyntheticImageData(1024, 1536, YES, (__bridge CFStringRef)UTTypeJPEG.identifier);
    for (size_t nPages = 128; nPages <= 500; nPages = (nPages == 128 ? 500 : 501)) {
        NSString *p = [tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"bench_%zu.cbz", nPages]];
        TestZipEntry *ents = calloc(nPages, sizeof(TestZipEntry));
        char (*names)[24] = calloc(nPages, 24);
        for (size_t i = 0; i < nPages; i++) {
            snprintf(names[i], 24, "page_%04zu.jpg", i + 1);
            ents[i] = (TestZipEntry){ names[i], pageImg, NO, NO, 0 };
        }
        writeTestZIP(p, ents, nPages, NO);
        double ts = nowMilliseconds();
        XSCBook *b = [XSCBook openURL:[NSURL fileURLWithPath:p] cancelFlag:NULL error:&err];
        double dt = nowMilliseconds() - ts;
        printf("  %3zu-page CBZ open   : %6.3f ms (pages=%lu)\n", nPages, dt, (unsigned long)b.pageCount);
        XSC_ASSERT(b.pageCount == nPages, "%zu-page CBZ opened", nPages);

        if (nPages == 128) {
            // 3. Cold decode & synchronous cache-hit lookup
            XSCImageStore *store = [[XSCImageStore alloc] init];
            __block BOOL done = NO;
            double td0 = nowMilliseconds();
            [store requestPageForBook:b index:0 priority:YES completion:^(XSCDecodedPage *page, BOOL failed) {
                (void)page; (void)failed;
                done = YES;
            }];
            NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:5.0];
            while (!done && [dl timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            }
            double td = nowMilliseconds() - td0;
            printf("  Cold decode (1024x1536 JPEG): %6.2f ms\n", td);

            const int iters = 10000;
            double th0 = nowMilliseconds();
            NSUInteger hits = 0;
            for (int k = 0; k < iters; k++) {
                if ([store cachedPageForBook:b index:0] != nil) hits++;
            }
            double thNs = (nowMilliseconds() - th0) * 1e6 / (double)iters;
            printf("  Sync cache-hit lookup       : %6.1f ns/call (%lu/%d hits)\n",
                   thNs, (unsigned long)hits, iters);
            XSC_ASSERT(hits == (NSUInteger)iters, "all sync cache-hit lookups succeeded");
        }
        free(names);
        free(ents);
    }
}

int main(void) {
    @autoreleasepool {
        char tmpl[] = "/tmp/xscomic-tests.XXXXXX";
        char *dirC = mkdtemp(tmpl);
        if (!dirC) { perror("mkdtemp"); return 1; }
        NSString *tmpDir = [NSString stringWithUTF8String:dirC];

        NSData *png1 = makeSyntheticImageData(64, 64, YES, (__bridge CFStringRef)UTTypePNG.identifier);
        NSData *png2 = makeSyntheticImageData(64, 64, NO, (__bridge CFStringRef)UTTypePNG.identifier);

        testExtensionsAndNaturalSort();
        testCBZStoreDeflateZip64Security(tmpDir, png1, png2);
        testCBTAndCB7(tmpDir, png1, png2);
        testDirectoryAndAdjacentVolumes(tmpDir, png1, png2);
        testReaderModelAndPredictor(tmpDir, png1);
        testImageStoreCachePurgeableGrayGIF(tmpDir);
        runBenchmarks(tmpDir);

        [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];

        printf("\n=== SUMMARY: %d passed, %d failed ===\n", gPassCount, gFailCount);
        return gFailCount == 0 ? 0 : 1;
    }
}
