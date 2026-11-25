#import "XSCArchive.h"

#include <compression.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const XSCArchiveErrorDomain = @"XSCArchiveErrorDomain";

#pragma mark - Limits & Constants

/*
 Hard ceilings against hostile or malformed archives (zip bombs, million-entry
 directory bombs, runaway PAX/GNU metadata headers, and pathological directory
 nesting). Every limit is checked BEFORE allocating buffers proportional to
 untrusted archive fields.
 */
static const uint64_t kXSCMaxEntryCount = 100000;
static const uint64_t kXSCMaxPageBytes = 256ULL * 1024ULL * 1024ULL;
static const uint64_t kXSCMaxCentralDirBytes = 64ULL * 1024ULL * 1024ULL;
static const uint64_t kXSCMaxInMemoryArchiveBytes = 256ULL * 1024ULL * 1024ULL;
static const size_t kXSCMaxMetaHeaderBytes = 64 * 1024;
static const size_t kXSCMaxInitialDataCap = 4 * 1024 * 1024;
static const int kXSCMaxDirectoryDepth = 64;

static _Atomic(uint64_t) gNextBookID = 1;

#pragma mark - Minimal libarchive.2.dylib C Declarations

/*
 macOS ships /usr/lib/libarchive.2.dylib (libarchive 3.7.x with zlib, liblzma,
 libbz2, RAR4, RAR5, and 7z) and exposes its stub in the SDK as libarchive.tbd,
 but omits <archive.h>. Declaring the 14 C ABI entry points we need avoids both
 dlopen() boilerplate and spawning /usr/bin/bsdtar as a subprocess, while adding
 zero third-party bytes to the executable.
 */
struct archive;
struct archive_entry;

static const int kArchiveOK = 0;
static const int kArchiveEOF = 1;
static const int kArchiveWarn = -20;

extern struct archive *archive_read_new(void);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_data_skip(struct archive *);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);

#pragma mark - Process-Scoped Spill Workspace (atexit Cleanup)

/*
 CBZ/ZIP and CBT/TAR never write to disk. CBR/CB7 archives <= 256 MiB stay in
 memory. Only libarchive volumes whose decoded image bytes exceed 256 MiB spill
 overflow pages into a private per-process root under NSTemporaryDirectory().

 Ownership contract:
   • Each spilled XSCBook owns one UUID subdirectory below gSpillRoot and removes
     it in -dealloc (and immediately on any open error/cancellation).
   • atexit(xscCleanupSpillRoot) removes the entire process root on normal exit,
     catching any open that was still in flight when the user quit.
 */
static char gSpillRoot[PATH_MAX];
static dispatch_once_t gSpillRootOnce;

static void xscRemoveTreeAtPath(const char *path) {
    if (!path || path[0] == '\0') return;
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        if (nsPath) {
            [[NSFileManager defaultManager] removeItemAtPath:nsPath error:nil];
        }
    }
}

static void xscCleanupSpillRoot(void) {
    xscRemoveTreeAtPath(gSpillRoot);
}

static const char *xscSpillWorkspaceRoot(void) {
    dispatch_once(&gSpillRootOnce, ^{
        NSString *root = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"xsComic-%@", [NSUUID UUID].UUIDString]];
        const char *utf8 = root.fileSystemRepresentation;
        if (utf8 && utf8[0] != '\0' && strlen(utf8) < sizeof(gSpillRoot)) {
            strlcpy(gSpillRoot, utf8, sizeof(gSpillRoot));
            atexit(xscCleanupSpillRoot);
        }
    });
    return gSpillRoot;
}

#pragma mark - Low-Level I/O & Extension Helpers

static NSError *xscMakeError(XSCArchiveErrorCode code, NSString *description) {
    return [NSError errorWithDomain:XSCArchiveErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static inline bool xscIsCancelled(const _Atomic(bool) *flag) {
    return flag != NULL && atomic_load_explicit(flag, memory_order_relaxed);
}

static inline uint8_t xscAsciiLower(uint8_t c) {
    return (c >= 'A' && c <= 'Z') ? (uint8_t)(c + 32) : c;
}

static inline bool xscIsDigit(uint8_t c) {
    return c >= '0' && c <= '9';
}

/*
 Unaligned little-endian loads via memcpy() compile to a single ldrh/ldr
 instruction on arm64 without invoking undefined behavior on unaligned ZIP
 header pointers.
 */
static inline uint16_t xscReadU16LE(const uint8_t *p) {
    uint16_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static inline uint32_t xscReadU32LE(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static inline uint64_t xscReadU64LE(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

/*
 Stateless pread(2) loop handling EINTR and short reads.

 Why pread(2) instead of mmap(2)?
   1. SIGBUS immunity: if a user unplugs a USB drive or drops an SMB share while
      reading, pread() cleanly returns -1 (EIO) instead of crashing the process
      with SIGBUS.
   2. Lock-free concurrency: pread() does not touch the file descriptor's seek
      offset, so multiple background decode lanes can read different pages from
      the same fd simultaneously with zero locking.
   3. Speed: on macOS, pread() reads straight out of the kernel Unified Buffer
      Cache (UBC), matching mmap() within ~50 us for typical comic pages.
 */
static bool xscPreadAll(int fd, void *buf, size_t count, off_t offset) {
    if (offset < 0) return false;
    uint8_t *dst = (uint8_t *)buf;
    size_t done = 0;
    while (done < count) {
        if ((uint64_t)offset > (uint64_t)INT64_MAX - done) return false;
        ssize_t n = pread(fd, dst + done, count - done, offset + (off_t)done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        done += (size_t)n;
    }
    return true;
}

/*
 Extension matching packs 2–4 lowercased ASCII bytes into a single uint32_t so
 directory scans and Central Directory walks test image/archive extensions in a
 few register instructions with zero heap allocations and zero UTType lookups.
 */
static uint32_t xscPackExtCode(const char *s, size_t len) {
    if (len < 2 || len > 4) return 0;
    uint32_t code = 0;
    for (size_t i = 0; i < len; i++) {
        code = (code << 8) | xscAsciiLower((uint8_t)s[i]);
    }
    return code;
}

static bool xscExtractExtCode(const char *path, size_t len, uint32_t *outCode) {
    size_t i = len;
    while (i > 0) {
        i--;
        char c = path[i];
        if (c == '.') {
            if (i == 0 || path[i - 1] == '/' || path[i - 1] == '\\') return false;
            size_t extLen = len - i - 1;
            uint32_t code = xscPackExtCode(path + i + 1, extLen);
            if (code == 0) return false;
            *outCode = code;
            return true;
        }
        if (c == '/' || c == '\\') return false;
    }
    return false;
}

static bool xscIsImageExtCode(uint32_t code) {
    switch (code) {
        case 0x6A7067:   // jpg
        case 0x706E67:   // png
        case 0x676966:   // gif
        case 0x626D70:   // bmp
        case 0x746966:   // tif
        case 0x6A706567: // jpeg
        case 0x77656270: // webp
        case 0x68656963: // heic
        case 0x68656966: // heif
        case 0x61766966: // avif
        case 0x74696666: // tiff
            return true;
        default:
            return false;
    }
}

static bool xscIsArchiveExtCode(uint32_t code) {
    switch (code) {
        case 0x377A:   // 7z
        case 0x636237: // cb7
        case 0x636272: // cbr
        case 0x636274: // cbt
        case 0x63627A: // cbz
        case 0x726172: // rar
        case 0x746172: // tar
        case 0x7A6970: // zip
            return true;
        default:
            return false;
    }
}

static bool xscIsImagePathBytes(const char *s, size_t len) {
    uint32_t code = 0;
    return xscExtractExtCode(s, len, &code) && xscIsImageExtCode(code);
}

static bool xscIsArchivePathBytes(const char *s, size_t len) {
    uint32_t code = 0;
    return xscExtractExtCode(s, len, &code) && xscIsArchiveExtCode(code);
}

static bool xscIsGIFPathBytes(const char *s, size_t len) {
    uint32_t code = 0;
    return xscExtractExtCode(s, len, &code) && code == 0x676966;
}

static bool xscHasDot(const char *s, size_t len) {
    return memchr(s, '.', len) != NULL;
}

/*
 Only directories whose basename contains '.' are queried for NSURLIsPackageKey.
 Normal chapter directories ("chapter1", "vol02") never incur LaunchServices /
 CoreServices metadata overhead, while ".app"/".bundle"/".rtfd" packages are
 still skipped cleanly.
 */
static bool xscIsPackageAtPath(const char *path) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        if (!nsPath) return false;
        NSURL *url = [NSURL fileURLWithPath:nsPath isDirectory:YES];
        NSNumber *isPkg = nil;
        if ([url getResourceValue:&isPkg forKey:NSURLIsPackageKey error:nil]) {
            return isPkg.boolValue;
        }
        return false;
    }
}

static size_t xscJoinPath(char *dst, size_t dstCap, const char *dir, size_t dirLen, const char *name, size_t nameLen) {
    bool needsSlash = (dirLen == 0 || dir[dirLen - 1] != '/');
    size_t total = dirLen + (needsSlash ? 1 : 0) + nameLen;
    if (total + 1 > dstCap) return 0;
    if (dirLen > 0) memcpy(dst, dir, dirLen);
    size_t pos = dirLen;
    if (needsSlash) dst[pos++] = '/';
    memcpy(dst + pos, name, nameLen);
    dst[pos + nameLen] = '\0';
    return total;
}

#pragma mark - Path Normalization & Security Validation

typedef enum {
    XSCPathOK = 0,
    XSCPathSkip = 1,   // hidden, __MACOSX, directory, empty
    XSCPathUnsafe = 2, // leading '/', '..', embedded NUL, drive letter
} XSCPathCheck;

/*
 Security gate applied to EVERY archive member (including non-image and skipped
 entries) across ZIP, TAR, and libarchive:
   • Rejects embedded NULs, absolute POSIX/Windows paths ('/', '\', "C:"), and
     any ".." component with XSCPathUnsafe (so hostile traversal archives fail
     immediately rather than silently skipping the bad member).
   • Strips harmless leading "./" prefixes commonly emitted by `zip -r .` and
     `bsdtar -c -C dir .`.
   • Skips macOS resource forks ("__MACOSX"), dotfiles (".DS_Store", ".hidden"),
     and directory entries (trailing '/' or '\').
 */
static XSCPathCheck xscValidateArchivePath(const char *raw,
                                           size_t rawLen,
                                           const char **outTrimmed,
                                           size_t *outLen) {
    if (rawLen == 0) return XSCPathSkip;
    if (memchr(raw, '\0', rawLen) != NULL) return XSCPathUnsafe;
    if (raw[0] == '/' || raw[0] == '\\') return XSCPathUnsafe;
    if (rawLen >= 2 && raw[1] == ':') return XSCPathUnsafe;

    const char *p = raw;
    size_t len = rawLen;
    while (len >= 2 && p[0] == '.' && (p[1] == '/' || p[1] == '\\')) {
        p += 2;
        len -= 2;
    }
    if (len == 0) return XSCPathSkip;

    bool isDir = (p[len - 1] == '/' || p[len - 1] == '\\');
    bool skipHiddenOrMeta = false;

    size_t start = 0;
    while (start < len) {
        size_t end = start;
        while (end < len && p[end] != '/' && p[end] != '\\') {
            end++;
        }
        size_t compLen = end - start;
        if (compLen == 2 && p[start] == '.' && p[start + 1] == '.') {
            return XSCPathUnsafe;
        }
        if (compLen > 0) {
            if (p[start] == '.') {
                if (compLen > 1) skipHiddenOrMeta = true;
            } else if (compLen == 8 && memcmp(p + start, "__MACOSX", 8) == 0) {
                skipHiddenOrMeta = true;
            }
        }
        start = (end < len) ? (end + 1) : len;
    }

    if (isDir || skipHiddenOrMeta) return XSCPathSkip;
    *outTrimmed = p;
    *outLen = len;
    return XSCPathOK;
}

#pragma mark - Flat UTF-8 Byte Arena & Entry Table

/*
 Storing all page names contiguously in a single NUL-terminated UTF-8 byte arena
 eliminates thousands of per-file NSString/NSURL allocations during directory
 scans and archive opens (cutting a 4,096-file scan from ~26 ms to ~2.5 ms on
 Apple Silicon). NSString objects are materialized lazily only when the UI asks
 for -pageNameAtIndex:.
 */
typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} XSCByteArena;

static bool xscArenaInit(XSCByteArena *a, size_t initialCap) {
    a->len = 0;
    a->cap = initialCap > 0 ? initialCap : 4096;
    a->buf = (char *)malloc(a->cap);
    return a->buf != NULL;
}

static void xscArenaFree(XSCByteArena *a) {
    free(a->buf);
    a->buf = NULL;
    a->len = 0;
    a->cap = 0;
}

static bool xscArenaAppend2(XSCByteArena *a,
                            const char *prefix,
                            size_t prefixLen,
                            const char *name,
                            size_t nameLen,
                            uint32_t *outOffset,
                            uint32_t *outLen) {
    if (prefixLen > UINT32_MAX || nameLen > UINT32_MAX - prefixLen) return false;
    size_t total = prefixLen + nameLen;
    if (a->len > UINT32_MAX - total - 1) return false;
    size_t needed = a->len + total + 1;
    if (needed > a->cap) {
        size_t newCap = a->cap ? a->cap : 4096;
        while (newCap < needed) {
            if (newCap > (SIZE_MAX / 2)) return false;
            newCap *= 2;
        }
        char *grown = (char *)realloc(a->buf, newCap);
        if (!grown) return false;
        a->buf = grown;
        a->cap = newCap;
    }
    *outOffset = (uint32_t)a->len;
    *outLen = (uint32_t)total;
    if (prefixLen > 0) {
        memcpy(a->buf + a->len, prefix, prefixLen);
        a->len += prefixLen;
    }
    if (nameLen > 0) {
        memcpy(a->buf + a->len, name, nameLen);
        a->len += nameLen;
    }
    a->buf[a->len++] = '\0';
    return true;
}

typedef enum {
    XSCBookKindDirectory = 0,
    XSCBookKindZip = 1,
    XSCBookKindTar = 2,
    XSCBookKindLibarchive = 3,
} XSCBookKind;

typedef struct {
    uint32_t nameOffset;
    uint32_t nameLen;
    uint16_t compressionMethod; // ZIP method (0=STORE, 8=DEFLATE)
    uint16_t flags;             // bit 0: spilled-to-disk for libarchive
    uint32_t payloadIndex;      // index into _memoryPayloads or spill file ID
    uint64_t dataOffset;        // ZIP localHeaderOffset or TAR dataOffset
    uint64_t compressedSize;
    uint64_t uncompressedSize;
} XSCEntry;

typedef struct {
    XSCEntry *items;
    size_t count;
    size_t cap;
} XSCEntryList;

static bool xscEntryListAppend(XSCEntryList *list, XSCEntry entry) {
    if (list->count >= kXSCMaxEntryCount) return false;
    if (list->count == list->cap) {
        size_t newCap = list->cap ? list->cap * 2 : 64;
        if (newCap > kXSCMaxEntryCount) newCap = (size_t)kXSCMaxEntryCount;
        XSCEntry *grown = (XSCEntry *)realloc(list->items, newCap * sizeof(XSCEntry));
        if (!grown) return false;
        list->items = grown;
        list->cap = newCap;
    }
    list->items[list->count++] = entry;
    return true;
}

static int xscCompareEntries(void *thunk, const void *lhsPtr, const void *rhsPtr) {
    const XSCByteArena *arena = (const XSCByteArena *)thunk;
    const XSCEntry *a = (const XSCEntry *)lhsPtr;
    const XSCEntry *b = (const XSCEntry *)rhsPtr;
    NSComparisonResult r = [XSCBook naturalCompareBytes:arena->buf + a->nameOffset
                                                 length:a->nameLen
                                              withBytes:arena->buf + b->nameOffset
                                                 length:b->nameLen];
    if (r == NSOrderedAscending) return -1;
    if (r == NSOrderedDescending) return 1;
    return 0;
}

#pragma mark - XSCBook Private Storage

@interface XSCBook () {
    XSCBookKind _kind;
    XSCByteArena _arena;
    XSCEntry *_entries;
    NSUInteger _pageCount;

    // Directory backend (immutable root path; reads open each page with O_NOFOLLOW)
    char *_rootDir;
    size_t _rootDirLen;

    // ZIP & TAR backend (single read-only fd accessed via stateless pread(2))
    int _fd;
    uint64_t _fileSize;

    // libarchive backend (immutable in-memory NSData array + optional spill dir)
    NSArray<NSData *> *_memoryPayloads;
    char *_spillDir;
}
@end

#pragma mark - Directory Walker (POSIX opendir/readdir + d_type)

/*
 Why POSIX opendir(3)/readdir(3) instead of NSFileManager or getattrlistbulk(2)?
   • NSFileManager.enumerator allocates a CFURL/NSURL and resource cache per
     entry (~17 ms for 4,096 files on Apple Silicon).
   • On APFS, getdirentries64 (behind readdir) already delivers d_type with zero
     inode-catalog lookups and empirically beats getattrlistbulk by ~1.7x when
     only (name, type) is needed.
   • Security: DT_LNK is always skipped so symlinks inside a comic folder can
     never escape the selected book. On filesystems that return DT_UNKNOWN
     (NFS/exFAT/FUSE), we fall back to lstat(2) (never stat(2)).
   • Memory safety: we read ent->d_name, ent->d_namlen, and ent->d_type directly
     through the pointer returned by readdir() without ever copying `*ent` by
     value past `ent->d_reclen`.
 */
static bool xscWalkDirectory(const char *dirPath,
                             const char *relPrefix,
                             size_t relPrefixLen,
                             int depth,
                             XSCByteArena *arena,
                             XSCEntryList *entries,
                             size_t *visitedCount,
                             const _Atomic(bool) *cancelFlag,
                             NSError **error) {
    if (depth > kXSCMaxDirectoryDepth) return true;

    DIR *dir = opendir(dirPath);
    if (!dir) {
        if (error && !*error) {
            *error = xscMakeError(XSCArchiveErrorIOFailure, @"The selected directory could not be read.");
        }
        return false;
    }

    size_t dirPathLen = strlen(dirPath);
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        // Amortize atomic cancellation load to once every 256 entries.
        if ((++(*visitedCount) & 255) == 0 && xscIsCancelled(cancelFlag)) {
            closedir(dir);
            if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
            return false;
        }

        const char *name = ent->d_name;
        size_t nameLen = ent->d_namlen;
        if (nameLen == 0 || name[0] == '.') continue; // skips ".", "..", and hidden files

        uint8_t dType = ent->d_type;
        if (dType == DT_LNK) continue; // never follow symlinks

        if (dType == DT_UNKNOWN) {
            char fullBuf[PATH_MAX];
            if (xscJoinPath(fullBuf, sizeof(fullBuf), dirPath, dirPathLen, name, nameLen) == 0) {
                continue;
            }
            struct stat st;
            if (lstat(fullBuf, &st) != 0) continue;
            if (S_ISREG(st.st_mode)) {
                dType = DT_REG;
            } else if (S_ISDIR(st.st_mode)) {
                dType = DT_DIR;
            } else {
                continue;
            }
        }

        if (dType == DT_REG) {
            if (!xscIsImagePathBytes(name, nameLen)) continue;
            XSCEntry e = {0};
            if (!xscArenaAppend2(arena, relPrefix, relPrefixLen, name, nameLen, &e.nameOffset, &e.nameLen)) {
                closedir(dir);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory while scanning directory.");
                return false;
            }
            if (!xscEntryListAppend(entries, e)) {
                closedir(dir);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Directory exceeds maximum page limit.");
                return false;
            }
        } else if (dType == DT_DIR) {
            bool needsSlash = (dirPathLen == 0 || dirPath[dirPathLen - 1] != '/');
            size_t subFullLen = dirPathLen + (needsSlash ? 1 : 0) + nameLen;
            size_t nextPrefLen = relPrefixLen + nameLen + 1;
            char *subFull = (char *)malloc(subFullLen + 1);
            char *nextPref = (char *)malloc(nextPrefLen + 1);
            if (!subFull || !nextPref) {
                free(subFull);
                free(nextPref);
                closedir(dir);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
                return false;
            }
            xscJoinPath(subFull, subFullLen + 1, dirPath, dirPathLen, name, nameLen);

            bool isPkg = xscHasDot(name, nameLen) && xscIsPackageAtPath(subFull);
            if (!isPkg) {
                if (relPrefixLen > 0) memcpy(nextPref, relPrefix, relPrefixLen);
                memcpy(nextPref + relPrefixLen, name, nameLen);
                nextPref[relPrefixLen + nameLen] = '/';
                nextPref[nextPrefLen] = '\0';

                bool ok = xscWalkDirectory(subFull,
                                           nextPref,
                                           nextPrefLen,
                                           depth + 1,
                                           arena,
                                           entries,
                                           visitedCount,
                                           cancelFlag,
                                           error);
                if (!ok) {
                    free(subFull);
                    free(nextPref);
                    closedir(dir);
                    return false;
                }
            }
            free(subFull);
            free(nextPref);
        }
    }

    closedir(dir);
    return true;
}

static bool xscDirectoryContainsImage(const char *dirPath,
                                      int depth,
                                      size_t *visitedCount,
                                      const _Atomic(bool) *cancelFlag) {
    if (depth > kXSCMaxDirectoryDepth) return false;
    DIR *dir = opendir(dirPath);
    if (!dir) return false;

    size_t dirPathLen = strlen(dirPath);
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if ((++(*visitedCount) & 255) == 0 && xscIsCancelled(cancelFlag)) {
            closedir(dir);
            return false;
        }
        const char *name = ent->d_name;
        size_t nameLen = ent->d_namlen;
        if (nameLen == 0 || name[0] == '.') continue;

        uint8_t dType = ent->d_type;
        if (dType == DT_LNK) continue;
        if (dType == DT_UNKNOWN) {
            char fullBuf[PATH_MAX];
            if (xscJoinPath(fullBuf, sizeof(fullBuf), dirPath, dirPathLen, name, nameLen) == 0) {
                continue;
            }
            struct stat st;
            if (lstat(fullBuf, &st) != 0) continue;
            dType = S_ISREG(st.st_mode) ? DT_REG : (S_ISDIR(st.st_mode) ? DT_DIR : DT_UNKNOWN);
        }

        if (dType == DT_REG) {
            if (xscIsImagePathBytes(name, nameLen)) {
                closedir(dir);
                return true;
            }
        } else if (dType == DT_DIR) {
            bool needsSlash = (dirPathLen == 0 || dirPath[dirPathLen - 1] != '/');
            size_t subFullLen = dirPathLen + (needsSlash ? 1 : 0) + nameLen;
            char *subFull = (char *)malloc(subFullLen + 1);
            if (!subFull) continue;
            xscJoinPath(subFull, subFullLen + 1, dirPath, dirPathLen, name, nameLen);
            bool isPkg = xscHasDot(name, nameLen) && xscIsPackageAtPath(subFull);
            bool found = !isPkg && xscDirectoryContainsImage(subFull, depth + 1, visitedCount, cancelFlag);
            free(subFull);
            if (found) {
                closedir(dir);
                return true;
            }
        }
    }
    closedir(dir);
    return false;
}

#pragma mark - TAR Header Helpers

static bool xscParseTarOctalOrBase256(const uint8_t *p, size_t len, uint64_t *outVal) {
    if (len == 0) return false;
    if ((p[0] & 0x80) != 0) {
        // GNU base-256 big-endian encoding for sizes >= 8 GiB
        if ((p[0] & 0x40) != 0) return false; // negative size unsupported
        uint64_t v = p[0] & 0x3F;
        for (size_t i = 1; i < len; i++) {
            if (v > (UINT64_MAX >> 8)) return false;
            v = (v << 8) | p[i];
        }
        *outVal = v;
        return true;
    }
    uint64_t v = 0;
    size_t i = 0;
    while (i < len && (p[i] == ' ' || p[i] == '\0')) i++;
    bool anyDigit = false;
    while (i < len && p[i] >= '0' && p[i] <= '7') {
        anyDigit = true;
        if (v > (UINT64_MAX >> 3)) return false;
        v = (v << 3) | (uint64_t)(p[i] - '0');
        i++;
    }
    *outVal = anyDigit ? v : 0;
    return true;
}

static bool xscVerifyTarChecksum(const uint8_t blk[512]) {
    uint64_t stored = 0;
    if (!xscParseTarOctalOrBase256(blk + 148, 8, &stored)) return false;
    uint64_t unsignedSum = 0;
    int64_t signedSum = 0;
    for (int i = 0; i < 512; i++) {
        uint8_t b = (i >= 148 && i < 156) ? (uint8_t)' ' : blk[i];
        unsignedSum += b;
        signedSum += (int8_t)b;
    }
    return stored == unsignedSum || (signedSum >= 0 && stored == (uint64_t)signedSum);
}

static bool xscIsZeroBlock512(const uint8_t blk[512]) {
    uint64_t acc = 0;
    for (int i = 0; i < 512; i += 8) {
        uint64_t w;
        memcpy(&w, blk + i, 8);
        acc |= w;
    }
    return acc == 0;
}

static void xscParsePaxRecords(const uint8_t *buf,
                               size_t len,
                               char **outPath,
                               size_t *outPathLen,
                               bool *outHasSize,
                               uint64_t *outSize) {
    size_t pos = 0;
    while (pos < len) {
        // PAX record format: "<decimal length> <key>=<value>\n"
        size_t recLen = 0;
        size_t p = pos;
        while (p < len && buf[p] >= '0' && buf[p] <= '9') {
            if (recLen > (SIZE_MAX - 9) / 10) return;
            recLen = recLen * 10 + (size_t)(buf[p] - '0');
            p++;
        }
        if (recLen == 0 || p >= len || buf[p] != ' ' || recLen > len - pos) break;
        size_t recEnd = pos + recLen;
        size_t kvStart = p + 1;
        size_t kvEnd = (recEnd > kvStart && buf[recEnd - 1] == '\n') ? (recEnd - 1) : recEnd;
        const uint8_t *eq = (const uint8_t *)memchr(buf + kvStart, '=', kvEnd - kvStart);
        if (eq) {
            size_t keyLen = (size_t)(eq - (buf + kvStart));
            const uint8_t *val = eq + 1;
            size_t valLen = (size_t)((buf + kvEnd) - val);
            if (keyLen == 4 && memcmp(buf + kvStart, "path", 4) == 0 && valLen <= kXSCMaxMetaHeaderBytes) {
                char *copy = (char *)malloc(valLen + 1);
                if (copy) {
                    memcpy(copy, val, valLen);
                    copy[valLen] = '\0';
                    free(*outPath);
                    *outPath = copy;
                    *outPathLen = valLen;
                }
            } else if (keyLen == 4 && memcmp(buf + kvStart, "size", 4) == 0 && valLen > 0) {
                uint64_t s = 0;
                bool ok = true;
                for (size_t k = 0; k < valLen; k++) {
                    if (val[k] < '0' || val[k] > '9' || s > (UINT64_MAX - 9) / 10) {
                        ok = false;
                        break;
                    }
                    s = s * 10 + (uint64_t)(val[k] - '0');
                }
                if (ok) {
                    *outHasSize = true;
                    *outSize = s;
                }
            }
        }
        pos = recEnd;
    }
}

#pragma mark - XSCBook Implementation

@implementation XSCBook

+ (BOOL)isSupportedArchiveExtension:(NSString *)ext {
    if (ext.length == 0) return NO;
    const char *s = ext.UTF8String;
    if (!s) return NO;
    if (s[0] == '.') s++;
    return xscIsArchiveExtCode(xscPackExtCode(s, strlen(s))) ? YES : NO;
}

+ (BOOL)isSupportedImageExtension:(NSString *)ext {
    if (ext.length == 0) return NO;
    const char *s = ext.UTF8String;
    if (!s) return NO;
    if (s[0] == '.') s++;
    return xscIsImageExtCode(xscPackExtCode(s, strlen(s))) ? YES : NO;
}

/*
 Zero-allocation ASCII-fast natural comparator (~9.4x faster than NSString
 localizedStandardCompare: on 4,096-page volumes).
   • Digit runs compare by numeric magnitude without integer overflow (skipping
     leading zeros, comparing significant digit count, then lexicographically;
     equal values order fewer leading zeros first to match Finder).
   • Non-digit ASCII bytes compare case-insensitively.
   • If any byte with bit 7 set (>= 0x80) is encountered in either operand, we
     hand the full byte spans to CFStringCompare with kCFCompareNumerically |
     kCFCompareLocalized | kCFCompareCaseInsensitive via zero-copy CFStringRef.
   • A deterministic raw-byte tie-breaker guarantees a strict total order.
 */
+ (NSComparisonResult)naturalCompareBytes:(const char *)a
                                   length:(size_t)aLen
                                withBytes:(const char *)b
                                   length:(size_t)bLen {
    const uint8_t *ua = (const uint8_t *)a;
    const uint8_t *ub = (const uint8_t *)b;
    size_t i = 0, j = 0;

    while (i < aLen && j < bLen) {
        uint8_t ca = ua[i];
        uint8_t cb = ub[j];

        if (((ca | cb) & 0x80) != 0) {
            CFStringRef sa = CFStringCreateWithBytesNoCopy(
                kCFAllocatorDefault, ua, (CFIndex)aLen, kCFStringEncodingUTF8, false, kCFAllocatorNull);
            CFStringRef sb = CFStringCreateWithBytesNoCopy(
                kCFAllocatorDefault, ub, (CFIndex)bLen, kCFStringEncodingUTF8, false, kCFAllocatorNull);
            if (sa && sb) {
                CFComparisonResult r = CFStringCompare(
                    sa, sb, kCFCompareNumerically | kCFCompareLocalized | kCFCompareCaseInsensitive);
                CFRelease(sa);
                CFRelease(sb);
                if (r == kCFCompareLessThan) return NSOrderedAscending;
                if (r == kCFCompareGreaterThan) return NSOrderedDescending;
                size_t m = aLen < bLen ? aLen : bLen;
                int cmp = memcmp(ua, ub, m);
                if (cmp != 0) return cmp < 0 ? NSOrderedAscending : NSOrderedDescending;
                if (aLen != bLen) return aLen < bLen ? NSOrderedAscending : NSOrderedDescending;
                return NSOrderedSame;
            }
            if (sa) CFRelease(sa);
            if (sb) CFRelease(sb);
        }

        if (xscIsDigit(ca) && xscIsDigit(cb)) {
            size_t startA = i, startB = j;
            while (i < aLen && ua[i] == '0') i++;
            while (j < bLen && ub[j] == '0') j++;
            size_t nzA = i, nzB = j;
            while (i < aLen && xscIsDigit(ua[i])) i++;
            while (j < bLen && xscIsDigit(ub[j])) j++;
            size_t sigA = i - nzA;
            size_t sigB = j - nzB;
            if (sigA != sigB) return sigA < sigB ? NSOrderedAscending : NSOrderedDescending;
            for (size_t k = 0; k < sigA; k++) {
                if (ua[nzA + k] != ub[nzB + k]) {
                    return ua[nzA + k] < ub[nzB + k] ? NSOrderedAscending : NSOrderedDescending;
                }
            }
            size_t rawA = i - startA;
            size_t rawB = j - startB;
            if (rawA != rawB) return rawA < rawB ? NSOrderedAscending : NSOrderedDescending;
        } else {
            uint8_t la = xscAsciiLower(ca);
            uint8_t lb = xscAsciiLower(cb);
            if (la != lb) return la < lb ? NSOrderedAscending : NSOrderedDescending;
            i++;
            j++;
        }
    }

    if (i != aLen) return NSOrderedDescending;
    if (j != bLen) return NSOrderedAscending;

    size_t m = aLen < bLen ? aLen : bLen;
    int cmp = memcmp(ua, ub, m);
    if (cmp != 0) return cmp < 0 ? NSOrderedAscending : NSOrderedDescending;
    if (aLen != bLen) return aLen < bLen ? NSOrderedAscending : NSOrderedDescending;
    return NSOrderedSame;
}

#pragma mark - Lifecycle

- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                             kind:(XSCBookKind)kind
                            arena:(XSCByteArena)arena
                          entries:(XSCEntry *)entries
                        pageCount:(NSUInteger)pageCount {
    self = [super init];
    if (self) {
        _sourceURL = [sourceURL copy];
        _displayTitle = sourceURL.lastPathComponent ?: @"";
        _bookID = atomic_fetch_add_explicit(&gNextBookID, 1, memory_order_relaxed);
        _kind = kind;
        _arena = arena;
        _entries = entries;
        _pageCount = pageCount;
        _fd = -1;
    }
    return self;
}

- (void)dealloc {
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
    free(_entries);
    _entries = NULL;
    xscArenaFree(&_arena);
    free(_rootDir);
    _rootDir = NULL;
    if (_spillDir) {
        xscRemoveTreeAtPath(_spillDir);
        free(_spillDir);
        _spillDir = NULL;
    }
}

#pragma mark - Opening Books

+ (nullable instancetype)openURL:(NSURL *)url
                      cancelFlag:(nullable const _Atomic(bool) *)cancelFlag
                           error:(NSError * _Nullable * _Nullable)error {
    if (xscIsCancelled(cancelFlag)) {
        if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
        return nil;
    }

    const char *path = url.fileSystemRepresentation;
    if (!path || path[0] == '\0') {
        if (error) *error = xscMakeError(XSCArchiveErrorMissingFile, @"The selected file no longer exists.");
        return nil;
    }

    struct stat st;
    if (stat(path, &st) != 0) {
        if (error) *error = xscMakeError(XSCArchiveErrorMissingFile, @"The selected file no longer exists.");
        return nil;
    }

    if (S_ISDIR(st.st_mode)) {
        return [self openDirectoryURL:url path:path cancelFlag:cancelFlag error:error];
    }

    NSString *ext = url.pathExtension;
    if (![self isSupportedArchiveExtension:ext]) {
        if (error) {
            *error = xscMakeError(XSCArchiveErrorUnsupportedFormat,
                                  [NSString stringWithFormat:@"Unsupported archive format: .%@", ext ?: @""]);
        }
        return nil;
    }

    // Reject FIFOs, sockets, and device nodes before any reader calls open(2).
    if (!S_ISREG(st.st_mode)) {
        if (error) {
            *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"The archive is not a regular file.");
        }
        return nil;
    }

    const char *extUTF8 = ext.UTF8String ?: "";
    uint32_t extCode = xscPackExtCode(extUTF8, strlen(extUTF8));
    if (extCode == 0x63627A || extCode == 0x7A6970) { // cbz, zip
        BOOL needsFallback = NO;
        XSCBook *book = [self openZipURL:url
                                    path:path
                              cancelFlag:cancelFlag
                           needsFallback:&needsFallback
                                   error:error];
        if (book || !needsFallback) return book;
        if (error) *error = nil;
        return [self openLibarchiveURL:url path:path cancelFlag:cancelFlag error:error];
    }

    if (extCode == 0x636274 || extCode == 0x746172) { // cbt, tar
        BOOL needsFallback = NO;
        XSCBook *book = [self openTarURL:url
                                    path:path
                              cancelFlag:cancelFlag
                           needsFallback:&needsFallback
                                   error:error];
        if (book || !needsFallback) return book;
        if (error) *error = nil;
        return [self openLibarchiveURL:url path:path cancelFlag:cancelFlag error:error];
    }

    // cbr, rar, cb7, 7z
    return [self openLibarchiveURL:url path:path cancelFlag:cancelFlag error:error];
}

#pragma mark - Directory Backend

+ (nullable instancetype)openDirectoryURL:(NSURL *)url
                                     path:(const char *)path
                               cancelFlag:(nullable const _Atomic(bool) *)cancelFlag
                                    error:(NSError * _Nullable * _Nullable)error {
    size_t rootLen = strlen(path);
    while (rootLen > 1 && path[rootLen - 1] == '/') rootLen--;
    char *rootDir = (char *)malloc(rootLen + 1);
    if (!rootDir) {
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    memcpy(rootDir, path, rootLen);
    rootDir[rootLen] = '\0';

    XSCByteArena arena = {0};
    if (!xscArenaInit(&arena, 16384)) {
        free(rootDir);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    XSCEntryList list = {0};
    size_t visited = 0;

    if (!xscWalkDirectory(rootDir, "", 0, 0, &arena, &list, &visited, cancelFlag, error)) {
        free(rootDir);
        free(list.items);
        xscArenaFree(&arena);
        return nil;
    }

    if (xscIsCancelled(cancelFlag)) {
        free(rootDir);
        free(list.items);
        xscArenaFree(&arena);
        if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
        return nil;
    }

    if (list.count == 0) {
        free(rootDir);
        free(list.items);
        xscArenaFree(&arena);
        if (error) *error = xscMakeError(XSCArchiveErrorNoImages, @"No readable images were found in this book.");
        return nil;
    }

    qsort_r(list.items, list.count, sizeof(XSCEntry), &arena, xscCompareEntries);

    if (xscIsCancelled(cancelFlag)) {
        free(rootDir);
        free(list.items);
        xscArenaFree(&arena);
        if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
        return nil;
    }

    XSCBook *book = [[XSCBook alloc] initWithSourceURL:url
                                                  kind:XSCBookKindDirectory
                                                 arena:arena
                                               entries:list.items
                                             pageCount:list.count];
    if (!book) {
        free(rootDir);
        free(list.items);
        xscArenaFree(&arena);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    book->_rootDir = rootDir;
    book->_rootDirLen = rootLen;
    return book;
}

#pragma mark - Zero-Extraction ZIP / CBZ Backend (pread + EOCD + Zip64)

/*
 Random-access ZIP reader supporting standard ZIP, Zip64, data descriptors
 (sizes are always read from the Central Directory, never from the Local File
 Header), STORE (method 0), and DEFLATE (method 8 via Apple libcompression).
 Exotic compression methods (Deflate64, BZip2, LZMA) set *needsFallback = YES
 so +openURL: seamlessly delegates to libarchive.
 */
+ (nullable instancetype)openZipURL:(NSURL *)url
                               path:(const char *)path
                         cancelFlag:(nullable const _Atomic(bool) *)cancelFlag
                      needsFallback:(BOOL *)needsFallback
                              error:(NSError * _Nullable * _Nullable)error {
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not open archive file.");
        return nil;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"The archive is not a regular file.");
        return nil;
    }
    uint64_t fileSize = (uint64_t)st.st_size;
    if (fileSize < 22) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"The archive is truncated or not a ZIP file.");
        return nil;
    }

    // 1. Read the tail (at most 65,557 bytes = 22-byte EOCD + max 65,535-byte comment)
    //    and scan backwards for End of Central Directory signature 0x06054b50.
    size_t tailLen = (size_t)(fileSize < 65557 ? fileSize : 65557);
    uint64_t tailOffset = fileSize - tailLen;
    uint8_t *tail = (uint8_t *)malloc(tailLen);
    if (!tail) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    if (!xscPreadAll(fd, tail, tailLen, (off_t)tailOffset)) {
        free(tail);
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading ZIP directory.");
        return nil;
    }

    int64_t eocdRel = -1;
    for (int64_t p = (int64_t)tailLen - 22; p >= 0; p--) {
        if (xscReadU32LE(tail + p) == 0x06054B50U) {
            uint16_t commentLen = xscReadU16LE(tail + p + 20);
            if ((uint64_t)p + 22 + commentLen == tailLen) {
                eocdRel = p;
                break;
            }
        }
    }
    if (eocdRel < 0) {
        free(tail);
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Invalid ZIP archive (missing central directory).");
        return nil;
    }

    uint64_t cdCount = xscReadU16LE(tail + eocdRel + 10);
    uint64_t cdSize = xscReadU32LE(tail + eocdRel + 12);
    uint64_t cdOffset = xscReadU32LE(tail + eocdRel + 16);
    uint64_t eocdAbs = tailOffset + (uint64_t)eocdRel;

    // 2. Check for a Zip64 EOCD Locator (0x07064b50) 20 bytes before EOCD.
    if (eocdAbs >= 20) {
        uint8_t loc[20];
        bool haveLoc = false;
        if (eocdRel >= 20) {
            memcpy(loc, tail + eocdRel - 20, 20);
            haveLoc = true;
        } else {
            haveLoc = xscPreadAll(fd, loc, 20, (off_t)(eocdAbs - 20));
        }
        if (haveLoc && xscReadU32LE(loc) == 0x07064B50U) {
            uint64_t z64Off = xscReadU64LE(loc + 8);
            if (z64Off <= fileSize && fileSize - z64Off >= 56) {
                uint8_t z64[56];
                if (xscPreadAll(fd, z64, 56, (off_t)z64Off) && xscReadU32LE(z64) == 0x06064B50U) {
                    cdCount = xscReadU64LE(z64 + 32);
                    cdSize = xscReadU64LE(z64 + 40);
                    cdOffset = xscReadU64LE(z64 + 48);
                }
            }
        }
    }
    free(tail);

    if (cdCount > kXSCMaxEntryCount || cdSize > kXSCMaxCentralDirBytes ||
        cdOffset > fileSize || cdSize > fileSize - cdOffset) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"ZIP central directory bounds are invalid.");
        return nil;
    }

    uint8_t *cdBuf = (uint8_t *)malloc(cdSize > 0 ? (size_t)cdSize : 1);
    if (!cdBuf) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    if (cdSize > 0 && !xscPreadAll(fd, cdBuf, (size_t)cdSize, (off_t)cdOffset)) {
        free(cdBuf);
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading ZIP central directory.");
        return nil;
    }

    XSCByteArena arena = {0};
    if (!xscArenaInit(&arena, 8192)) {
        free(cdBuf);
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    XSCEntryList list = {0};

    // 3. Walk Central Directory headers (0x02014b50) in memory.
    size_t cur = 0;
    size_t end = (size_t)cdSize;
    uint64_t seen = 0;
    while (cur + 46 <= end) {
        if ((++seen & 255) == 0 && xscIsCancelled(cancelFlag)) {
            free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
            return nil;
        }
        if (seen > kXSCMaxEntryCount) {
            free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Archive exceeds maximum entry limit.");
            return nil;
        }
        if (xscReadU32LE(cdBuf + cur) != 0x02014B50U) {
            free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Corrupt ZIP central directory header.");
            return nil;
        }

        uint16_t gpFlags = xscReadU16LE(cdBuf + cur + 8);
        uint16_t method = xscReadU16LE(cdBuf + cur + 10);
        uint64_t compSize = xscReadU32LE(cdBuf + cur + 20);
        uint64_t uncompSize = xscReadU32LE(cdBuf + cur + 24);
        uint16_t nameLen = xscReadU16LE(cdBuf + cur + 28);
        uint16_t extraLen = xscReadU16LE(cdBuf + cur + 30);
        uint16_t commentLen = xscReadU16LE(cdBuf + cur + 32);
        uint32_t extAttr = xscReadU32LE(cdBuf + cur + 38);
        uint64_t localOff = xscReadU32LE(cdBuf + cur + 42);

        size_t entrySize = (size_t)46 + nameLen + extraLen + commentLen;
        if (entrySize > end - cur) {
            free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Truncated ZIP central directory entry.");
            return nil;
        }
        size_t next = cur + entrySize;

        const char *rawName = (const char *)(cdBuf + cur + 46);
        const char *trimmed = NULL;
        size_t trimmedLen = 0;
        XSCPathCheck pchk = xscValidateArchivePath(rawName, nameLen, &trimmed, &trimmedLen);
        if (pchk == XSCPathUnsafe) {
            free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorUnsafePath, @"Archive contains an unsafe path.");
            return nil;
        }

        uint32_t unixMode = extAttr >> 16;
        bool isSymlink = ((unixMode & S_IFMT) == S_IFLNK);

        if (pchk == XSCPathOK && !isSymlink && xscIsImagePathBytes(trimmed, trimmedLen)) {
            if ((gpFlags & 0x0001U) != 0) {
                free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
                if (error) *error = xscMakeError(XSCArchiveErrorEncrypted, @"Encrypted ZIP archives are not supported.");
                return nil;
            }
            if (method != 0 && method != 8) {
                free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
                *needsFallback = YES;
                return nil;
            }

            // Parse Zip64 extra field (header ID 0x0001) whenever a 32-bit field is saturated.
            if (uncompSize == 0xFFFFFFFFULL || compSize == 0xFFFFFFFFULL || localOff == 0xFFFFFFFFULL) {
                size_t ep = cur + 46 + nameLen;
                size_t eEnd = ep + extraLen;
                while (ep + 4 <= eEnd) {
                    uint16_t hid = xscReadU16LE(cdBuf + ep);
                    uint16_t hlen = xscReadU16LE(cdBuf + ep + 2);
                    ep += 4;
                    if (hlen > eEnd - ep) break;
                    if (hid == 0x0001U) {
                        size_t zp = ep;
                        size_t zEnd = ep + hlen;
                        if (uncompSize == 0xFFFFFFFFULL && zp + 8 <= zEnd) {
                            uncompSize = xscReadU64LE(cdBuf + zp);
                            zp += 8;
                        }
                        if (compSize == 0xFFFFFFFFULL && zp + 8 <= zEnd) {
                            compSize = xscReadU64LE(cdBuf + zp);
                            zp += 8;
                        }
                        if (localOff == 0xFFFFFFFFULL && zp + 8 <= zEnd) {
                            localOff = xscReadU64LE(cdBuf + zp);
                        }
                        break;
                    }
                    ep += hlen;
                }
            }

            if (uncompSize > kXSCMaxPageBytes || compSize > kXSCMaxPageBytes ||
                compSize > fileSize || localOff >= fileSize) {
                free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
                if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"ZIP entry exceeds safe size bounds.");
                return nil;
            }

            XSCEntry e = {0};
            e.compressionMethod = method;
            e.dataOffset = localOff;
            e.compressedSize = compSize;
            e.uncompressedSize = uncompSize;
            if (!xscArenaAppend2(&arena, "", 0, trimmed, trimmedLen, &e.nameOffset, &e.nameLen) ||
                !xscEntryListAppend(&list, e)) {
                free(cdBuf); free(list.items); xscArenaFree(&arena); close(fd);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
                return nil;
            }
        }
        cur = next;
    }
    free(cdBuf);

    if (list.count == 0) {
        free(list.items); xscArenaFree(&arena); close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorNoImages, @"No readable images were found in this book.");
        return nil;
    }

    qsort_r(list.items, list.count, sizeof(XSCEntry), &arena, xscCompareEntries);

    XSCBook *book = [[XSCBook alloc] initWithSourceURL:url
                                                  kind:XSCBookKindZip
                                                 arena:arena
                                               entries:list.items
                                             pageCount:list.count];
    if (!book) {
        free(list.items); xscArenaFree(&arena); close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    book->_fd = fd;
    book->_fileSize = fileSize;
    return book;
}

#pragma mark - Zero-Extraction TAR / CBT Backend (pread Offset Scan)

/*
 Walks 512-byte ustar/PAX/GNU-LongName headers by seeking past each payload
 (`ceil(size / 512) * 512`) without ever reading image bytes during open.
 If the first block fails TAR checksum verification (e.g. gzip/bzip2/xz-wrapped
 .cbt), *needsFallback = YES hands off to libarchive.
 */
+ (nullable instancetype)openTarURL:(NSURL *)url
                               path:(const char *)path
                         cancelFlag:(nullable const _Atomic(bool) *)cancelFlag
                      needsFallback:(BOOL *)needsFallback
                              error:(NSError * _Nullable * _Nullable)error {
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not open archive file.");
        return nil;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"The archive is not a regular file.");
        return nil;
    }
    uint64_t fileSize = (uint64_t)st.st_size;
    if (fileSize < 512) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"The archive is truncated or not a TAR file.");
        return nil;
    }

    uint8_t blk[512];
    if (!xscPreadAll(fd, blk, 512, 0)) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading TAR header.");
        return nil;
    }
    if (!xscIsZeroBlock512(blk) && !xscVerifyTarChecksum(blk)) {
        close(fd);
        *needsFallback = YES;
        return nil;
    }

    XSCByteArena arena = {0};
    if (!xscArenaInit(&arena, 8192)) {
        close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    XSCEntryList list = {0};

    uint64_t offset = 0;
    uint64_t seen = 0;
    char *nextLongName = NULL;
    size_t nextLongNameLen = 0;
    bool nextHasPaxSize = false;
    uint64_t nextPaxSize = 0;

    while (offset <= fileSize && fileSize - offset >= 512) {
        if ((++seen & 255) == 0 && xscIsCancelled(cancelFlag)) {
            free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
            return nil;
        }
        if (seen > kXSCMaxEntryCount) {
            free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Archive exceeds maximum entry limit.");
            return nil;
        }
        if (offset > 0 && !xscPreadAll(fd, blk, 512, (off_t)offset)) {
            free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Unexpected EOF in TAR archive.");
            return nil;
        }
        if (xscIsZeroBlock512(blk)) break;

        if (!xscVerifyTarChecksum(blk)) {
            free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Invalid TAR header checksum.");
            return nil;
        }

        uint64_t size = 0;
        if (!xscParseTarOctalOrBase256(blk + 124, 12, &size)) {
            free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Invalid TAR entry size.");
            return nil;
        }
        if (nextHasPaxSize) {
            size = nextPaxSize;
            nextHasPaxSize = false;
        }

        uint64_t dataOff = offset + 512;
        // Validate bounds BEFORE rounding `size` up to 512 so `size + 511` can never wrap.
        if (size > fileSize || dataOff > fileSize - size) {
            free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"TAR entry extends past end of file.");
            return nil;
        }
        uint64_t padded = (size + 511ULL) & ~511ULL;

        uint8_t typeflag = blk[156];

        if (typeflag == 'L') {
            // GNU LongName for next entry
            if (size <= kXSCMaxMetaHeaderBytes && size > 0) {
                char *buf = (char *)malloc((size_t)size + 1);
                if (!buf || !xscPreadAll(fd, buf, (size_t)size, (off_t)dataOff)) {
                    free(buf);
                    free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
                    if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Failed reading TAR long name.");
                    return nil;
                }
                buf[size] = '\0';
                free(nextLongName);
                nextLongName = buf;
                nextLongNameLen = strnlen(nextLongName, (size_t)size);
            }
        } else if (typeflag == 'x') {
            // PAX extended header for next entry
            if (size <= kXSCMaxMetaHeaderBytes && size > 0) {
                uint8_t *pax = (uint8_t *)malloc((size_t)size);
                if (!pax || !xscPreadAll(fd, pax, (size_t)size, (off_t)dataOff)) {
                    free(pax);
                    free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
                    if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Failed reading TAR PAX header.");
                    return nil;
                }
                xscParsePaxRecords(pax, (size_t)size, &nextLongName, &nextLongNameLen, &nextHasPaxSize, &nextPaxSize);
                free(pax);
            }
        } else if (typeflag == 'g') {
            // PAX global header — skip payload
        } else {
            char stackName[260];
            const char *memberName = NULL;
            size_t memberNameLen = 0;

            if (nextLongName) {
                memberName = nextLongName;
                memberNameLen = nextLongNameLen;
            } else {
                size_t prefLen = strnlen((const char *)(blk + 345), 155);
                size_t nameLen = strnlen((const char *)blk, 100);
                if (prefLen > 0) {
                    memcpy(stackName, blk + 345, prefLen);
                    stackName[prefLen] = '/';
                    memcpy(stackName + prefLen + 1, blk, nameLen);
                    memberNameLen = prefLen + 1 + nameLen;
                    stackName[memberNameLen] = '\0';
                } else {
                    memcpy(stackName, blk, nameLen);
                    memberNameLen = nameLen;
                    stackName[memberNameLen] = '\0';
                }
                memberName = stackName;
            }

            const char *trimmed = NULL;
            size_t trimmedLen = 0;
            XSCPathCheck pchk = xscValidateArchivePath(memberName, memberNameLen, &trimmed, &trimmedLen);
            if (pchk == XSCPathUnsafe) {
                free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
                if (error) *error = xscMakeError(XSCArchiveErrorUnsafePath, @"Archive contains an unsafe path.");
                return nil;
            }

            // Only regular files ('0' or legacy '\0') become pages; hardlinks ('1') & symlinks ('2') are skipped.
            bool isRegular = (typeflag == '0' || typeflag == '\0');
            if (pchk == XSCPathOK && isRegular && xscIsImagePathBytes(trimmed, trimmedLen)) {
                if (size > kXSCMaxPageBytes) {
                    free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
                    if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"TAR entry exceeds safe size bounds.");
                    return nil;
                }
                XSCEntry e = {0};
                e.dataOffset = dataOff;
                e.uncompressedSize = size;
                if (!xscArenaAppend2(&arena, "", 0, trimmed, trimmedLen, &e.nameOffset, &e.nameLen) ||
                    !xscEntryListAppend(&list, e)) {
                    free(nextLongName); free(list.items); xscArenaFree(&arena); close(fd);
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
                    return nil;
                }
            }

            free(nextLongName);
            nextLongName = NULL;
            nextLongNameLen = 0;
        }

        if (padded > fileSize - dataOff) break;
        offset = dataOff + padded;
    }

    free(nextLongName);

    if (list.count == 0) {
        free(list.items); xscArenaFree(&arena); close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorNoImages, @"No readable images were found in this book.");
        return nil;
    }

    qsort_r(list.items, list.count, sizeof(XSCEntry), &arena, xscCompareEntries);

    XSCBook *book = [[XSCBook alloc] initWithSourceURL:url
                                                  kind:XSCBookKindTar
                                                 arena:arena
                                               entries:list.items
                                             pageCount:list.count];
    if (!book) {
        free(list.items); xscArenaFree(&arena); close(fd);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    book->_fd = fd;
    book->_fileSize = fileSize;
    return book;
}

#pragma mark - In-Process libarchive Backend (CBR / RAR4 / RAR5 / CB7 / 7z / Exotic)

/*
 Single-pass sequential stream over libarchive.2.dylib (handles solid RAR/7z
 archives without double decompression). Each libarchive reader instance is
 strictly local to this call; once open completes, the reader is freed and the
 resulting XSCBook serves pages concurrently from immutable NSData buffers (or
 stateless O_NOFOLLOW pread(2) on spilled files for >256 MiB volumes).
 */
+ (nullable instancetype)openLibarchiveURL:(NSURL *)url
                                      path:(const char *)path
                                cancelFlag:(nullable const _Atomic(bool) *)cancelFlag
                                     error:(NSError * _Nullable * _Nullable)error {
    struct archive *a = archive_read_new();
    if (!a) {
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not initialize archive reader.");
        return nil;
    }
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    if (archive_read_open_filename(a, path, 65536) != kArchiveOK) {
        const char *msg = archive_error_string(a);
        NSString *desc = msg ? [NSString stringWithUTF8String:msg] : @"The archive could not be opened.";
        archive_read_free(a);
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, desc ?: @"The archive could not be opened.");
        return nil;
    }

    XSCByteArena arena = {0};
    if (!xscArenaInit(&arena, 8192)) {
        archive_read_free(a);
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    XSCEntryList list = {0};
    NSMutableArray<NSData *> *payloads = [NSMutableArray array];
    uint64_t totalMemoryBytes = 0;
    uint64_t seen = 0;
    char *spillDir = NULL;
    uint32_t spillCounter = 0;

    uint8_t chunk[65536];
    struct archive_entry *entry = NULL;
    int rc;

    while ((rc = archive_read_next_header(a, &entry)) == kArchiveOK || rc == kArchiveWarn) {
        if (xscIsCancelled(cancelFlag)) {
            archive_read_free(a); free(list.items); xscArenaFree(&arena);
            if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
            if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
            return nil;
        }
        if (++seen > kXSCMaxEntryCount) {
            archive_read_free(a); free(list.items); xscArenaFree(&arena);
            if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Archive exceeds maximum entry limit.");
            return nil;
        }

        const char *rawName = archive_entry_pathname_utf8(entry);
        if (!rawName) rawName = archive_entry_pathname(entry);
        size_t rawLen = rawName ? strlen(rawName) : 0;

        const char *trimmed = NULL;
        size_t trimmedLen = 0;
        XSCPathCheck pchk = xscValidateArchivePath(rawName ?: "", rawLen, &trimmed, &trimmedLen);
        if (pchk == XSCPathUnsafe) {
            archive_read_free(a); free(list.items); xscArenaFree(&arena);
            if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
            if (error) *error = xscMakeError(XSCArchiveErrorUnsafePath, @"Archive contains an unsafe path.");
            return nil;
        }

        mode_t ft = archive_entry_filetype(entry);
        bool isRegular = (ft == 0 || (ft & S_IFMT) == S_IFREG);
        bool isSymlink = ((ft & S_IFMT) == S_IFLNK);

        if (pchk != XSCPathOK || isSymlink || !isRegular || !xscIsImagePathBytes(trimmed, trimmedLen)) {
            archive_read_data_skip(a);
            continue;
        }

        if (archive_entry_is_encrypted(entry) > 0) {
            archive_read_free(a); free(list.items); xscArenaFree(&arena);
            if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
            if (error) *error = xscMakeError(XSCArchiveErrorEncrypted, @"Encrypted archives are not supported.");
            return nil;
        }

        int64_t declaredSize = archive_entry_size(entry);
        if (declaredSize > (int64_t)kXSCMaxPageBytes) {
            archive_read_free(a); free(list.items); xscArenaFree(&arena);
            if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Archive entry exceeds safe size bounds.");
            return nil;
        }

        bool spillThis = (totalMemoryBytes > kXSCMaxInMemoryArchiveBytes);
        int spillFd = -1;
        uint32_t spillID = 0;
        NSMutableData *memData = nil;

        if (spillThis) {
            if (!spillDir) {
                const char *root = xscSpillWorkspaceRoot();
                if (!root || root[0] == '\0') {
                    archive_read_free(a); free(list.items); xscArenaFree(&arena);
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not initialize temporary workspace.");
                    return nil;
                }
                NSString *bookSpill = [[NSString stringWithUTF8String:root]
                    stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
                BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:bookSpill
                                                         withIntermediateDirectories:YES
                                                                          attributes:nil
                                                                               error:nil];
                if (!created) {
                    archive_read_free(a); free(list.items); xscArenaFree(&arena);
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not create temporary spill directory.");
                    return nil;
                }
                spillDir = strdup(bookSpill.fileSystemRepresentation);
                if (!spillDir) {
                    xscRemoveTreeAtPath(bookSpill.fileSystemRepresentation);
                    archive_read_free(a); free(list.items); xscArenaFree(&arena);
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
                    return nil;
                }
            }
            spillID = spillCounter++;
            char spillPath[PATH_MAX];
            int pathLen = snprintf(spillPath, sizeof(spillPath), "%s/%u.bin", spillDir, spillID);
            if (pathLen <= 0 || (size_t)pathLen >= sizeof(spillPath)) {
                archive_read_free(a); free(list.items); xscArenaFree(&arena);
                xscRemoveTreeAtPath(spillDir); free(spillDir);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Temporary spill path too long.");
                return nil;
            }
            spillFd = open(spillPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
            if (spillFd < 0) {
                archive_read_free(a); free(list.items); xscArenaFree(&arena);
                xscRemoveTreeAtPath(spillDir); free(spillDir);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not create temporary spill file.");
                return nil;
            }
        } else {
            // Cap initial preallocation so a corrupt header claiming 250 MiB cannot force
            // a massive upfront allocation before any bytes are actually decompressed.
            NSUInteger cap = (declaredSize > 0)
                ? (NSUInteger)((uint64_t)declaredSize < kXSCMaxInitialDataCap ? (uint64_t)declaredSize : kXSCMaxInitialDataCap)
                : 65536;
            memData = [NSMutableData dataWithCapacity:cap];
        }

        uint64_t pageBytes = 0;
        ssize_t n;
        while ((n = archive_read_data(a, chunk, sizeof(chunk))) > 0) {
            if (xscIsCancelled(cancelFlag)) {
                if (spillFd >= 0) close(spillFd);
                archive_read_free(a); free(list.items); xscArenaFree(&arena);
                if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
                if (error) *error = xscMakeError(XSCArchiveErrorCancelled, @"Cancelled.");
                return nil;
            }
            pageBytes += (uint64_t)n;
            if (pageBytes > kXSCMaxPageBytes) {
                if (spillFd >= 0) close(spillFd);
                archive_read_free(a); free(list.items); xscArenaFree(&arena);
                if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
                if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Decompressed page exceeds safe limit.");
                return nil;
            }
            if (spillFd >= 0) {
                size_t written = 0;
                while (written < (size_t)n) {
                    ssize_t w = write(spillFd, chunk + written, (size_t)n - written);
                    if (w < 0) {
                        if (errno == EINTR) continue;
                        close(spillFd);
                        archive_read_free(a); free(list.items); xscArenaFree(&arena);
                        if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
                        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed writing temporary spill file.");
                        return nil;
                    }
                    written += (size_t)w;
                }
            } else {
                [memData appendBytes:chunk length:(NSUInteger)n];
            }
        }
        if (spillFd >= 0) close(spillFd);

        if (n < 0) {
            const char *msg = archive_error_string(a);
            NSString *desc = msg ? [NSString stringWithUTF8String:msg] : @"Failed decompressing archive entry.";
            archive_read_free(a); free(list.items); xscArenaFree(&arena);
            if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
            if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, desc ?: @"Failed decompressing archive entry.");
            return nil;
        }

        XSCEntry e = {0};
        e.uncompressedSize = pageBytes;
        if (spillThis) {
            e.flags = 1;
            e.payloadIndex = spillID;
        } else {
            e.flags = 0;
            e.payloadIndex = (uint32_t)payloads.count;
            [payloads addObject:memData];
            totalMemoryBytes += pageBytes;
        }

        if (!xscArenaAppend2(&arena, "", 0, trimmed, trimmedLen, &e.nameOffset, &e.nameLen) ||
            !xscEntryListAppend(&list, e)) {
            archive_read_free(a); free(list.items); xscArenaFree(&arena);
            if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
            if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
            return nil;
        }
    }

    if (rc != kArchiveEOF) {
        const char *msg = archive_error_string(a);
        NSString *desc = msg ? [NSString stringWithUTF8String:msg] : @"The archive could not be read.";
        archive_read_free(a); free(list.items); xscArenaFree(&arena);
        if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
        if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, desc ?: @"The archive could not be read.");
        return nil;
    }

    archive_read_free(a);

    if (list.count == 0) {
        free(list.items); xscArenaFree(&arena);
        if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
        if (error) *error = xscMakeError(XSCArchiveErrorNoImages, @"No readable images were found in this book.");
        return nil;
    }

    qsort_r(list.items, list.count, sizeof(XSCEntry), &arena, xscCompareEntries);

    XSCBook *book = [[XSCBook alloc] initWithSourceURL:url
                                                  kind:XSCBookKindLibarchive
                                                 arena:arena
                                               entries:list.items
                                             pageCount:list.count];
    if (!book) {
        free(list.items); xscArenaFree(&arena);
        if (spillDir) { xscRemoveTreeAtPath(spillDir); free(spillDir); }
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
        return nil;
    }
    book->_memoryPayloads = [payloads copy];
    book->_spillDir = spillDir;
    return book;
}

#pragma mark - Adjacent Volume Discovery

typedef struct {
    uint32_t nameOffset;
    uint32_t nameLen;
    bool isDirectory;
} XSCSiblingEntry;

static int xscCompareSiblings(void *thunk, const void *lhsPtr, const void *rhsPtr) {
    const XSCByteArena *arena = (const XSCByteArena *)thunk;
    const XSCSiblingEntry *a = (const XSCSiblingEntry *)lhsPtr;
    const XSCSiblingEntry *b = (const XSCSiblingEntry *)rhsPtr;
    NSComparisonResult r = [XSCBook naturalCompareBytes:arena->buf + a->nameOffset
                                                 length:a->nameLen
                                              withBytes:arena->buf + b->nameOffset
                                                 length:b->nameLen];
    if (r == NSOrderedAscending) return -1;
    if (r == NSOrderedDescending) return 1;
    return 0;
}

+ (nullable NSURL *)adjacentVolumeURLFor:(NSURL *)currentURL
                                    step:(NSInteger)step
                              cancelFlag:(nullable const _Atomic(bool) *)cancelFlag {
    if (step == 0 || xscIsCancelled(cancelFlag)) return nil;

    NSURL *standardized = currentURL.URLByStandardizingPath;
    NSURL *parentURL = standardized.URLByDeletingLastPathComponent;
    const char *parentPath = parentURL.fileSystemRepresentation;
    const char *currentName = standardized.lastPathComponent.UTF8String;
    if (!parentPath || parentPath[0] == '\0' || !currentName || currentName[0] == '\0' ||
        (currentName[0] == '/' && currentName[1] == '\0')) {
        return nil;
    }
    size_t parentLen = strlen(parentPath);
    size_t currentNameLen = strlen(currentName);

    DIR *dir = opendir(parentPath);
    if (!dir) return nil;

    XSCByteArena arena = {0};
    if (!xscArenaInit(&arena, 4096)) {
        closedir(dir);
        return nil;
    }

    XSCSiblingEntry *items = NULL;
    size_t count = 0, cap = 0;

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (xscIsCancelled(cancelFlag)) {
            free(items); xscArenaFree(&arena); closedir(dir);
            return nil;
        }
        const char *name = ent->d_name;
        size_t nameLen = ent->d_namlen;
        if (nameLen == 0 || name[0] == '.') continue;

        uint8_t dType = ent->d_type;
        if (dType == DT_UNKNOWN || dType == DT_LNK) {
            char fullBuf[PATH_MAX];
            if (xscJoinPath(fullBuf, sizeof(fullBuf), parentPath, parentLen, name, nameLen) == 0) {
                continue;
            }
            struct stat st;
            if (stat(fullBuf, &st) != 0) continue;
            dType = S_ISDIR(st.st_mode) ? DT_DIR : (S_ISREG(st.st_mode) ? DT_REG : DT_UNKNOWN);
        }

        bool isDir = (dType == DT_DIR);
        bool isPotential = isDir || (dType == DT_REG && xscIsArchivePathBytes(name, nameLen));
        if (!isPotential) continue;

        if (count == cap) {
            size_t newCap = cap ? cap * 2 : 64;
            XSCSiblingEntry *grown = (XSCSiblingEntry *)realloc(items, newCap * sizeof(XSCSiblingEntry));
            if (!grown) break;
            items = grown;
            cap = newCap;
        }
        XSCSiblingEntry s = {0};
        s.isDirectory = isDir;
        if (xscArenaAppend2(&arena, "", 0, name, nameLen, &s.nameOffset, &s.nameLen)) {
            items[count++] = s;
        }
    }
    closedir(dir);

    if (count == 0) {
        free(items); xscArenaFree(&arena);
        return nil;
    }

    qsort_r(items, count, sizeof(XSCSiblingEntry), &arena, xscCompareSiblings);

    NSInteger currentIndex = -1;
    for (size_t i = 0; i < count; i++) {
        if (items[i].nameLen == currentNameLen &&
            memcmp(arena.buf + items[i].nameOffset, currentName, currentNameLen) == 0) {
            currentIndex = (NSInteger)i;
            break;
        }
    }
    if (currentIndex < 0) {
        free(items); xscArenaFree(&arena);
        return nil;
    }

    NSInteger dirStep = step > 0 ? 1 : -1;
    NSInteger idx = currentIndex + dirStep;
    NSURL *result = nil;

    while (idx >= 0 && idx < (NSInteger)count) {
        if (xscIsCancelled(cancelFlag)) break;
        XSCSiblingEntry cand = items[idx];
        const char *candName = arena.buf + cand.nameOffset;
        size_t candLen = cand.nameLen;

        if (!cand.isDirectory) {
            NSString *nsName = [[NSString alloc] initWithBytes:candName length:candLen encoding:NSUTF8StringEncoding];
            if (nsName) {
                result = [parentURL URLByAppendingPathComponent:nsName isDirectory:NO];
                break;
            }
        } else {
            char fullBuf[PATH_MAX];
            if (xscJoinPath(fullBuf, sizeof(fullBuf), parentPath, parentLen, candName, candLen) > 0) {
                bool isPkg = xscHasDot(candName, candLen) && xscIsPackageAtPath(fullBuf);
                size_t visited = 0;
                if (!isPkg && xscDirectoryContainsImage(fullBuf, 0, &visited, cancelFlag)) {
                    NSString *nsName = [[NSString alloc] initWithBytes:candName length:candLen encoding:NSUTF8StringEncoding];
                    if (nsName) {
                        result = [parentURL URLByAppendingPathComponent:nsName isDirectory:YES];
                        break;
                    }
                }
            }
        }
        idx += dirStep;
    }

    free(items);
    xscArenaFree(&arena);
    return result;
}

#pragma mark - Page Metadata & Thread-Safe Random-Access Reads

- (NSString *)pageNameAtIndex:(NSUInteger)index {
    if (index >= _pageCount) return @"";
    XSCEntry e = _entries[index];
    return [[NSString alloc] initWithBytes:_arena.buf + e.nameOffset
                                    length:e.nameLen
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

- (BOOL)isGIFAtIndex:(NSUInteger)index {
    if (index >= _pageCount) return NO;
    XSCEntry e = _entries[index];
    return xscIsGIFPathBytes(_arena.buf + e.nameOffset, e.nameLen) ? YES : NO;
}

- (nullable NSData *)copyPageDataAtIndex:(NSUInteger)index
                                   error:(NSError * _Nullable * _Nullable)error {
    if (index >= _pageCount) {
        if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Page index out of bounds.");
        return nil;
    }
    XSCEntry e = _entries[index];

    switch (_kind) {
        case XSCBookKindDirectory: {
            bool needsSlash = (_rootDirLen == 0 || _rootDir[_rootDirLen - 1] != '/');
            size_t fullLen = _rootDirLen + (needsSlash ? 1 : 0) + e.nameLen;
            char stackBuf[PATH_MAX];
            char *pathBuf = (fullLen + 1 <= sizeof(stackBuf)) ? stackBuf : (char *)malloc(fullLen + 1);
            if (!pathBuf) {
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
                return nil;
            }
            xscJoinPath(pathBuf, fullLen + 1, _rootDir, _rootDirLen, _arena.buf + e.nameOffset, e.nameLen);

            int fd = open(pathBuf, O_RDONLY | O_NOFOLLOW);
            if (pathBuf != stackBuf) free(pathBuf);
            if (fd < 0) {
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not open page file.");
                return nil;
            }
            struct stat st;
            if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 ||
                (uint64_t)st.st_size > kXSCMaxPageBytes) {
                close(fd);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Page file is unreadable.");
                return nil;
            }
            size_t sz = (size_t)st.st_size;
            NSMutableData *data = [NSMutableData dataWithLength:sz];
            if (sz > 0 && !xscPreadAll(fd, data.mutableBytes, sz, 0)) {
                close(fd);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading page file.");
                return nil;
            }
            close(fd);
            return data;
        }

        case XSCBookKindZip: {
            if (e.uncompressedSize > kXSCMaxPageBytes) {
                if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"ZIP page exceeds safe size bounds.");
                return nil;
            }
            uint8_t lfh[30];
            if (e.dataOffset > _fileSize || _fileSize - e.dataOffset < 30 ||
                !xscPreadAll(_fd, lfh, 30, (off_t)e.dataOffset) ||
                xscReadU32LE(lfh) != 0x04034B50U) {
                if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Invalid ZIP local file header.");
                return nil;
            }
            uint64_t lfhHeaderBytes = 30ULL + xscReadU16LE(lfh + 26) + xscReadU16LE(lfh + 28);
            if (lfhHeaderBytes > _fileSize - e.dataOffset) {
                if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"ZIP page extends past end of file.");
                return nil;
            }
            uint64_t payloadOff = e.dataOffset + lfhHeaderBytes;
            if (e.compressedSize > _fileSize - payloadOff) {
                if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"ZIP page extends past end of file.");
                return nil;
            }

            if (e.uncompressedSize == 0) {
                return [NSData data];
            }

            if (e.compressionMethod == 0) {
                if (e.uncompressedSize > _fileSize - payloadOff) {
                    if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Truncated STORE ZIP entry.");
                    return nil;
                }
                NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)e.uncompressedSize];
                if (!xscPreadAll(_fd, out.mutableBytes, (size_t)e.uncompressedSize, (off_t)payloadOff)) {
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading ZIP page.");
                    return nil;
                }
                return out;
            }

            if (e.compressionMethod == 8) {
                if (e.compressedSize == 0 || e.compressedSize > kXSCMaxPageBytes) {
                    if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Invalid compressed ZIP entry size.");
                    return nil;
                }
                uint8_t *compBuf = (uint8_t *)malloc((size_t)e.compressedSize);
                if (!compBuf) {
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Out of memory.");
                    return nil;
                }
                if (!xscPreadAll(_fd, compBuf, (size_t)e.compressedSize, (off_t)payloadOff)) {
                    free(compBuf);
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading compressed ZIP page.");
                    return nil;
                }

                /*
                 Decompress with streaming libcompression (COMPRESSION_ZLIB is raw
                 RFC 1951 DEFLATE). Bounding dst_size to uncompressedSize and
                 probing with a 1-byte sentinel if status == OK catches both
                 exact-fit streams whose final EOB symbol needs one extra pump
                 AND zip bombs that lie about uncompressedSize.
                 */
                NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)e.uncompressedSize];
                compression_stream stream;
                if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_OK) {
                    free(compBuf);
                    if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not initialize decompressor.");
                    return nil;
                }
                stream.src_ptr = compBuf;
                stream.src_size = (size_t)e.compressedSize;
                stream.dst_ptr = (uint8_t *)out.mutableBytes;
                stream.dst_size = (size_t)e.uncompressedSize;

                compression_status status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
                size_t produced = (size_t)e.uncompressedSize - stream.dst_size;

                bool overflowed = false;
                if (status == COMPRESSION_STATUS_OK && stream.dst_size == 0) {
                    uint8_t sentinel = 0;
                    stream.dst_ptr = &sentinel;
                    stream.dst_size = 1;
                    status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
                    if (stream.dst_size != 1) {
                        overflowed = true;
                    }
                }

                compression_stream_destroy(&stream);
                free(compBuf);

                if (overflowed || status != COMPRESSION_STATUS_END || produced != (size_t)e.uncompressedSize) {
                    if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"Failed decompressing ZIP page.");
                    return nil;
                }
                return out;
            }

            if (error) *error = xscMakeError(XSCArchiveErrorUnsupportedFormat, @"Unsupported ZIP compression method.");
            return nil;
        }

        case XSCBookKindTar: {
            if (e.uncompressedSize == 0) return [NSData data];
            if (e.dataOffset > _fileSize || e.uncompressedSize > _fileSize - e.dataOffset) {
                if (error) *error = xscMakeError(XSCArchiveErrorCorruptArchive, @"TAR page extends past end of file.");
                return nil;
            }
            NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)e.uncompressedSize];
            if (!xscPreadAll(_fd, out.mutableBytes, (size_t)e.uncompressedSize, (off_t)e.dataOffset)) {
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading TAR page.");
                return nil;
            }
            return out;
        }

        case XSCBookKindLibarchive: {
            if ((e.flags & 1) == 0) {
                if (e.payloadIndex < _memoryPayloads.count) {
                    return _memoryPayloads[e.payloadIndex];
                }
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Missing archive payload.");
                return nil;
            }
            if (!_spillDir) {
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Missing temporary spill directory.");
                return nil;
            }
            char spillPath[PATH_MAX];
            int pathLen = snprintf(spillPath, sizeof(spillPath), "%s/%u.bin", _spillDir, e.payloadIndex);
            if (pathLen <= 0 || (size_t)pathLen >= sizeof(spillPath)) {
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Spilled page path too long.");
                return nil;
            }
            int fd = open(spillPath, O_RDONLY | O_NOFOLLOW);
            if (fd < 0) {
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Could not open spilled page.");
                return nil;
            }
            NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)e.uncompressedSize];
            if (e.uncompressedSize > 0 && !xscPreadAll(fd, out.mutableBytes, (size_t)e.uncompressedSize, 0)) {
                close(fd);
                if (error) *error = xscMakeError(XSCArchiveErrorIOFailure, @"Failed reading spilled page.");
                return nil;
            }
            close(fd);
            return out;
        }
    }
}

@end
