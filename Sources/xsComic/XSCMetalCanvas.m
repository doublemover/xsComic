/*
 XSCMetalCanvas.m — Direct CAMetalLayer comic page renderer.

 Presentation & GPU Pipeline:
   1. Zero-copy IOSurface -> MTLTexture binding: on Apple Silicon unified
      memory, `newTextureWithDescriptor:iosurface:plane:0` wraps each page's
      IOSurface directly as `MTLPixelFormatR8Unorm` (grayscale manga) or
      `MTLPixelFormatBGRA8Unorm` (color) with zero pixel copies and no
      AppKit/SwiftUI intermediate backing stores.
   2. Decode-once, GPU-scale-always: pages are decoded once at native
      resolution. Window resizing, sidebar toggles, and 120 Hz focal-point
      pinch-zoom never trigger re-decodes; the fragment shader performs
      Lanczos-3 downscaling (for crisp, moire-free manga screentones) and
      smooth bilinear upscaling in real time on the GPU.
   3. Zero offscreen shadows: a subtle 1-pixel hairline border is shaded inline
      inside the fragment shader, avoiding CoreAnimation's expensive offscreen
      alpha-mask shadow surface allocation.
   4. Lazy AppKit overlays: empty-state CTA button, loading/status label, and
      animated GIF `NSImageView`s are created only when needed and hidden
      otherwise.
 */

#import "XSCMetalCanvas.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

static const CGFloat kXSCCanvasInset = 12.0;
static const CGFloat kXSCPageSpacing = 8.0;
static const CGFloat kXSCMinZoomScale = 0.1;
static const CGFloat kXSCMaxZoomScale = 16.0;

typedef struct {
    simd_float4 rectNDC;    // (x0, y0, x1, y1) in Metal NDC [-1, 1]
    simd_float2 texSize;    // raw texture dimensions in pixels (w, h)
    simd_float2 dstSize;    // destination quad dimensions in backing pixels (w, h)
    uint32_t orientation;   // EXIF orientation 1..8
    uint32_t isGrayscale;   // 1 = R8Unorm (.rrr1 swizzle), 0 = BGRA8Unorm
} XSCPageUniforms;

/*
 Inline Metal Shading Language (MSL) program — minified to keep `__cstring`
 compact while preserving full readability in this guide:

 Structs:
   - `U` (XSCPageUniforms): `r` = rectNDC (x0,y0,x1,y1), `ts` = texSize,
     `ds` = dstSize, `o` = EXIF orientation (1..8), `g` = isGrayscale (0/1).
   - `V` (VSOut): clip-space `p` (`[[position]]`) and screen-space `uv` in [0,1].

 Vertex shader (`xsc_vs`):
   - Emits 2 triangles (6 vertices via `vertex_id`, no vertex buffer needed).
   - Maps `c.x` in [0,1] across `[r.x, r.z]` (left -> right) and `c.y` in [0,1]
     across `[r.w, r.y]` (top `y1` -> bottom `y0` in Metal NDC), so `uv = (0,0)`
     is top-left and `uv = (1,1)` is bottom-right, matching CoreGraphics row-0-top
     IOSurface memory layout.

 EXIF orientation helper (`ex(uv, o)`):
   - Transforms upright screen-space UV into raw texture UV for all 8 EXIF cases:
     1: identity            | 2: flip H (1-u, v)      | 3: rot 180 (1-u, 1-v)
     4: flip V (u, 1-v)     | 5: transpose (v, u)     | 6: rot 90 CW (v, 1-u)
     7: transverse (1-v,1-u)| 8: rot 270 CW (1-v, u)

 Lanczos-3 kernel (`l3(x)`):
   - Evaluates `sinc(x) * sinc(x/3)` for `|x| < 3` (1 at 0, 0 for `|x| >= 3`).

 Fragment shader (`xsc_fs`):
   - Computes downscale ratio `rt = orientedTexSize / dstSize`.
   - When downscaling (`max(rt.x, rt.y) > 1.05`): runs a 6×6 separable Lanczos-3
     filter with step scaled by `clamp(rawRatio * 0.5, 1.0, 3.5)` using the
     hardware linear sampler so large downscales remain alias-free.
   - When upscaling or 1:1: samples directly with the hardware linear sampler.
   - Grayscale swizzle: when `u.g != 0` (`MTLPixelFormatR8Unorm`), expands
     `c.r` into `(c.r, c.r, c.r, 1.0)`.
   - Crisp 1px hairline border: pixels within 1 backing pixel of the quad edge
     blend 16% black to cleanly separate white comic margins from the canvas.
 */
static NSString * const kXSCMetalShaderSource = @""
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct U{float4 r;float2 ts,ds;uint o,g;};\n"
"struct V{float4 p[[position]];float2 uv;};\n"
"vertex V xsc_vs(uint i[[vertex_id]],constant U&u[[buffer(0)]]){\n"
"const float2 k[6]={{0,0},{1,0},{0,1},{1,0},{1,1},{0,1}};\n"
"float2 c=k[i];return{float4(mix(u.r.x,u.r.z,c.x),mix(u.r.w,u.r.y,c.y),0,1),c};}\n"
"static inline float2 ex(float2 u,uint o){\n"
"switch(o){case 2:return{1-u.x,u.y};case 3:return{1-u.x,1-u.y};case 4:return{u.x,1-u.y};"
"case 5:return{u.y,u.x};case 6:return{u.y,1-u.x};case 7:return{1-u.y,1-u.x};case 8:return{1-u.y,u.x};default:return u;}}\n"
"static inline float l3(float x){float a=abs(x);if(a<1e-4)return 1;if(a>=3)return 0;float p=3.14159265*a,q=p/3;return(sin(p)*sin(q))/(p*q);}\n"
"fragment float4 xsc_fs(V in[[stage_in]],texture2d<float>t[[texture(0)]],constant U&u[[buffer(0)]]){\n"
"constexpr sampler s(address::clamp_to_edge,filter::linear);\n"
"float2 ru=ex(in.uv,u.o),ot=(u.o>=5&&u.o<=8)?u.ts.yx:u.ts,rt=ot/max(u.ds,float2(1));float4 c;\n"
"if(max(rt.x,rt.y)>1.05){\n"
"float2 tx=1/max(u.ts,float2(1)),rr=(u.o>=5&&u.o<=8)?rt.yx:rt,st=tx*clamp(rr*0.5,float2(1),float2(3.5)),co=ru*u.ts-0.5,f=fract(co),b=(floor(co)+0.5)*tx;\n"
"float4 a=0;float ws=0;\n"
"for(int j=-2;j<=3;++j){float wy=l3(j-f.y);for(int i=-2;i<=3;++i){float w=l3(i-f.x)*wy;a+=t.sample(s,b+float2(i,j)*st)*w;ws+=w;}}\n"
"c=a/max(ws,1e-5);}else{c=t.sample(s,ru);}\n"
"if(u.g)c=float4(c.r,c.r,c.r,1);\n"
"float2 px=in.uv*u.ds;if(px.x<1||px.y<1||px.x>u.ds.x-1||px.y>u.ds.y-1)c.rgb=mix(c.rgb,float3(0),0.16);\n"
"return c;}\n";

@implementation XSCMetalCanvas {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;

    XSCDecodedPage *_leftPage;
    XSCDecodedPage *_rightPage;
    id<MTLTexture> _leftTexture;
    id<MTLTexture> _rightTexture;

    XSCZoomMode _zoomMode;
    CGFloat _customScale;
    CGPoint _panOffset;
    CGPoint _lastDragPoint;
    BOOL _isDragging;

    BOOL _showEmptyCTA;
    BOOL _isLoading;
    NSString *_statusText;

    NSButton *_openButton;
    NSTextField *_statusLabel;
    NSImageView *_leftGIFView;
    NSImageView *_rightGIFView;
    XSCDecodedPage *_leftGIFPage;
    XSCDecodedPage *_rightGIFPage;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _zoomMode = XSCZoomModeFit;
        _customScale = 1.0;
        _panOffset = CGPointZero;

        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

        [self setupMetal];
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer = [CAMetalLayer layer];
    id<MTLDevice> dev = _device ?: MTLCreateSystemDefaultDevice();
    layer.device = dev;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.presentsWithTransaction = NO;
    layer.contentsScale = self.window.backingScaleFactor ?: (NSScreen.mainScreen.backingScaleFactor ?: 2.0);
    return layer;
}

- (void)setupMetal {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        return;
    }
    _commandQueue = [_device newCommandQueue];

    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    if ([ml isKindOfClass:[CAMetalLayer class]]) {
        ml.device = _device;
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ml.framebufferOnly = YES;
    }

    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kXSCMetalShaderSource options:nil error:&err];
    if (!lib) {
        return;
    }
    id<MTLFunction> vs = [lib newFunctionWithName:@"xsc_vs"];
    id<MTLFunction> fs = [lib newFunctionWithName:@"xsc_fs"];

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vs;
    desc.fragmentFunction = fs;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
}

/*
 Wraps a decoded page's IOSurface as a zero-copy unified-memory MTLTexture.
 Refuses to bind a surface whose contents were purged by the kernel.
 */
- (nullable id<MTLTexture>)textureForPage:(nullable XSCDecodedPage *)page {
    if (!page || !_device || !page.surface) {
        return nil;
    }
    if (![page pinNonVolatile]) {
        return nil;
    }
    MTLPixelFormat fmt = page.isGrayscale ? MTLPixelFormatR8Unorm : MTLPixelFormatBGRA8Unorm;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                    width:page.pixelWidth
                                                                                   height:page.pixelHeight
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    return [_device newTextureWithDescriptor:desc iosurface:page.surface plane:0];
}

#pragma mark - Public API

- (XSCZoomMode)zoomMode {
    return _zoomMode;
}

- (CGFloat)zoomScale {
    if (_zoomMode == XSCZoomModeCustom) {
        return _customScale;
    }
    return [self computeFitScale];
}

- (void)displayLeftPage:(nullable XSCDecodedPage *)leftPage
              rightPage:(nullable XSCDecodedPage *)rightPage
           showEmptyCTA:(BOOL)showEmptyCTA
              isLoading:(BOOL)isLoading
             statusText:(nullable NSString *)statusText {
    if (_leftPage != leftPage) {
        _leftPage = leftPage;
        _leftTexture = [self textureForPage:leftPage];
    }
    if (_rightPage != rightPage) {
        _rightPage = rightPage;
        _rightTexture = [self textureForPage:rightPage];
    }
    _showEmptyCTA = showEmptyCTA;
    _isLoading = isLoading;
    _statusText = [statusText copy];

    [self updateOverlays];
    [self clampPanOffset];
    [self renderNow];
}

- (void)setFitMode {
    _zoomMode = XSCZoomModeFit;
    _panOffset = CGPointZero;
    [self layoutGIFOverlays];
    [self renderNow];
    [self notifyZoomChanged];
}

- (void)setCustomScale:(CGFloat)scale {
    CGFloat clamped = fmin(kXSCMaxZoomScale, fmax(kXSCMinZoomScale, scale));
    _zoomMode = XSCZoomModeCustom;
    _customScale = clamped;
    [self clampPanOffset];
    [self layoutGIFOverlays];
    [self renderNow];
    [self notifyZoomChanged];
}

- (void)adjustZoomByFactor:(CGFloat)factor {
    CGFloat base = (_zoomMode == XSCZoomModeCustom) ? _customScale : [self computeFitScale];
    [self setCustomScale:base * factor];
}

- (void)resetPan {
    _panOffset = CGPointZero;
    [self layoutGIFOverlays];
    [self renderNow];
}

- (void)notifyZoomChanged {
    if (_onZoomChanged) {
        _onZoomChanged(_zoomMode, self.zoomScale);
    }
}

#pragma mark - Layout & Geometry

- (CGFloat)computeFitScale {
    NSRect b = self.bounds;
    CGFloat availW = fmax(1.0, b.size.width - 2.0 * kXSCCanvasInset);
    CGFloat availH = fmax(1.0, b.size.height - 2.0 * kXSCCanvasInset);

    if (!_leftPage && !_rightPage) {
        return 1.0;
    }
    if (_leftPage && _rightPage) {
        CGSize ls = _leftPage.orientedPixelSize;
        CGSize rs = _rightPage.orientedPixelSize;
        CGFloat totalW = fmax(1.0, ls.width + rs.width);
        CGFloat maxH = fmax(1.0, fmax(ls.height, rs.height));
        CGFloat usableW = fmax(1.0, availW - kXSCPageSpacing);
        return fmin(usableW / totalW, availH / maxH);
    }
    XSCDecodedPage *single = _leftPage ?: _rightPage;
    CGSize s = single.orientedPixelSize;
    return fmin(availW / fmax(1.0, s.width), availH / fmax(1.0, s.height));
}

- (void)computeLeftRect:(NSRect *)outLeft rightRect:(NSRect *)outRight totalSize:(NSSize *)outTotal {
    NSRect b = self.bounds;
    CGFloat scale = self.zoomScale;
    NSRect leftR = NSZeroRect;
    NSRect rightR = NSZeroRect;
    NSSize total = NSZeroSize;

    if (_leftPage && _rightPage) {
        CGSize ls = _leftPage.orientedPixelSize;
        CGSize rs = _rightPage.orientedPixelSize;
        CGFloat lw = ls.width * scale;
        CGFloat lh = ls.height * scale;
        CGFloat rw = rs.width * scale;
        CGFloat rh = rs.height * scale;
        total = NSMakeSize(lw + kXSCPageSpacing + rw, fmax(lh, rh));
        CGFloat cx = b.size.width * 0.5 + _panOffset.x;
        CGFloat cy = b.size.height * 0.5 + _panOffset.y;
        CGFloat startX = cx - total.width * 0.5;
        leftR = NSMakeRect(startX, cy - lh * 0.5, lw, lh);
        rightR = NSMakeRect(startX + lw + kXSCPageSpacing, cy - rh * 0.5, rw, rh);
    } else if (_leftPage || _rightPage) {
        XSCDecodedPage *p = _leftPage ?: _rightPage;
        CGSize s = p.orientedPixelSize;
        CGFloat pw = s.width * scale;
        CGFloat ph = s.height * scale;
        total = NSMakeSize(pw, ph);
        CGFloat cx = b.size.width * 0.5 + _panOffset.x;
        CGFloat cy = b.size.height * 0.5 + _panOffset.y;
        NSRect r = NSMakeRect(cx - pw * 0.5, cy - ph * 0.5, pw, ph);
        if (_leftPage) {
            leftR = r;
        } else {
            rightR = r;
        }
    }

    if (outLeft) *outLeft = leftR;
    if (outRight) *outRight = rightR;
    if (outTotal) *outTotal = total;
}

- (void)clampPanOffset {
    if (_zoomMode == XSCZoomModeFit) {
        _panOffset = CGPointZero;
        return;
    }
    NSSize total = NSZeroSize;
    [self computeLeftRect:NULL rightRect:NULL totalSize:&total];
    NSRect b = self.bounds;
    CGFloat maxX = fmax(0.0, (total.width - b.size.width) * 0.5 + kXSCCanvasInset);
    CGFloat maxY = fmax(0.0, (total.height - b.size.height) * 0.5 + kXSCCanvasInset);
    _panOffset.x = fmin(maxX, fmax(-maxX, _panOffset.x));
    _panOffset.y = fmin(maxY, fmax(-maxY, _panOffset.y));
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    [self renderNow];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self syncDrawableSize];
        [self renderNow];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self syncDrawableSize];
    [self clampPanOffset];
    [self layoutOverlays];
    [self renderNow];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self syncDrawableSize];
    [self renderNow];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self renderNow];
}

- (void)syncDrawableSize {
    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    if (![ml isKindOfClass:[CAMetalLayer class]]) {
        return;
    }
    CGFloat scale = self.window.backingScaleFactor ?: (NSScreen.mainScreen.backingScaleFactor ?: 2.0);
    ml.contentsScale = scale;
    NSRect b = self.bounds;
    CGFloat w = fmax(1.0, round(b.size.width * scale));
    CGFloat h = fmax(1.0, round(b.size.height * scale));
    if (ml.drawableSize.width != w || ml.drawableSize.height != h) {
        ml.drawableSize = CGSizeMake(w, h);
    }
}

#pragma mark - Metal Rendering

- (void)renderNow {
    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    if (!_pipeline || !_commandQueue || ![ml isKindOfClass:[CAMetalLayer class]]) {
        return;
    }
    /* Skip drawable acquisition when detached or occluded to avoid stalling. */
    if (!self.window || (self.window.occlusionState & NSWindowOcclusionStateVisible) == 0) {
        return;
    }
    NSRect b = self.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) {
        return;
    }
    [self syncDrawableSize];

    @autoreleasepool {
        id<CAMetalDrawable> drawable = [ml nextDrawable];
        if (!drawable) {
            return;
        }

        NSColor *bg = [NSColor.windowBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        double r = 0.12, g = 0.12, bl = 0.12;
        if (bg) {
            r = bg.redComponent;
            g = bg.greenComponent;
            bl = bg.blueComponent;
        }

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, bl, 1.0);

        id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
        if (!cmd) {
            return;
        }
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
        if (!enc) {
            return;
        }
        [enc setRenderPipelineState:_pipeline];

        NSRect leftR = NSZeroRect, rightR = NSZeroRect;
        [self computeLeftRect:&leftR rightRect:&rightR totalSize:NULL];
        CGFloat backingScale = ml.contentsScale ?: 2.0;

        if (_leftPage && _leftTexture && !_leftPage.isAnimatedGIF) {
            [self encodeQuadForPage:_leftPage texture:_leftTexture rect:leftR viewBounds:b backingScale:backingScale encoder:enc];
        }
        if (_rightPage && _rightTexture && !_rightPage.isAnimatedGIF) {
            [self encodeQuadForPage:_rightPage texture:_rightTexture rect:rightR viewBounds:b backingScale:backingScale encoder:enc];
        }

        [enc endEncoding];
        [cmd presentDrawable:drawable];
        [cmd commit];
    }
}

- (void)encodeQuadForPage:(XSCDecodedPage *)page
                  texture:(id<MTLTexture>)texture
                     rect:(NSRect)rect
               viewBounds:(NSRect)bounds
             backingScale:(CGFloat)backingScale
                  encoder:(id<MTLRenderCommandEncoder>)enc {
    if (rect.size.width < 0.5 || rect.size.height < 0.5) {
        return;
    }
    float x0 = (float)((rect.origin.x / bounds.size.width) * 2.0 - 1.0);
    float x1 = (float)((NSMaxX(rect) / bounds.size.width) * 2.0 - 1.0);
    float y0 = (float)((rect.origin.y / bounds.size.height) * 2.0 - 1.0);
    float y1 = (float)((NSMaxY(rect) / bounds.size.height) * 2.0 - 1.0);

    XSCPageUniforms u;
    u.rectNDC = simd_make_float4(x0, y0, x1, y1);
    u.texSize = simd_make_float2((float)page.pixelWidth, (float)page.pixelHeight);
    u.dstSize = simd_make_float2((float)(rect.size.width * backingScale), (float)(rect.size.height * backingScale));
    u.orientation = page.exifOrientation;
    u.isGrayscale = page.isGrayscale ? 1u : 0u;

    [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:texture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

#pragma mark - Lightweight Overlays

- (void)updateOverlays {
    if (_showEmptyCTA) {
        if (!_openButton) {
            _openButton = [NSButton buttonWithTitle:@"Open Comic…" target:self action:@selector(handleOpenButton:)];
            _openButton.bezelStyle = NSBezelStyleRounded;
            _openButton.controlSize = NSControlSizeLarge;
            [_openButton sizeToFit];
            [self addSubview:_openButton];
        }
        _openButton.hidden = NO;
    } else if (_openButton) {
        _openButton.hidden = YES;
    }

    NSString *labelText = _statusText;
    if (!labelText && _isLoading) {
        labelText = @"Loading…";
    }
    if (labelText.length > 0) {
        if (!_statusLabel) {
            _statusLabel = [NSTextField labelWithString:@""];
            _statusLabel.alignment = NSTextAlignmentCenter;
            _statusLabel.textColor = NSColor.secondaryLabelColor;
            _statusLabel.font = [NSFont systemFontOfSize:13.0];
            [self addSubview:_statusLabel];
        }
        _statusLabel.stringValue = labelText;
        [_statusLabel sizeToFit];
        _statusLabel.hidden = NO;
    } else if (_statusLabel) {
        _statusLabel.hidden = YES;
    }

    [self updateGIFOverlay:&_leftGIFView pageSlot:&_leftGIFPage forPage:_leftPage];
    [self updateGIFOverlay:&_rightGIFView pageSlot:&_rightGIFPage forPage:_rightPage];
    [self layoutOverlays];
}

- (void)updateGIFOverlay:(NSImageView * __strong *)viewPtr
                pageSlot:(XSCDecodedPage * __strong *)pageSlotPtr
                 forPage:(nullable XSCDecodedPage *)page {
    if (page && page.isAnimatedGIF && page.gifData) {
        if (!*viewPtr) {
            NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iv.animates = YES;
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.imageFrameStyle = NSImageFrameNone;
            [self addSubview:iv];
            *viewPtr = iv;
        }
        /* Only decode a fresh animated NSImage when the displayed page changes. */
        if (*pageSlotPtr != page) {
            *pageSlotPtr = page;
            (*viewPtr).image = [[NSImage alloc] initWithData:page.gifData];
        }
        (*viewPtr).hidden = NO;
    } else {
        *pageSlotPtr = nil;
        if (*viewPtr) {
            (*viewPtr).image = nil;
            (*viewPtr).hidden = YES;
        }
    }
}

- (void)layoutOverlays {
    NSRect b = self.bounds;
    if (_openButton && !_openButton.hidden) {
        NSSize s = _openButton.frame.size;
        _openButton.frame = NSMakeRect(round((b.size.width - s.width) * 0.5),
                                       round((b.size.height - s.height) * 0.5),
                                       s.width, s.height);
    }
    if (_statusLabel && !_statusLabel.hidden) {
        NSSize s = _statusLabel.frame.size;
        CGFloat yOff = (_openButton && !_openButton.hidden) ? -36.0 : 0.0;
        _statusLabel.frame = NSMakeRect(round((b.size.width - s.width) * 0.5),
                                        round((b.size.height - s.height) * 0.5 + yOff),
                                        s.width, s.height);
    }
    [self layoutGIFOverlays];
}

- (void)layoutGIFOverlays {
    if ((!_leftGIFView || _leftGIFView.hidden) && (!_rightGIFView || _rightGIFView.hidden)) {
        return;
    }
    NSRect leftR = NSZeroRect, rightR = NSZeroRect;
    [self computeLeftRect:&leftR rightRect:&rightR totalSize:NULL];
    if (_leftGIFView && !_leftGIFView.hidden) {
        _leftGIFView.frame = leftR;
    }
    if (_rightGIFView && !_rightGIFView.hidden) {
        _rightGIFView.frame = rightR;
    }
}

- (void)handleOpenButton:(id)sender {
    (void)sender;
    if (_onChooseBookRequested) {
        _onChooseBookRequested();
    }
}

#pragma mark - Pinch-Zoom & Panning

- (void)magnifyWithEvent:(NSEvent *)event {
    if (!_leftPage && !_rightPage) {
        return;
    }
    if (_zoomMode == XSCZoomModeFit) {
        _customScale = [self computeFitScale];
        _zoomMode = XSCZoomModeCustom;
        _panOffset = CGPointZero;
    }
    CGFloat oldScale = _customScale;
    CGFloat factor = 1.0 + event.magnification;
    if (factor <= 0.05) {
        factor = 0.05;
    }
    CGFloat newScale = fmin(kXSCMaxZoomScale, fmax(kXSCMinZoomScale, oldScale * factor));
    if (fabs(newScale - oldScale) < 1e-5) {
        return;
    }

    /* Keep the point under the cursor stationary while scaling around view center. */
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGPoint center = CGPointMake(self.bounds.size.width * 0.5, self.bounds.size.height * 0.5);
    CGFloat dx = p.x - center.x;
    CGFloat dy = p.y - center.y;
    CGFloat ratio = newScale / oldScale;

    _customScale = newScale;
    _panOffset.x = dx - (dx - _panOffset.x) * ratio;
    _panOffset.y = dy - (dy - _panOffset.y) * ratio;

    [self clampPanOffset];
    [self layoutGIFOverlays];
    [self renderNow];
    [self notifyZoomChanged];
}

- (void)scrollWheel:(NSEvent *)event {
    if (_zoomMode != XSCZoomModeCustom) {
        [super scrollWheel:event];
        return;
    }
    CGFloat mult = event.hasPreciseScrollingDeltas ? 1.0 : 12.0;
    _panOffset.x += event.scrollingDeltaX * mult;
    _panOffset.y -= event.scrollingDeltaY * mult;
    [self clampPanOffset];
    [self layoutGIFOverlays];
    [self renderNow];
}

- (void)mouseDown:(NSEvent *)event {
    if (_zoomMode == XSCZoomModeCustom) {
        _isDragging = YES;
        _lastDragPoint = [self convertPoint:event.locationInWindow fromView:nil];
    } else {
        [super mouseDown:event];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_isDragging) {
        [super mouseDragged:event];
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    _panOffset.x += p.x - _lastDragPoint.x;
    _panOffset.y += p.y - _lastDragPoint.y;
    _lastDragPoint = p;
    [self clampPanOffset];
    [self layoutGIFOverlays];
    [self renderNow];
}

- (void)mouseUp:(NSEvent *)event {
    _isDragging = NO;
    [super mouseUp:event];
}

#pragma mark - Drag & Drop

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = sender.draggingPasteboard;
    if ([pb canReadObjectForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = sender.draggingPasteboard;
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                               options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count > 0 && _onOpenURLsDropped) {
        _onOpenURLsDropped(urls);
        return YES;
    }
    return NO;
}

@end
