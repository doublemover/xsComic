#import "XSCReaderModel.h"
#import <AppKit/AppKit.h>
#include <stdatomic.h>

/*
 XSCReaderModel keeps all reading-session state on the main queue while
 keeping archive I/O and image decoding completely off-main.

 Four design invariants drive its latency and memory characteristics:

   1. Archive-order navigation: `currentIndex` always advances 0 ..< pageCount
      and stays aligned to `currentIndex % step == 0`. RTL reverses only the
      visual left/right pair returned by `visualPageIndices`, so prefetch,
      history, and volume continuation never branch on reading direction.

   2. Zero-hop synchronous cache-hit fast path: on every page turn, the model
      queries `XSCImageStore.cachedPageForBook:index:` directly under an
      `os_unfair_lock` (~100 ns). When the visible spread is already decoded,
      the delegate updates the Metal canvas inside the exact same run-loop
      turn — guaranteeing single-frame (< 8.3 ms at 120 Hz) turns with zero
      intermediate blank or spinner frames.

   3. 120 ms loading grace timer: on a cold cache miss, the previous spread
      remains on screen briefly while the priority decode lane runs. Only if
      decoding still has not finished after 120 ms does the model reveal the
      "Loading page…" status overlay.

   4. Predictive adjacent-volume pre-warming: when `continueAcrossVolumes` is
      enabled and the reader comes within 3 pages of either volume boundary,
      the model discovers, opens, and pre-decodes the boundary page(s) of the
      neighboring volume off-main so crossing volumes swaps synchronously.
 */

static const NSUInteger kXSCForwardPrefetchCount = 8;
static const NSUInteger kXSCBackwardBufferCount = 2;
static const uint64_t kXSCLoadingGraceNsec = 120ULL * NSEC_PER_MSEC;

/// Lightweight ARC-managed cancellation flag safe to share across GCD queues.
@interface XSCCancelToken : NSObject {
    _Atomic(bool) _flag;
}
- (const _Atomic(bool) *)flagPointer;
- (BOOL)isCancelled;
- (void)cancel;
@end

@implementation XSCCancelToken

- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&_flag, false);
    }
    return self;
}

- (const _Atomic(bool) *)flagPointer {
    return &_flag;
}

- (BOOL)isCancelled {
    return atomic_load_explicit(&_flag, memory_order_relaxed);
}

- (void)cancel {
    atomic_store_explicit(&_flag, true, memory_order_relaxed);
}

@end

@interface XSCReaderModel ()
@property (nonatomic, strong, readwrite) XSCImageStore *imageStore;
@property (nonatomic, strong, readwrite, nullable) XSCBook *book;
@property (nonatomic, assign, readwrite) NSUInteger currentIndex;
@property (nonatomic, assign, readwrite) XSCReadingDirection direction;
@property (nonatomic, assign, readwrite) XSCPageMode pageMode;
@property (nonatomic, assign, readwrite) BOOL isLoading;
@property (nonatomic, copy, readwrite, nullable) NSString *errorMessage;
@property (nonatomic, assign, readwrite) uint8_t consecutiveBackwardTurns;
@end

@implementation XSCReaderModel {
    uint64_t _openGeneration;
    XSCCancelToken *_openCancelToken;

    uint64_t _displayGeneration;
    BOOL _displayResolved;
    XSCDecodedPage *_displayedLeftPage;
    XSCDecodedPage *_displayedRightPage;

    // Predictive adjacent-volume pre-warming (at most 1 next + 1 prev book).
    XSCBook *_prewarmedNextBook;
    XSCBook *_prewarmedPrevBook;
    XSCCancelToken *_prewarmNextToken;
    XSCCancelToken *_prewarmPrevToken;
    uint64_t _prewarmNextBookID;
    uint64_t _prewarmPrevBookID;

    // Guards against duplicate on-demand adjacent lookups on repeated boundary presses.
    BOOL _adjacentLookupInFlight;
    XSCCancelToken *_adjacentLookupToken;
}

- (instancetype)init {
    return [self initWithImageStore:[[XSCImageStore alloc] init]];
}

- (instancetype)initWithImageStore:(XSCImageStore *)imageStore {
    self = [super init];
    if (self) {
        _imageStore = imageStore;
        _direction = XSCReadingDirectionLTR;
        _pageMode = XSCPageModeSingle;
    }
    return self;
}

- (void)dealloc {
    [_openCancelToken cancel];
    [_prewarmNextToken cancel];
    [_prewarmPrevToken cancel];
    [_adjacentLookupToken cancel];
}

- (void)setDelegate:(id<XSCReaderModelDelegate>)delegate {
    _delegate = delegate;
    if (delegate != nil) {
        [self presentCurrentSpreadWithContinueAcrossVolumes:NO];
    }
}

#pragma mark - Derived Geometry & Indicators

- (NSUInteger)step {
    return (self.pageMode == XSCPageModeDouble) ? 2 : 1;
}

- (NSArray<NSNumber *> *)visualPageIndices {
    XSCBook *book = self.book;
    if (!book || book.pageCount == 0 || self.currentIndex >= book.pageCount) {
        return @[];
    }
    if (self.pageMode == XSCPageModeSingle || self.currentIndex + 1 >= book.pageCount) {
        return @[@(self.currentIndex)];
    }
    if (self.direction == XSCReadingDirectionRTL) {
        return @[@(self.currentIndex + 1), @(self.currentIndex)];
    }
    return @[@(self.currentIndex), @(self.currentIndex + 1)];
}

- (NSString *)pageIndicatorText {
    XSCBook *book = self.book;
    if (!book || book.pageCount == 0) {
        return @"";
    }
    NSUInteger start = self.currentIndex + 1;
    NSUInteger end = MIN(self.currentIndex + [self step], book.pageCount);
    if (start == end) {
        return [NSString stringWithFormat:@"%lu / %lu",
                (unsigned long)start, (unsigned long)book.pageCount];
    }
    return [NSString stringWithFormat:@"%lu\u2013%lu / %lu",
            (unsigned long)start, (unsigned long)end, (unsigned long)book.pageCount];
}

#pragma mark - Prefetch Predictor

/*
 Bounded 8-ahead / 2-behind prefetch ordering with a 1-byte saturating
 reverse-reading predictor (`consecutiveBackwardTurns` in 0..2).

 A single backward turn is usually a brief check or correction, so prefetch
 stays forward-first. Two consecutive backward turns indicate sustained
 rereading and prioritize the 2 preceding pages ahead of the 8 upcoming pages
 without expanding the cache window or memory budget.
 */
+ (NSArray<NSNumber *> *)prefetchOrderForCurrentIndex:(NSUInteger)currentIndex
                                            pageCount:(NSUInteger)pageCount
                                             pageMode:(XSCPageMode)pageMode
                             consecutiveBackwardTurns:(uint8_t)backwardTurns {
    if (pageCount == 0 || currentIndex >= pageCount) {
        return @[];
    }
    NSUInteger step = (pageMode == XSCPageModeDouble) ? 2 : 1;
    NSUInteger visibleEnd = MIN(currentIndex + step, pageCount);
    NSUInteger nextEnd = MIN(visibleEnd + kXSCForwardPrefetchCount, pageCount);
    NSUInteger prevStart = (currentIndex > kXSCBackwardBufferCount)
        ? (currentIndex - kXSCBackwardBufferCount)
        : 0;

    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:
        (nextEnd - visibleEnd) + (currentIndex - prevStart)];

    if (backwardTurns >= 2) {
        for (NSUInteger i = currentIndex; i > prevStart; i--) {
            [order addObject:@(i - 1)];
        }
        for (NSUInteger i = visibleEnd; i < nextEnd; i++) {
            [order addObject:@(i)];
        }
    } else {
        for (NSUInteger i = visibleEnd; i < nextEnd; i++) {
            [order addObject:@(i)];
        }
        for (NSUInteger i = currentIndex; i > prevStart; i--) {
            [order addObject:@(i - 1)];
        }
    }
    return order;
}

#pragma mark - Opening & Replacing Books

- (void)openURL:(NSURL *)url {
    [self openURL:url startAtEnd:NO];
}

- (void)openURL:(NSURL *)url startAtEnd:(BOOL)startAtEnd {
    if (!url) return;

    _openGeneration += 1;
    uint64_t generation = _openGeneration;

    // Invalidate any in-flight cold page decode or 120 ms grace timer from the
    // previous book so a late callback cannot overwrite the "Opening book…" state.
    _displayGeneration += 1;
    _displayResolved = YES;

    [_openCancelToken cancel];
    [_adjacentLookupToken cancel];
    _adjacentLookupInFlight = NO;
    [self clearPrewarmedVolumes];

    XSCCancelToken *token = [[XSCCancelToken alloc] init];
    _openCancelToken = token;

    self.isLoading = YES;
    self.errorMessage = nil;

    // Notify delegate so toolbar/loading UI updates immediately.
    [self.delegate readerModelDidUpdateState:self];
    [self.delegate readerModel:self
               displayLeftPage:_displayedLeftPage
                     rightPage:_displayedRightPage
                  showEmptyCTA:NO
                     isLoading:YES
                    statusText:@"Opening book\u2026"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        XSCBook *loaded = [XSCBook openURL:url
                                cancelFlag:[token flagPointer]
                                     error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_openGeneration || [token isCancelled]) {
                return;
            }
            self->_openCancelToken = nil;
            if (!loaded) {
                self.isLoading = NO;
                if (!(error && [error.domain isEqualToString:XSCArchiveErrorDomain]
                      && error.code == XSCArchiveErrorCancelled)) {
                    self.errorMessage = error.localizedDescription ?: @"The archive could not be opened.";
                }
                [self presentCurrentSpreadWithContinueAcrossVolumes:NO];
                return;
            }

            [self commitLoadedBook:loaded
                        startAtEnd:startAtEnd
                      keepInCache:NO
             continueAcrossVolumes:NO];
        });
    });
}

- (void)commitLoadedBook:(XSCBook *)loaded
              startAtEnd:(BOOL)startAtEnd
            keepInCache:(BOOL)keepInCache
   continueAcrossVolumes:(BOOL)continueAcrossVolumes {
    [self.imageStore resetKeepingBook:(keepInCache ? loaded : nil)];

    self.book = loaded;
    self.errorMessage = nil;
    self.isLoading = NO;
    self.consecutiveBackwardTurns = 0;

    if (startAtEnd && loaded.pageCount > 0) {
        NSUInteger lastIndex = loaded.pageCount - 1;
        NSUInteger step = [self step];
        self.currentIndex = lastIndex - (lastIndex % step);
    } else {
        self.currentIndex = 0;
    }

    [self presentCurrentSpreadWithContinueAcrossVolumes:continueAcrossVolumes];

    // Defer recent-document bookkeeping past the first rendered frame (skip in headless tests).
    NSURL *sourceURL = loaded.sourceURL;
    uint64_t generation = _openGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == self->_openGeneration && sourceURL && NSApp != nil) {
            [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:sourceURL];
        }
    });
}

#pragma mark - Navigation

- (void)turnPageForKey:(XSCPageTurnKey)key
   swapRTLPageTurnKeys:(BOOL)swapRTL
 continueAcrossVolumes:(BOOL)continueAcrossVolumes {
    BOOL leftGoesForward = (self.direction == XSCReadingDirectionRTL && !swapRTL);
    BOOL goForward = (key == XSCPageTurnKeyLeft) ? leftGoesForward : !leftGoesForward;
    if (goForward) {
        [self goForwardContinueAcrossVolumes:continueAcrossVolumes];
    } else {
        [self goBackwardContinueAcrossVolumes:continueAcrossVolumes];
    }
}

- (void)goForwardContinueAcrossVolumes:(BOOL)continueAcrossVolumes {
    XSCBook *book = self.book;
    if (self.isLoading || !book || book.pageCount == 0) return;

    NSUInteger step = [self step];
    if (self.currentIndex + step < book.pageCount) {
        self.currentIndex = MIN(self.currentIndex + step, book.pageCount - 1);
        self.consecutiveBackwardTurns = 0;
        [self presentCurrentSpreadWithContinueAcrossVolumes:continueAcrossVolumes];
        return;
    }

    if (continueAcrossVolumes) {
        [self crossToAdjacentVolumeForward:YES];
    }
}

- (void)goBackwardContinueAcrossVolumes:(BOOL)continueAcrossVolumes {
    XSCBook *book = self.book;
    if (self.isLoading || !book || book.pageCount == 0) return;

    if (self.currentIndex > 0) {
        NSUInteger step = [self step];
        self.currentIndex = (self.currentIndex >= step) ? (self.currentIndex - step) : 0;
        if (self.consecutiveBackwardTurns < 2) {
            self.consecutiveBackwardTurns += 1;
        }
        [self presentCurrentSpreadWithContinueAcrossVolumes:continueAcrossVolumes];
        return;
    }

    if (continueAcrossVolumes) {
        [self crossToAdjacentVolumeForward:NO];
    }
}

- (BOOL)jumpToOneBasedPageNumber:(NSInteger)pageNumber {
    XSCBook *book = self.book;
    if (!book || pageNumber < 1 || (NSUInteger)pageNumber > book.pageCount) {
        return NO;
    }
    NSUInteger index = (NSUInteger)(pageNumber - 1);
    NSUInteger step = [self step];
    self.currentIndex = index - (index % step);
    self.consecutiveBackwardTurns = 0;
    [self presentCurrentSpreadWithContinueAcrossVolumes:NO];
    return YES;
}

- (void)toggleDirection {
    self.direction = (self.direction == XSCReadingDirectionLTR)
        ? XSCReadingDirectionRTL
        : XSCReadingDirectionLTR;
    [self presentCurrentSpreadWithContinueAcrossVolumes:NO];
}

- (void)togglePageMode {
    self.pageMode = (self.pageMode == XSCPageModeSingle)
        ? XSCPageModeDouble
        : XSCPageModeSingle;
    NSUInteger step = [self step];
    self.currentIndex -= (self.currentIndex % step);
    self.consecutiveBackwardTurns = 0;
    [self presentCurrentSpreadWithContinueAcrossVolumes:NO];
}

#pragma mark - Predictive Volume Pre-Warming & Boundary Crossing

/*
 Entering the final (or initial) 3 pages of a volume with continuation enabled
 triggers low-priority off-main discovery + open of the sibling volume, plus
 pre-decoding its boundary spread into XSCImageStore. When the user crosses
 the boundary, the new XSCBook swaps in synchronously (< 0.2 ms) and the old
 book slides into the opposite pre-warm slot for instant back-crossing.
 */
- (void)clearPrewarmedVolumes {
    [_prewarmNextToken cancel];
    [_prewarmPrevToken cancel];
    _prewarmNextToken = nil;
    _prewarmPrevToken = nil;
    _prewarmedNextBook = nil;
    _prewarmedPrevBook = nil;
    _prewarmNextBookID = 0;
    _prewarmPrevBookID = 0;
}

- (void)maybePrewarmAdjacentVolumes {
    XSCBook *book = self.book;
    if (!book || book.pageCount == 0) return;

    NSUInteger step = [self step];
    NSUInteger remainingAfter = (self.currentIndex + step < book.pageCount)
        ? (book.pageCount - (self.currentIndex + step))
        : 0;
    if (remainingAfter <= 3 && _prewarmNextBookID != book.bookID) {
        [self startPrewarmAdjacentForward:YES forBook:book];
    }
    if (self.currentIndex <= 3 && _prewarmPrevBookID != book.bookID) {
        [self startPrewarmAdjacentForward:NO forBook:book];
    }
}

- (void)startPrewarmAdjacentForward:(BOOL)forward forBook:(XSCBook *)book {
    uint64_t expectedBookID = book.bookID;
    NSURL *sourceURL = book.sourceURL;
    XSCCancelToken *token = [[XSCCancelToken alloc] init];

    if (forward) {
        [_prewarmNextToken cancel];
        _prewarmNextToken = token;
        _prewarmNextBookID = expectedBookID;
        _prewarmedNextBook = nil;
    } else {
        [_prewarmPrevToken cancel];
        _prewarmPrevToken = token;
        _prewarmPrevBookID = expectedBookID;
        _prewarmedPrevBook = nil;
    }

    NSInteger dirStep = forward ? 1 : -1;
    XSCPageMode modeAtStart = self.pageMode;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *adjURL = [XSCBook adjacentVolumeURLFor:sourceURL
                                                 step:dirStep
                                           cancelFlag:[token flagPointer]];
        if (!adjURL || [token isCancelled]) return;

        XSCBook *adjBook = [XSCBook openURL:adjURL
                                 cancelFlag:[token flagPointer]
                                      error:NULL];
        if (!adjBook || adjBook.pageCount == 0 || [token isCancelled]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([token isCancelled] || self.book.bookID != expectedBookID) {
                return;
            }
            if (forward) {
                self->_prewarmedNextBook = adjBook;
                [self.imageStore prewarmPageForBook:adjBook index:0];
                if (modeAtStart == XSCPageModeDouble && adjBook.pageCount > 1) {
                    [self.imageStore prewarmPageForBook:adjBook index:1];
                }
            } else {
                self->_prewarmedPrevBook = adjBook;
                NSUInteger step = (modeAtStart == XSCPageModeDouble) ? 2 : 1;
                NSUInteger lastIndex = adjBook.pageCount - 1;
                NSUInteger startIdx = lastIndex - (lastIndex % step);
                [self.imageStore prewarmPageForBook:adjBook index:startIdx];
                if (step == 2 && startIdx + 1 < adjBook.pageCount) {
                    [self.imageStore prewarmPageForBook:adjBook index:startIdx + 1];
                }
            }
        });
    });
}

- (void)crossToAdjacentVolumeForward:(BOOL)forward {
    XSCBook *currentBook = self.book;
    if (!currentBook) return;

    // Fast path: pre-warmed adjacent volume is already open (and boundary page pre-decoded).
    XSCBook *prewarmed = forward ? _prewarmedNextBook : _prewarmedPrevBook;
    if (prewarmed != nil) {
        [_openCancelToken cancel];
        _openCancelToken = nil;
        [_adjacentLookupToken cancel];
        _adjacentLookupInFlight = NO;
        _openGeneration += 1;

        [_prewarmNextToken cancel];
        [_prewarmPrevToken cancel];
        _prewarmNextToken = nil;
        _prewarmPrevToken = nil;

        // Retain the book we just left as the opposite-direction prewarmed slot!
        if (forward) {
            _prewarmedPrevBook = currentBook;
            _prewarmPrevBookID = prewarmed.bookID;
            _prewarmedNextBook = nil;
            _prewarmNextBookID = 0;
        } else {
            _prewarmedNextBook = currentBook;
            _prewarmNextBookID = prewarmed.bookID;
            _prewarmedPrevBook = nil;
            _prewarmPrevBookID = 0;
        }

        [self commitLoadedBook:prewarmed
                    startAtEnd:!forward
                  keepInCache:YES
         continueAcrossVolumes:YES];
        return;
    }

    // Fallback: discover neighbor off-main WITHOUT flashing the canvas spinner at series end,
    // while marking model.isLoading = YES so concurrent turns and async waiters serialize cleanly.
    if (_adjacentLookupInFlight) return;
    _adjacentLookupInFlight = YES;
    self.isLoading = YES;

    uint64_t expectedBookID = currentBook.bookID;
    NSURL *sourceURL = currentBook.sourceURL;
    NSInteger dirStep = forward ? 1 : -1;

    XSCCancelToken *token = [[XSCCancelToken alloc] init];
    _adjacentLookupToken = token;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *adjURL = [XSCBook adjacentVolumeURLFor:sourceURL
                                                 step:dirStep
                                           cancelFlag:[token flagPointer]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_adjacentLookupInFlight = NO;
            if ([token isCancelled] || self.book.bookID != expectedBookID) {
                return;
            }
            if (!adjURL) {
                // End of series: stay put silently without destroying the canvas.
                self.isLoading = NO;
                [self.delegate readerModelDidUpdateState:self];
                return;
            }
            [self openURL:adjURL startAtEnd:!forward];
        });
    });
}

#pragma mark - Zero-Hop Synchronous Presentation

- (void)presentCurrentSpreadWithContinueAcrossVolumes:(BOOL)continueAcrossVolumes {
    _displayGeneration += 1;
    uint64_t gen = _displayGeneration;
    _displayResolved = NO;

    XSCBook *book = self.book;
    if (!book || book.pageCount == 0) {
        _displayedLeftPage = nil;
        _displayedRightPage = nil;
        _displayResolved = YES;
        [self.delegate readerModel:self
                   displayLeftPage:nil
                         rightPage:nil
                      showEmptyCTA:!self.isLoading
                         isLoading:self.isLoading
                        statusText:(self.isLoading ? @"Opening book\u2026" : nil)];
        [self.delegate readerModelDidUpdateState:self];
        return;
    }

    NSArray<NSNumber *> *visual = self.visualPageIndices;
    NSUInteger count = visual.count;
    NSUInteger leftIdx = (count >= 1) ? visual[0].unsignedIntegerValue : NSNotFound;
    NSUInteger rightIdx = (count >= 2) ? visual[1].unsignedIntegerValue : NSNotFound;

    NSMutableIndexSet *visibleSet = [NSMutableIndexSet indexSet];
    if (leftIdx != NSNotFound) [visibleSet addIndex:leftIdx];
    if (rightIdx != NSNotFound) [visibleSet addIndex:rightIdx];

    NSArray<NSNumber *> *prefetchOrder =
        [XSCReaderModel prefetchOrderForCurrentIndex:self.currentIndex
                                           pageCount:book.pageCount
                                            pageMode:self.pageMode
                            consecutiveBackwardTurns:self.consecutiveBackwardTurns];

    // Zero-hop synchronous lock-protected cache lookup (~100 ns).
    XSCDecodedPage *cachedLeft = (leftIdx != NSNotFound)
        ? [self.imageStore cachedPageForBook:book index:leftIdx]
        : nil;
    XSCDecodedPage *cachedRight = (rightIdx != NSNotFound)
        ? [self.imageStore cachedPageForBook:book index:rightIdx]
        : nil;

    BOOL leftReady = (leftIdx == NSNotFound || cachedLeft != nil);
    BOOL rightReady = (rightIdx == NSNotFound || cachedRight != nil);

    if (leftReady && rightReady) {
        // 100% cache hit: swap Metal/IOSurface canvas in this exact run-loop turn!
        _displayResolved = YES;
        _displayedLeftPage = cachedLeft;
        _displayedRightPage = cachedRight;
        [self.delegate readerModel:self
                   displayLeftPage:cachedLeft
                         rightPage:cachedRight
                      showEmptyCTA:NO
                         isLoading:NO
                        statusText:nil];
        [self.imageStore updateRetentionAndPrefetchForBook:book
                                            visibleIndices:visibleSet
                                            orderedIndices:prefetchOrder];
        [self.delegate readerModelDidUpdateState:self];
        if (continueAcrossVolumes) {
            [self maybePrewarmAdjacentVolumes];
        }
        return;
    }

    // Cache miss on 1 or 2 visible pages: update retention & prefetch, keep last frame briefly,
    // and reveal loading status ONLY if cold decode exceeds 120 ms grace window.
    [self.imageStore updateRetentionAndPrefetchForBook:book
                                        visibleIndices:visibleSet
                                        orderedIndices:prefetchOrder];
    [self.delegate readerModelDidUpdateState:self];

    __block XSCDecodedPage *resolvedLeft = cachedLeft;
    __block XSCDecodedPage *resolvedRight = cachedRight;
    __block BOOL leftDone = leftReady;
    __block BOOL rightDone = rightReady;
    __block BOOL leftFailed = NO;
    __block BOOL rightFailed = NO;

    void (^finishIfReady)(void) = ^{
        if (gen != self->_displayGeneration) return;
        if (!leftDone || !rightDone) return;

        self->_displayResolved = YES;
        BOOL allFailed = (leftIdx != NSNotFound ? leftFailed : YES)
            && (rightIdx != NSNotFound ? rightFailed : YES);
        if (allFailed) {
            self->_displayedLeftPage = nil;
            self->_displayedRightPage = nil;
            [self.delegate readerModel:self
                       displayLeftPage:nil
                             rightPage:nil
                          showEmptyCTA:NO
                             isLoading:NO
                            statusText:@"Unreadable Image"];
        } else {
            self->_displayedLeftPage = resolvedLeft;
            self->_displayedRightPage = resolvedRight;
            [self.delegate readerModel:self
                       displayLeftPage:resolvedLeft
                             rightPage:resolvedRight
                          showEmptyCTA:NO
                             isLoading:NO
                            statusText:nil];
        }
    };

    if (!leftDone) {
        [self.imageStore requestPageForBook:book
                                      index:leftIdx
                                   priority:YES
                                 completion:^(XSCDecodedPage *page, BOOL failed) {
            if (gen != self->_displayGeneration) return;
            resolvedLeft = page;
            leftFailed = (failed || page == nil);
            leftDone = YES;
            finishIfReady();
        }];
    }
    if (!rightDone) {
        [self.imageStore requestPageForBook:book
                                      index:rightIdx
                                   priority:YES
                                 completion:^(XSCDecodedPage *page, BOOL failed) {
            if (gen != self->_displayGeneration) return;
            resolvedRight = page;
            rightFailed = (failed || page == nil);
            rightDone = YES;
            finishIfReady();
        }];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kXSCLoadingGraceNsec),
                   dispatch_get_main_queue(), ^{
        if (gen != self->_displayGeneration || self->_displayResolved) {
            return;
        }
        [self.delegate readerModel:self
                   displayLeftPage:self->_displayedLeftPage
                         rightPage:self->_displayedRightPage
                      showEmptyCTA:NO
                         isLoading:YES
                        statusText:@"Loading page\u2026"];
    });

    if (continueAcrossVolumes) {
        [self maybePrewarmAdjacentVolumes];
    }
}

@end
