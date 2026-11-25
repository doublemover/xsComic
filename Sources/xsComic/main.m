#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "XSCArchive.h"
#import "XSCImageStore.h"
#import "XSCMetalCanvas.h"
#import "XSCReaderModel.h"

/*
 Pure-AppKit shell for xsComic (arm64, macOS 14+).

 Eliminating SwiftUI/AttributeGraph/NSHostingView cuts cold launch to ~40-70 ms
 and removes ~15-25 MB of idle UI footprint while unlocking two critical
 responsiveness paths:

   1. Parallel Finder launch: `application:openURLs:` fires during launch
      before window construction finishes, starting archive open + page-1
      decode in parallel with NSWindow and NSToolbar setup.

   2. Zero-hop key dispatch: `XSCWindow.sendEvent:` intercepts page-turn keys
      directly before `NSMenu.performKeyEquivalent:` (unless the first
      responder is an NSTextView editing the inline page-jump field). On a
      cache hit, keypress -> XSCReaderModel -> os_unfair_lock cache lookup ->
      CAMetalLayer draw completes synchronously in the same run-loop turn.
 */

static NSString * const kPrefSwapRTLPageTurnKeys = @"swapRTLPageTurnKeys";
static NSString * const kPrefContinueAcrossVolumes = @"continueAcrossVolumes";
static NSString * const kPrefUseAlternateIcon = @"useAlternateIcon";

static NSToolbarIdentifier const kXSCToolbarID = @"XSCToolbar";
static NSToolbarItemIdentifier const kToolbarSidebarID = @"sidebar";
static NSToolbarItemIdentifier const kToolbarOpenID = @"open";
static NSToolbarItemIdentifier const kToolbarDirectionID = @"direction";
static NSToolbarItemIdentifier const kToolbarPageModeID = @"pageMode";
static NSToolbarItemIdentifier const kToolbarPageIndicatorID = @"pageIndicator";
static NSToolbarItemIdentifier const kToolbarZoomOutID = @"zoomOut";
static NSToolbarItemIdentifier const kToolbarZoomLabelID = @"zoomLabel";
static NSToolbarItemIdentifier const kToolbarZoomInID = @"zoomIn";

#pragma mark - Preferences Helpers

static BOOL XSCPrefBool(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

static void XSCApplyAppIconAsync(BOOL useAlternate) {
    if (!useAlternate) {
        NSApp.applicationIconImage = nil;
        return;
    }
    // Capture native icon on main thread before dispatching SVG rasterization off-main.
    NSImage *nativeIcon = [NSApp.applicationIconImage copy];
    NSURL *svgURL = [[NSBundle mainBundle] URLForResource:@"AppIcon-Azusa" withExtension:@"svg"];
    if (!nativeIcon || !svgURL) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSImage *artwork = [[NSImage alloc] initWithContentsOfURL:svgURL];
        if (!artwork) return;

        NSImage *composited = [NSImage imageWithSize:NSMakeSize(256, 256)
                                             flipped:NO
                                      drawingHandler:^BOOL(NSRect dstRect) {
            [artwork drawInRect:dstRect
                       fromRect:NSZeroRect
                      operation:NSCompositingOperationCopy
                       fraction:1.0];
            [nativeIcon drawInRect:dstRect
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationDestinationIn
                          fraction:1.0];
            return YES;
        }];
        // Force realization off-main by drawing into a bitmap rep.
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:256
                          pixelsHigh:256
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSCalibratedRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:0];
        if (rep) {
            NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:ctx];
            [composited drawInRect:NSMakeRect(0, 0, 256, 256)
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationCopy
                          fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];
            NSImage *finalIcon = [[NSImage alloc] initWithSize:NSMakeSize(256, 256)];
            [finalIcon addRepresentation:rep];
            composited = finalIcon;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (XSCPrefBool(kPrefUseAlternateIcon)) {
                NSApp.applicationIconImage = composited;
            }
        });
    });
}

#pragma mark - Dynamic Separator & Direct Key-Handling Window

@interface XSCDividerView : NSView
@end

@implementation XSCDividerView

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = NSColor.separatorColor.CGColor;
}

@end

@protocol XSCKeyInterceptDelegate <NSObject>
- (BOOL)handleDirectKeyEvent:(NSEvent *)event;
@end

@interface XSCWindow : NSWindow
@property (nonatomic, weak, nullable) id<XSCKeyInterceptDelegate> keyDelegate;
@end

@implementation XSCWindow

- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        if (![self.firstResponder isKindOfClass:[NSTextView class]]) {
            if ([self.keyDelegate handleDirectKeyEvent:event]) {
                return;
            }
        }
    }
    [super sendEvent:event];
}

@end

#pragma mark - Reader Window Controller

@interface XSCWindowController : NSWindowController <
    XSCReaderModelDelegate,
    XSCKeyInterceptDelegate,
    NSToolbarDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate
>
- (instancetype)initWithModel:(XSCReaderModel *)model;
- (void)chooseBook:(nullable id)sender;
- (void)turnLeft:(nullable id)sender;
- (void)turnRight:(nullable id)sender;
- (void)toggleDirection:(nullable id)sender;
- (void)togglePageMode:(nullable id)sender;
- (void)beginPageJump:(nullable id)sender;
- (void)zoomToWindow:(nullable id)sender;
- (void)zoomActualSize:(nullable id)sender;
- (void)zoomIn:(nullable id)sender;
- (void)zoomOut:(nullable id)sender;
- (void)toggleSidebar:(nullable id)sender;
@end

@implementation XSCWindowController {
    XSCReaderModel *_model;
    XSCMetalCanvas *_canvas;

    // Sidebar
    NSScrollView *_sidebarScroll;
    NSTableView *_sidebarTable;
    XSCDividerView *_sidebarDivider;
    NSLayoutConstraint *_sidebarWidthConstraint;
    NSLayoutConstraint *_sidebarDividerWidthConstraint;
    BOOL _showsSidebar;
    BOOL _updatingSidebarSelection;
    uint64_t _lastSidebarBookID;
    NSUInteger _lastPresentedIndex;

    // Toolbar controls
    NSSegmentedControl *_directionSegment;
    NSSegmentedControl *_pageModeSegment;
    NSTextField *_pageField;
    BOOL _isEditingPageJump;
    NSButton *_zoomLabelButton;

    NSString *_lastShownError;
}

- (instancetype)initWithModel:(XSCReaderModel *)model {
    NSRect frame = NSMakeRect(0, 0, 1024, 768);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
        | NSWindowStyleMaskClosable
        | NSWindowStyleMaskMiniaturizable
        | NSWindowStyleMaskResizable;
    XSCWindow *window = [[XSCWindow alloc] initWithContentRect:frame
                                                     styleMask:style
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    window.title = @"xsComic";
    window.contentMinSize = NSMakeSize(640, 480);
    [window center];
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

    self = [super initWithWindow:window];
    if (self) {
        _model = model;
        window.keyDelegate = self;
        [self buildContentHierarchy];
        [self buildToolbar];
        _model.delegate = self;
    }
    return self;
}

- (void)buildContentHierarchy {
    NSView *root = self.window.contentView;

    // Sidebar table (150pt collapsible)
    _sidebarTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _sidebarTable.headerView = nil;
    _sidebarTable.rowHeight = 24.0;
    _sidebarTable.intercellSpacing = NSMakeSize(0, 2);
    _sidebarTable.allowsMultipleSelection = YES;
    _sidebarTable.allowsEmptySelection = YES;
    _sidebarTable.backgroundColor = [NSColor clearColor];
    _sidebarTable.dataSource = self;
    _sidebarTable.delegate = self;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"page"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_sidebarTable addTableColumn:col];

    _sidebarScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _sidebarScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _sidebarScroll.documentView = _sidebarTable;
    _sidebarScroll.hasVerticalScroller = YES;
    _sidebarScroll.autohidesScrollers = YES;
    _sidebarScroll.drawsBackground = NO;
    _sidebarScroll.hidden = YES;

    _sidebarDivider = [[XSCDividerView alloc] initWithFrame:NSZeroRect];
    _sidebarDivider.translatesAutoresizingMaskIntoConstraints = NO;
    _sidebarDivider.wantsLayer = YES;
    _sidebarDivider.hidden = YES;

    // Metal page canvas
    _canvas = [[XSCMetalCanvas alloc] initWithFrame:root.bounds];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;

    __weak typeof(self) weakSelf = self;
    _canvas.onZoomChanged = ^(XSCZoomMode mode, CGFloat effectiveScale) {
        [weakSelf updateZoomLabelForMode:mode scale:effectiveScale];
    };
    _canvas.onOpenURLsDropped = ^(NSArray<NSURL *> *urls) {
        if (urls.firstObject) {
            [weakSelf openBookURL:urls.firstObject];
        }
    };
    _canvas.onChooseBookRequested = ^{
        [weakSelf chooseBook:nil];
    };

    [root addSubview:_sidebarScroll];
    [root addSubview:_sidebarDivider];
    [root addSubview:_canvas];

    _sidebarWidthConstraint = [_sidebarScroll.widthAnchor constraintEqualToConstant:0.0];
    _sidebarDividerWidthConstraint = [_sidebarDivider.widthAnchor constraintEqualToConstant:0.0];

    [NSLayoutConstraint activateConstraints:@[
        [_sidebarScroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_sidebarScroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_sidebarScroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        _sidebarWidthConstraint,

        [_sidebarDivider.leadingAnchor constraintEqualToAnchor:_sidebarScroll.trailingAnchor],
        [_sidebarDivider.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_sidebarDivider.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        _sidebarDividerWidthConstraint,

        [_canvas.leadingAnchor constraintEqualToAnchor:_sidebarDivider.trailingAnchor],
        [_canvas.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_canvas.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_canvas.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
}

- (void)buildToolbar {
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:kXSCToolbarID];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = NO;
    self.window.toolbar = toolbar;
}

- (void)openBookURL:(NSURL *)url {
    [_model openURL:url];
}

#pragma mark - Direct Key Handling (Zero-Hop Fast Path)

- (BOOL)handleDirectKeyEvent:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length == 0) return NO;
    unichar ch = [chars characterAtIndex:0];

    // Allow Cmd+= as an alias for Zoom In (alongside Cmd++).
    if (mods == NSEventModifierFlagCommand && ch == '=') {
        [self zoomIn:nil];
        return YES;
    }

    // Ignore other Cmd/Ctrl/Option shortcuts so menu commands work normally.
    if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        return NO;
    }

    BOOL swapRTL = XSCPrefBool(kPrefSwapRTLPageTurnKeys);
    BOOL continueVols = XSCPrefBool(kPrefContinueAcrossVolumes);

    switch (ch) {
        case NSLeftArrowFunctionKey:
            [_model turnPageForKey:XSCPageTurnKeyLeft
               swapRTLPageTurnKeys:swapRTL
             continueAcrossVolumes:continueVols];
            return YES;
        case NSRightArrowFunctionKey:
            [_model turnPageForKey:XSCPageTurnKeyRight
               swapRTLPageTurnKeys:swapRTL
             continueAcrossVolumes:continueVols];
            return YES;
        case ' ':
            if (mods & NSEventModifierFlagShift) {
                [_model goBackwardContinueAcrossVolumes:continueVols];
            } else {
                [_model goForwardContinueAcrossVolumes:continueVols];
            }
            return YES;
        case NSPageDownFunctionKey:
            [_model goForwardContinueAcrossVolumes:continueVols];
            return YES;
        case NSPageUpFunctionKey:
            [_model goBackwardContinueAcrossVolumes:continueVols];
            return YES;
        case NSHomeFunctionKey:
            [_model jumpToOneBasedPageNumber:1];
            return YES;
        case NSEndFunctionKey:
            if (_model.book && _model.book.pageCount > 0) {
                [_model jumpToOneBasedPageNumber:(NSInteger)_model.book.pageCount];
            }
            return YES;
        default:
            return NO;
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(beginPageJump:)) {
        return (_model.book != nil && _model.book.pageCount > 0);
    }
    return YES;
}

#pragma mark - Actions

- (void)chooseBook:(id)sender {
    (void)sender;
    if (self.window.attachedSheet != nil) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Open Comic Book";
    panel.prompt = @"Open";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;

    NSArray<NSString *> *exts = @[@"cb7", @"cbr", @"cbt", @"cbz", @"7z", @"rar", @"tar", @"zip"];
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithCapacity:exts.count + 1];
    [types addObject:UTTypeFolder];
    for (NSString *ext in exts) {
        UTType *t = [UTType typeWithFilenameExtension:ext];
        if (t) [types addObject:t];
    }
    panel.allowedContentTypes = types;

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [self->_model openURL:panel.URL];
        }
    }];
}

- (void)turnLeft:(id)sender {
    (void)sender;
    [_model turnPageForKey:XSCPageTurnKeyLeft
       swapRTLPageTurnKeys:XSCPrefBool(kPrefSwapRTLPageTurnKeys)
     continueAcrossVolumes:XSCPrefBool(kPrefContinueAcrossVolumes)];
}

- (void)turnRight:(id)sender {
    (void)sender;
    [_model turnPageForKey:XSCPageTurnKeyRight
       swapRTLPageTurnKeys:XSCPrefBool(kPrefSwapRTLPageTurnKeys)
     continueAcrossVolumes:XSCPrefBool(kPrefContinueAcrossVolumes)];
}

- (void)toggleDirection:(id)sender {
    (void)sender;
    [_model toggleDirection];
}

- (void)directionSegmentChanged:(NSSegmentedControl *)sender {
    XSCReadingDirection target = (sender.selectedSegment == 1)
        ? XSCReadingDirectionRTL
        : XSCReadingDirectionLTR;
    if (_model.direction != target) {
        [_model toggleDirection];
    }
}

- (void)togglePageMode:(id)sender {
    (void)sender;
    [_model togglePageMode];
}

- (void)pageModeSegmentChanged:(NSSegmentedControl *)sender {
    XSCPageMode target = (sender.selectedSegment == 1)
        ? XSCPageModeDouble
        : XSCPageModeSingle;
    if (_model.pageMode != target) {
        [_model togglePageMode];
    }
}

- (void)zoomToWindow:(id)sender {
    (void)sender;
    [_canvas setFitMode];
    [self updateZoomLabelForMode:_canvas.zoomMode scale:_canvas.zoomScale];
}

- (void)zoomActualSize:(id)sender {
    (void)sender;
    [_canvas setCustomScale:1.0];
    [self updateZoomLabelForMode:_canvas.zoomMode scale:_canvas.zoomScale];
}

- (void)zoomLabelClicked:(id)sender {
    (void)sender;
    if (_canvas.zoomMode == XSCZoomModeFit) {
        [self zoomActualSize:nil];
    } else {
        [self zoomToWindow:nil];
    }
}

- (void)zoomIn:(id)sender {
    (void)sender;
    [_canvas adjustZoomByFactor:1.25];
    [self updateZoomLabelForMode:_canvas.zoomMode scale:_canvas.zoomScale];
}

- (void)zoomOut:(id)sender {
    (void)sender;
    [_canvas adjustZoomByFactor:0.8];
    [self updateZoomLabelForMode:_canvas.zoomMode scale:_canvas.zoomScale];
}

- (void)toggleSidebar:(id)sender {
    (void)sender;
    _showsSidebar = !_showsSidebar;
    _sidebarScroll.hidden = !_showsSidebar;
    _sidebarDivider.hidden = !_showsSidebar;
    _sidebarWidthConstraint.constant = _showsSidebar ? 150.0 : 0.0;
    _sidebarDividerWidthConstraint.constant = _showsSidebar ? 1.0 : 0.0;
    if (_showsSidebar) {
        [self syncSidebarSelection];
    }
}

#pragma mark - Inline Page Jump Editor

- (void)beginPageJump:(id)sender {
    (void)sender;
    if (_isEditingPageJump || !_model.book || _model.book.pageCount == 0) return;
    _isEditingPageJump = YES;
    _pageField.editable = YES;
    _pageField.selectable = YES;
    _pageField.bezeled = YES;
    _pageField.drawsBackground = YES;
    _pageField.stringValue = [NSString stringWithFormat:@"%lu",
                              (unsigned long)(_model.currentIndex + 1)];
    [self.window makeFirstResponder:_pageField];
    [_pageField selectText:nil];
}

- (void)endPageJumpEditing {
    _isEditingPageJump = NO;
    _pageField.editable = NO;
    _pageField.selectable = NO;
    _pageField.bezeled = NO;
    _pageField.drawsBackground = NO;
    _pageField.stringValue = _model.pageIndicatorText;
    [self.window makeFirstResponder:_canvas];
}

- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector {
    (void)control;
    (void)textView;
    if (commandSelector == @selector(insertNewline:)) {
        NSString *trimmed = [_pageField.stringValue
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSScanner *scanner = [NSScanner scannerWithString:trimmed];
        NSInteger pageNum = 0;
        if (trimmed.length > 0
            && [scanner scanInteger:&pageNum]
            && scanner.isAtEnd
            && [_model jumpToOneBasedPageNumber:pageNum]) {
            [self endPageJumpEditing];
        } else {
            NSBeep();
        }
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self endPageJumpEditing];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    (void)obj;
    if (_isEditingPageJump) {
        [self endPageJumpEditing];
    }
}

#pragma mark - XSCReaderModelDelegate

- (void)readerModel:(XSCReaderModel *)model
     displayLeftPage:(XSCDecodedPage *)leftPage
           rightPage:(XSCDecodedPage *)rightPage
        showEmptyCTA:(BOOL)showEmptyCTA
           isLoading:(BOOL)isLoading
          statusText:(NSString *)statusText {
    (void)model;
    [_canvas displayLeftPage:leftPage
                   rightPage:rightPage
                showEmptyCTA:showEmptyCTA
                   isLoading:isLoading
                  statusText:statusText];
}

- (void)readerModelDidUpdateState:(XSCReaderModel *)model {
    self.window.title = model.book ? model.book.displayTitle : @"xsComic";
    self.window.representedURL = model.book ? model.book.sourceURL : nil;

    _directionSegment.selectedSegment = (model.direction == XSCReadingDirectionRTL) ? 1 : 0;
    _pageModeSegment.selectedSegment = (model.pageMode == XSCPageModeDouble) ? 1 : 0;

    if (_isEditingPageJump && model.book.bookID != _lastSidebarBookID) {
        [self endPageJumpEditing];
    } else if (!_isEditingPageJump) {
        _pageField.stringValue = model.pageIndicatorText;
    }

    uint64_t bookID = model.book ? model.book.bookID : 0;
    BOOL bookChanged = (bookID != _lastSidebarBookID);
    BOOL indexChanged = (model.currentIndex != _lastPresentedIndex);
    if (bookChanged) {
        _lastSidebarBookID = bookID;
        [_sidebarTable reloadData];
    }
    if (bookChanged || indexChanged) {
        _lastPresentedIndex = model.currentIndex;
        [_canvas resetPan];
    }
    if (_showsSidebar) {
        [self syncSidebarSelection];
    }

    if (model.errorMessage && ![model.errorMessage isEqualToString:_lastShownError]) {
        _lastShownError = [model.errorMessage copy];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Couldn\u2019t Open Book";
        alert.informativeText = model.errorMessage;
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    } else if (!model.errorMessage) {
        _lastShownError = nil;
    }
}

- (void)syncSidebarSelection {
    if (!_model.book || _model.book.pageCount == 0) {
        _updatingSidebarSelection = YES;
        [_sidebarTable deselectAll:nil];
        _updatingSidebarSelection = NO;
        return;
    }
    NSUInteger step = (_model.pageMode == XSCPageModeDouble) ? 2 : 1;
    NSUInteger len = MIN(step, _model.book.pageCount - _model.currentIndex);
    NSIndexSet *rows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(_model.currentIndex, len)];
    _updatingSidebarSelection = YES;
    [_sidebarTable selectRowIndexes:rows byExtendingSelection:NO];
    [_sidebarTable scrollRowToVisible:(NSInteger)_model.currentIndex];
    _updatingSidebarSelection = NO;
}

- (void)updateZoomLabelForMode:(XSCZoomMode)mode scale:(CGFloat)scale {
    if (!_zoomLabelButton) return;
    if (mode == XSCZoomModeFit) {
        _zoomLabelButton.title = @"Fit";
    } else {
        long pct = lrint(scale * 100.0);
        _zoomLabelButton.title = (pct == 100)
            ? @"1:1"
            : [NSString stringWithFormat:@"%ld%%", pct];
    }
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)(_model.book ? _model.book.pageCount : 0);
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    (void)tableColumn;
    static NSUserInterfaceItemIdentifier const cellID = @"PageRow";
    NSTextField *label = [tableView makeViewWithIdentifier:cellID owner:self];
    if (!label) {
        label = [NSTextField labelWithString:@""];
        label.identifier = cellID;
        label.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    label.stringValue = [NSString stringWithFormat:@"Page %ld", (long)(row + 1)];
    return label;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    if (_updatingSidebarSelection) return;
    NSInteger row = _sidebarTable.selectedRow;
    if (row >= 0) {
        [_model jumpToOneBasedPageNumber:(row + 1)];
        [self.window makeFirstResponder:_canvas];
    }
}

#pragma mark - NSToolbarDelegate

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar;
    return @[
        kToolbarSidebarID,
        kToolbarOpenID,
        NSToolbarFlexibleSpaceItemIdentifier,
        kToolbarDirectionID,
        kToolbarPageModeID,
        kToolbarPageIndicatorID,
        NSToolbarFlexibleSpaceItemIdentifier,
        kToolbarZoomOutID,
        kToolbarZoomLabelID,
        kToolbarZoomInID,
    ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar;
    (void)flag;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];

    if ([itemIdentifier isEqualToString:kToolbarSidebarID]) {
        NSButton *btn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"sidebar.left"
                                                            accessibilityDescription:@"Sidebar"]
                                           target:self
                                           action:@selector(toggleSidebar:)];
        btn.bezelStyle = NSBezelStyleTexturedRounded;
        item.view = btn;
        item.toolTip = @"Toggle page sidebar";
    } else if ([itemIdentifier isEqualToString:kToolbarOpenID]) {
        NSButton *btn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"folder"
                                                            accessibilityDescription:@"Open"]
                                           target:self
                                           action:@selector(chooseBook:)];
        btn.bezelStyle = NSBezelStyleTexturedRounded;
        item.view = btn;
        item.toolTip = @"Open comic book";
    } else if ([itemIdentifier isEqualToString:kToolbarDirectionID]) {
        _directionSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"LTR", @"RTL"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:self
                                                                    action:@selector(directionSegmentChanged:)];
        _directionSegment.selectedSegment = 0;
        item.view = _directionSegment;
        item.toolTip = @"Reading direction";
    } else if ([itemIdentifier isEqualToString:kToolbarPageModeID]) {
        NSImage *single = [NSImage imageWithSystemSymbolName:@"rectangle"
                                    accessibilityDescription:@"Single Page"];
        NSImage *dbl = [NSImage imageWithSystemSymbolName:@"rectangle.split.2x1"
                                 accessibilityDescription:@"Double Page"];
        _pageModeSegment = [NSSegmentedControl segmentedControlWithImages:@[single, dbl]
                                                             trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                   target:self
                                                                   action:@selector(pageModeSegmentChanged:)];
        _pageModeSegment.selectedSegment = 0;
        item.view = _pageModeSegment;
        item.toolTip = @"Page mode";
    } else if ([itemIdentifier isEqualToString:kToolbarPageIndicatorID]) {
        _pageField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 88, 22)];
        _pageField.editable = NO;
        _pageField.selectable = NO;
        _pageField.bezeled = NO;
        _pageField.drawsBackground = NO;
        _pageField.alignment = NSTextAlignmentCenter;
        _pageField.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular];
        _pageField.placeholderString = @"";
        _pageField.delegate = self;
        NSClickGestureRecognizer *dblClick = [[NSClickGestureRecognizer alloc]
            initWithTarget:self action:@selector(beginPageJump:)];
        dblClick.numberOfClicksRequired = 2;
        [_pageField addGestureRecognizer:dblClick];
        item.view = _pageField;
        item.toolTip = @"Double-click or press \u21e7\u2318G to jump to page";
    } else if ([itemIdentifier isEqualToString:kToolbarZoomOutID]) {
        NSButton *btn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus"
                                                            accessibilityDescription:@"Zoom Out"]
                                           target:self
                                           action:@selector(zoomOut:)];
        btn.bezelStyle = NSBezelStyleTexturedRounded;
        item.view = btn;
        item.toolTip = @"Zoom Out";
    } else if ([itemIdentifier isEqualToString:kToolbarZoomLabelID]) {
        _zoomLabelButton = [NSButton buttonWithTitle:@"Fit"
                                              target:self
                                              action:@selector(zoomLabelClicked:)];
        _zoomLabelButton.bezelStyle = NSBezelStyleTexturedRounded;
        _zoomLabelButton.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightRegular];
        _zoomLabelButton.frame = NSMakeRect(0, 0, 56, 24);
        item.view = _zoomLabelButton;
        item.toolTip = @"Toggle Fit / Actual Size";
    } else if ([itemIdentifier isEqualToString:kToolbarZoomInID]) {
        NSButton *btn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus"
                                                            accessibilityDescription:@"Zoom In"]
                                           target:self
                                           action:@selector(zoomIn:)];
        btn.bezelStyle = NSBezelStyleTexturedRounded;
        item.view = btn;
        item.toolTip = @"Zoom In";
    }
    return item;
}

@end

#pragma mark - Lazy Preferences Window Controller

@interface XSCPrefsController : NSWindowController
@end

@implementation XSCPrefsController

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 140)
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = @"Settings";
    [win center];
    self = [super initWithWindow:win];
    if (self) {
        NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 12.0;

        NSButton *swapBtn = [self checkboxWithTitle:@"Swap left and right page-turn keys in RTL mode"
                                                key:kPrefSwapRTLPageTurnKeys
                                             action:@selector(toggleSwapRTL:)];
        NSButton *contBtn = [self checkboxWithTitle:@"Continue into adjacent volumes"
                                                key:kPrefContinueAcrossVolumes
                                             action:@selector(toggleContinueVolumes:)];
        NSButton *iconBtn = [self checkboxWithTitle:@"Use alternate app icon"
                                                key:kPrefUseAlternateIcon
                                             action:@selector(toggleAlternateIcon:)];

        [stack addArrangedSubview:swapBtn];
        [stack addArrangedSubview:contBtn];
        [stack addArrangedSubview:iconBtn];

        NSView *content = win.contentView;
        [content addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20.0],
            [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20.0],
            [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:20.0],
            [stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-20.0],
        ]];
    }
    return self;
}

- (NSButton *)checkboxWithTitle:(NSString *)title key:(NSString *)key action:(SEL)action {
    NSButton *btn = [NSButton checkboxWithTitle:title target:self action:action];
    btn.state = XSCPrefBool(key) ? NSControlStateValueOn : NSControlStateValueOff;
    return btn;
}

- (void)toggleSwapRTL:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn)
                                            forKey:kPrefSwapRTLPageTurnKeys];
}

- (void)toggleContinueVolumes:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(sender.state == NSControlStateValueOn)
                                            forKey:kPrefContinueAcrossVolumes];
}

- (void)toggleAlternateIcon:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefUseAlternateIcon];
    XSCApplyAppIconAsync(enabled);
}

@end

#pragma mark - App Delegate & Main Menu

@interface XSCAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation XSCAppDelegate {
    XSCReaderModel *_model;
    XSCWindowController *_windowController;
    XSCPrefsController *_prefsController;
}

- (XSCReaderModel *)ensureModel {
    if (!_model) {
        _model = [[XSCReaderModel alloc] init];
    }
    return _model;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    if (urls.firstObject) {
        // Start archive open + page-1 decode IMMEDIATELY in parallel with window construction!
        [[self ensureModel] openURL:urls.firstObject];
    }
    if (_windowController) {
        [_windowController showWindow:nil];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kPrefSwapRTLPageTurnKeys: @NO,
        kPrefContinueAcrossVolumes: @YES,
        kPrefUseAlternateIcon: @NO,
    }];

    [self ensureModel];
    _windowController = [[XSCWindowController alloc] initWithModel:_model];
    [self buildMainMenu];

    [_windowController showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (!_model.book && !_model.isLoading) {
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        for (NSUInteger i = 1; i < args.count; i++) {
            NSString *arg = args[i];
            if (![arg hasPrefix:@"-"] && [NSFileManager.defaultManager fileExistsAtPath:arg]) {
                [_model openURL:[NSURL fileURLWithPath:arg]];
                break;
            }
        }
    }

    if (XSCPrefBool(kPrefUseAlternateIcon)) {
        XSCApplyAppIconAsync(YES);
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (!flag && _windowController) {
        [_windowController showWindow:nil];
    }
    return YES;
}

- (void)chooseBook:(id)sender {
    if (_windowController) {
        [_windowController showWindow:nil];
        [_windowController chooseBook:sender];
    }
}

- (void)showPreferences:(id)sender {
    (void)sender;
    if (!_prefsController) {
        _prefsController = [[XSCPrefsController alloc] init];
    }
    [_prefsController showWindow:nil];
}

- (void)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // App menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"xsComic"];
    [appMenu addItemWithTitle:@"About xsComic"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *prefs = [appMenu addItemWithTitle:@"Settings\u2026"
                                           action:@selector(showPreferences:)
                                    keyEquivalent:@","];
    prefs.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide xsComic"
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit xsComic"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];

    // File menu
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open\u2026"
                        action:@selector(chooseBook:)
                 keyEquivalent:@"o"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    [mainMenu addItem:fileItem];

    // Edit menu (enables Cut/Copy/Paste/Select All in page-jump text field)
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [mainMenu addItem:editItem];

    // Reading menu
    NSMenuItem *readItem = [[NSMenuItem alloc] init];
    NSMenu *readMenu = [[NSMenu alloc] initWithTitle:@"Reading"];

    unichar leftCh = NSLeftArrowFunctionKey;
    NSMenuItem *leftItem = [readMenu addItemWithTitle:@"Left"
                                               action:@selector(turnLeft:)
                                        keyEquivalent:[NSString stringWithCharacters:&leftCh length:1]];
    leftItem.keyEquivalentModifierMask = 0;

    unichar rightCh = NSRightArrowFunctionKey;
    NSMenuItem *rightItem = [readMenu addItemWithTitle:@"Right"
                                                action:@selector(turnRight:)
                                         keyEquivalent:[NSString stringWithCharacters:&rightCh length:1]];
    rightItem.keyEquivalentModifierMask = 0;

    [readMenu addItem:[NSMenuItem separatorItem]];
    [readMenu addItemWithTitle:@"Toggle Reading Direction"
                        action:@selector(toggleDirection:)
                 keyEquivalent:@"d"];
    [readMenu addItemWithTitle:@"Toggle Page Mode"
                        action:@selector(togglePageMode:)
                 keyEquivalent:@"p"];
    NSMenuItem *jumpItem = [readMenu addItemWithTitle:@"Jump to Page\u2026"
                                               action:@selector(beginPageJump:)
                                        keyEquivalent:@"G"];
    jumpItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;

    [readMenu addItem:[NSMenuItem separatorItem]];
    [readMenu addItemWithTitle:@"Zoom to Window"
                        action:@selector(zoomToWindow:)
                 keyEquivalent:@"0"];
    [readMenu addItemWithTitle:@"Actual Size"
                        action:@selector(zoomActualSize:)
                 keyEquivalent:@"1"];
    [readMenu addItemWithTitle:@"Zoom In"
                        action:@selector(zoomIn:)
                 keyEquivalent:@"+"];
    [readMenu addItemWithTitle:@"Zoom Out"
                        action:@selector(zoomOut:)
                 keyEquivalent:@"-"];
    readItem.submenu = readMenu;
    [mainMenu addItem:readItem];

    // View menu
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *sidebarItem = [viewMenu addItemWithTitle:@"Toggle Sidebar"
                                                  action:@selector(toggleSidebar:)
                                           keyEquivalent:@"s"];
    sidebarItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    viewItem.submenu = viewMenu;
    [mainMenu addItem:viewItem];

    // Window menu
    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [winMenu addItemWithTitle:@"Minimize"
                       action:@selector(performMiniaturize:)
                keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"Zoom"
                       action:@selector(performZoom:)
                keyEquivalent:@""];
    winItem.submenu = winMenu;
    [mainMenu addItem:winItem];

    NSApp.mainMenu = mainMenu;
    NSApp.windowsMenu = winMenu;
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        XSCAppDelegate *delegate = [[XSCAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
