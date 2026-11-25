#pragma once

#import <AppKit/AppKit.h>
#import "XSCImageStore.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XSCZoomMode) {
    XSCZoomModeFit = 0,
    XSCZoomModeCustom = 1,
};

/// Direct CAMetalLayer comic page canvas with zero-copy IOSurface -> MTLTexture binding,
/// inline MSL Lanczos-3 / Bicubic scaling, EXIF orientation, 120 Hz focal-point pinch-zoom,
/// smooth panning, and native NSImageView overlay for multi-frame animated GIFs.
@interface XSCMetalCanvas : NSView

@property (nonatomic, readonly) XSCZoomMode zoomMode;
@property (nonatomic, readonly) CGFloat zoomScale; // Effective scale (actual fitted scale in Fit mode, or custom scale)

@property (nonatomic, copy, nullable) void (^onZoomChanged)(XSCZoomMode mode, CGFloat effectiveScale);
@property (nonatomic, copy, nullable) void (^onOpenURLsDropped)(NSArray<NSURL *> *urls);
@property (nonatomic, copy, nullable) void (^onChooseBookRequested)(void);

/// Synchronously updates displayed pages and renders immediately (single-frame <0.2 ms on cache hit).
/// Pass `leftPage` (and optional `rightPage` for 2-page spread).
- (void)displayLeftPage:(nullable XSCDecodedPage *)leftPage
              rightPage:(nullable XSCDecodedPage *)rightPage
           showEmptyCTA:(BOOL)showEmptyCTA
              isLoading:(BOOL)isLoading
             statusText:(nullable NSString *)statusText;

- (void)setFitMode;
- (void)setCustomScale:(CGFloat)scale;
- (void)adjustZoomByFactor:(CGFloat)factor;
- (void)resetPan;

@end

NS_ASSUME_NONNULL_END
