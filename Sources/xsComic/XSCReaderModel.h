#pragma once

#import <Foundation/Foundation.h>
#import "XSCArchive.h"
#import "XSCImageStore.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XSCReadingDirection) {
    XSCReadingDirectionLTR = 0,
    XSCReadingDirectionRTL = 1,
};

typedef NS_ENUM(NSInteger, XSCPageMode) {
    XSCPageModeSingle = 0,
    XSCPageModeDouble = 1,
};

typedef NS_ENUM(NSInteger, XSCPageTurnKey) {
    XSCPageTurnKeyLeft = 0,
    XSCPageTurnKeyRight = 1,
};

@class XSCReaderModel;

@protocol XSCReaderModelDelegate <NSObject>
- (void)readerModelDidUpdateState:(XSCReaderModel *)model;
- (void)readerModel:(XSCReaderModel *)model
     displayLeftPage:(nullable XSCDecodedPage *)leftPage
           rightPage:(nullable XSCDecodedPage *)rightPage
        showEmptyCTA:(BOOL)showEmptyCTA
           isLoading:(BOOL)isLoading
          statusText:(nullable NSString *)statusText;
@end

/*
 XSCReaderModel is the reader's small, main-thread control plane.

 It owns the active XSCBook, archive-order page position, spread/direction
 presentation math, the 2-turn backward prefetch predictor, zero-hop
 synchronous cache-hit dispatch, and predictive adjacent-volume pre-warming.
 Archive I/O and image decoding stay strictly off the main thread in XSCBook
 and XSCImageStore.
 */
@interface XSCReaderModel : NSObject

@property (nonatomic, weak, nullable) id<XSCReaderModelDelegate> delegate;
@property (nonatomic, readonly) XSCImageStore *imageStore;
@property (nonatomic, readonly, nullable) XSCBook *book;
@property (nonatomic, readonly) NSUInteger currentIndex;
@property (nonatomic, readonly) XSCReadingDirection direction;
@property (nonatomic, readonly) XSCPageMode pageMode;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly, nullable) NSString *errorMessage;
@property (nonatomic, readonly) uint8_t consecutiveBackwardTurns;

/// Visible page indices in visual left-to-right display order (respects LTR/RTL and Single/Double).
@property (nonatomic, readonly) NSArray<NSNumber *> *visualPageIndices;
/// Human-readable page label e.g. "1" or "2-3" (or "1 / 120").
@property (nonatomic, readonly) NSString *pageIndicatorText;

- (instancetype)init;
- (instancetype)initWithImageStore:(XSCImageStore *)imageStore;

- (void)openURL:(NSURL *)url;
- (void)openURL:(NSURL *)url startAtEnd:(BOOL)startAtEnd;

- (void)turnPageForKey:(XSCPageTurnKey)key
   swapRTLPageTurnKeys:(BOOL)swapRTL
 continueAcrossVolumes:(BOOL)continueAcrossVolumes;

- (void)goForwardContinueAcrossVolumes:(BOOL)continueAcrossVolumes;
- (void)goBackwardContinueAcrossVolumes:(BOOL)continueAcrossVolumes;

/// 1-based page jump. Returns YES if valid and applied.
- (BOOL)jumpToOneBasedPageNumber:(NSInteger)pageNumber;

- (void)toggleDirection;
- (void)togglePageMode;

/// Pure helper exposed for deterministic unit testing of the 8-ahead / 2-behind + 2-turn backward predictor.
+ (NSArray<NSNumber *> *)prefetchOrderForCurrentIndex:(NSUInteger)currentIndex
                                            pageCount:(NSUInteger)pageCount
                                             pageMode:(XSCPageMode)pageMode
                             consecutiveBackwardTurns:(uint8_t)backwardTurns;

@end

NS_ASSUME_NONNULL_END
