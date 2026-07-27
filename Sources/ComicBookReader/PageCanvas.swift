import SwiftUI

/*
 PageCanvas is intentionally a compositor, not an image engine. SwiftUI lays
 out one or two immutable NSImages; ReaderModel and PageImageStore decide what to
 decode, retain, prefetch, and cancel. Keeping those jobs separate makes the hot
 rendering path mostly native drawing while the asynchronous path remains easy
 to audit.

 Four quantities connect layout to decoding:

   1. the viewport determines the largest fitted page cell;
   2. display scale converts that cell from points to useful pixels;
   3. coarse buckets prevent tiny resizes or pinch updates from creating a new
      decoded image for every intermediate value;
   4. task identifiers cancel work as soon as book, page, mode, or demand changes.

 This is the performance-critical bridge between "what can be seen?" and "what
 should exist in memory?" The comments below preserve the arithmetic and its
 reasons together.
 */
private enum CanvasMetrics {
    // Modest fixed geometry keeps pages away from window edges without a nested
    // stack of decorative containers.
    static let inset: CGFloat = 12
    static let pageSpacing: CGFloat = 8

    // ImageIO requests are rounded to 256-pixel steps. The small amount of
    // possible overdecode buys cache reuse during continuous window resizing.
    static let decodeBucket = 256

    // Custom zoom is quantized into sixty-fourths of native resolution. This
    // integer is both a cache/task key and a fixed-point denominator; it avoids
    // hashing noisy floating-point gesture values.
    static let fullResolutionScaleKey = 64
}

struct PageCanvas: View {
    @Environment(\.displayScale) private var displayScale

    let reader: ReaderModel

    // MagnifyGesture reports total magnification since the gesture began. We
    // therefore capture exactly one base scale and multiply every update by it;
    // feeding each update back into the previous one would compound zoom wildly.
    @State private var gestureStartScale: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            // These values are cheap scalar projections of geometry and reader
            // state. Giving each a name keeps the layout/decode contract visible
            // and ensures demand loads and prefetch use identical keys.
            let maximumPageSize = maximumPageSize(in: geometry.size)
            let previewDimension = previewDimension(for: maximumPageSize)
            let decodeScaleKey = decodeScaleKey(for: reader.zoom)

            Group {
                if let scale = reader.zoom.scale {
                    /*
                     A custom scale has an intrinsic content size: source pixels
                     multiplied by scale. Native ScrollView supplies panning,
                     clipping, scroll bars, momentum, and trackpad drag behavior
                     without a custom gesture recognizer or retained transform.
                     */
                    ScrollView([.horizontal, .vertical]) {
                        pageRow(
                            scale: scale,
                            previewDimension: previewDimension,
                            decodeScaleKey: decodeScaleKey
                        )
                        .padding(CanvasMetrics.inset)
                    }
                } else {
                    // Fit mode has no oversized content to pan. Avoiding a
                    // ScrollView here removes needless scrolling machinery and
                    // lets the spread consume the viewport directly.
                    pageRow(
                        maximumSize: maximumPageSize,
                        previewDimension: previewDimension,
                        decodeScaleKey: decodeScaleKey
                    )
                    .padding(CanvasMetrics.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            /*
             Preparing the image window and displaying the current page are
             intentionally separate tasks. PageImageView below issues the
             user-visible demand request; this task arranges the bounded cache
             around it (eight pages ahead, two behind). PageImageStore coalesces
             identical requests, so a prefetched page becoming visible does not
             decode twice.

             SwiftUI cancels and replaces this task whenever ImageWindowID
             changes. Object identity acts as the book generation, and bucketed
             dimensions keep harmless geometry noise from churning tasks.
             */
            .task(
                id: ImageWindowID(
                    book: reader.bookIdentity,
                    index: reader.currentIndex,
                    pageMode: reader.pageMode,
                    previewDimension: previewDimension,
                    decodeScaleKey: decodeScaleKey
                )
            ) {
                let visibleContainsGIF = reader.visiblePages.contains {
                    $0.pathExtension.lowercased() == "gif"
                }

                // Native animated GIFs must remain full-resolution while visible
                // because an ImageIO thumbnail is only a static frame. Ordinary
                // pages retain full resolution only when zoom demands it.
                await reader.prepareImageWindow(
                    maximumPixelDimension: previewDimension,
                    retainsFullResolution:
                        decodeScaleKey == CanvasMetrics.fullResolutionScaleKey
                        || visibleContainsGIF
                )
            }

            /*
             The magnifier is simultaneous with ScrollView's gestures. Thus a
             zoomed page keeps native drag-to-pan behavior while pinching adjusts
             scale. Beginning a pinch in fit mode snapshots the fitted scale and
             deliberately converts the reader to custom zoom on the first update.
             */
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if gestureStartScale == nil {
                            gestureStartScale =
                                reader.zoom.scale
                                ?? reader.fitZoomScale(within: maximumPageSize)
                        }
                        reader.setZoomScale((gestureStartScale ?? 1) * value.magnification)
                    }
                    .onEnded { _ in gestureStartScale = nil }
            )
        }
    }

    @ViewBuilder
    private func pageRow(
        maximumSize: CGSize? = nil,
        scale: CGFloat? = nil,
        previewDimension: Int,
        decodeScaleKey: Int
    ) -> some View {
        // Capture the current spread once for this view construction. In RTL
        // double-page mode ReaderModel has already reversed its display order;
        // canvas layout contains no reading-direction special cases.
        let visiblePages = reader.visiblePages

        HStack(spacing: CanvasMetrics.pageSpacing) {
            ForEach(visiblePages, id: \.self) { url in
                PageImageView(
                    reader: reader,
                    url: url,
                    previewDimension: previewDimension,
                    decodeScaleKey: decodeScaleKey,
                    scale: scale,
                    maximumSize: maximumSize
                )
            }
        }
    }

    private func maximumPageSize(in viewport: CGSize) -> CGSize {
        /*
         A double-page spread gives each leaf an equal-width slot after removing
         one inter-page gap. Height is shared. Clamping each axis to one point
         prevents invalid frames during the transient zero-sized geometry that
         can occur while a window is being created or collapsed.
         */
        let pageCount = max(1, reader.visiblePages.count)
        let spacing = CanvasMetrics.pageSpacing * CGFloat(pageCount - 1)
        return CGSize(
            width: max(
                1,
                (viewport.width - 2 * CanvasMetrics.inset - spacing)
                    / CGFloat(pageCount)
            ),
            height: max(1, viewport.height - 2 * CanvasMetrics.inset)
        )
    }

    private func previewDimension(for maximumPageSize: CGSize) -> Int {
        /*
         ImageIO works in pixels whereas SwiftUI proposes points. We ask only
         for enough pixels to fill the largest page axis on the current display,
         then round upward so the preview is never undersized. Bucket rounding
         makes nearby window sizes share both an image-cache entry and task ID.
         */
        let target = max(maximumPageSize.width, maximumPageSize.height) * displayScale
        let bucket = CanvasMetrics.decodeBucket
        return max(bucket, Int((target / CGFloat(bucket)).rounded(.up)) * bucket)
    }

    private func decodeScaleKey(for zoom: ZoomMode) -> Int {
        switch zoom {
        case .fit:
            // Zero is not a scale; it means "the fitted preview is sufficient."
            return 0
        case .custom(let scale):
            /*
             Convert point scale to device-pixel demand, cap it at native
             resolution, and quantize upward. Upscaling beyond 100% cannot reveal
             detail absent from the source, so it must not allocate larger images.
             */
            let decodedFraction = min(1, max(0, scale * displayScale))
            return max(
                1,
                Int(
                    (decodedFraction * CGFloat(CanvasMetrics.fullResolutionScaleKey))
                        .rounded(.up)
                )
            )
        }
    }
}

/*
 A `.task(id:)` identifier is a compact dependency list for asynchronous work.
 It contains values that change the requested cache window, and pointedly omits
 unrelated state (toolbar visibility, error text, reading direction). Those
 changes may redraw a view but should not cancel useful image work.
 */
private struct ImageWindowID: Hashable {
    let book: ObjectIdentifier?
    let index: Int
    let pageMode: PageMode
    let previewDimension: Int
    let decodeScaleKey: Int
}

/*
 Each visible page is a three-state progressive renderer:

       loading ──preview──▶ loaded(preview) ──detail──▶ loaded(detail)
          └────────────────────failure──────────────────▶ failed

 Showing the fitted preview first bounds time-to-first-page and memory. A detail
 decode follows only when custom zoom can expose more source pixels. The view
 stores one DecodedPage reference—not parallel preview/detail copies—and the
 actor-backed store handles cache ownership and duplicate requests.
 */
private struct PageImageView: View {
    private enum Phase {
        case loading
        case loaded(DecodedPage)
        case failed
    }

    let reader: ReaderModel
    let url: URL
    let previewDimension: Int
    let decodeScaleKey: Int
    let scale: CGFloat?
    let maximumSize: CGSize?

    @State private var phase = Phase.loading

    var body: some View {
        Group {
            switch phase {
            case .loaded(let page):
                /*
                 NSImage drawing stays in SwiftUI/AppKit's native compositor.
                 `sourcePixelSize`, rather than decoded-preview dimensions,
                 defines custom zoom geometry; replacing a preview with a detail
                 image therefore cannot make the page jump in size.
                 */
                Image(nsImage: page.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: scale.map { page.sourcePixelSize.width * $0 },
                        height: scale.map { page.sourcePixelSize.height * $0 }
                    )
                    .frame(
                        maxWidth: maximumSize?.width,
                        maxHeight: maximumSize?.height
                    )
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            case .failed:
                ContentUnavailableView(
                    "Unreadable Image",
                    systemImage: "photo.badge.exclamationmark"
                )
            case .loading:
                ProgressView()
            }
        }

        // The complete request identity matters here. Page turns, book changes,
        // resize buckets, and zoom buckets each cancel stale progressive work;
        // toolbar-only updates do not.
        .task(
            id: PageImageLoadID(
                book: reader.bookIdentity,
                url: url,
                previewDimension: previewDimension,
                decodeScaleKey: decodeScaleKey
            )
        ) {
            await load()
        }
    }

    private func load() async {
        phase = .loading
        let isGIF = url.pathExtension.lowercased() == "gif"

        /*
         Stage one asks for a viewport-bounded preview. ImageIO keeps a smaller
         source at its natural size; an unusual static format whose thumbnail
         path fails may use PageImageStore's native compatibility fallback. The
         request is normally enough for fit mode and is shared with prefetch.
         Cancellation is checked after each suspension so an old task never
         publishes into a repurposed view.
         */
        let previewRequest = PageImageRequest(
            url: url,
            maximumPixelDimension: previewDimension
        )
        if let preview = await reader.image(for: previewRequest), !Task.isCancelled {
            phase = .loaded(preview)

            if let detailRequest = detailRequest(for: preview, isGIF: isGIF),
                !Task.isCancelled,
                let detail = await reader.image(for: detailRequest),
                !Task.isCancelled
            {
                phase = .loaded(detail)
            }
        }

        /*
         ImageIO thumbnails do not preserve GIF animation. Once its static
         preview is on screen, request the native NSImage representation. The
         store deliberately keeps native GIFs visible-only because retaining all
         frames in the general cache could consume its entire memory budget.
         */
        if isGIF, !Task.isCancelled {
            let nativeRequest = PageImageRequest(
                url: url,
                maximumPixelDimension: nil
            )
            if let native = await reader.image(for: nativeRequest), !Task.isCancelled {
                phase = .loaded(native)
            }
        }

        // A failed preview can still be rescued by the native GIF path above.
        if !Task.isCancelled, case .loading = phase {
            phase = .failed
        }
    }

    private func detailRequest(
        for preview: DecodedPage,
        isGIF: Bool
    ) -> PageImageRequest? {
        // Fit mode's scale key is zero, and GIF detail follows its separate
        // animation-preserving path. Neither should schedule this static decode.
        guard !isGIF, decodeScaleKey > 0 else { return nil }

        /*
         Image metadata is untrusted. Establish a finite, positive upper bound
         before converting CGFloat to Int or multiplying below. Int.max / 512
         leaves ample room for the 64-based fixed-point calculation and
         256-pixel bucket rounding on every supported architecture.
         */
        let rawSourceDimension = max(
            preview.sourcePixelSize.width,
            preview.sourcePixelSize.height
        ).rounded(.up)
        guard rawSourceDimension.isFinite,
            rawSourceDimension > 0,
            rawSourceDimension <= CGFloat(Int.max / 512)
        else {
            return nil
        }

        let sourceDimension = Int(rawSourceDimension)
        let scale = CanvasMetrics.fullResolutionScaleKey
        let bucket = CanvasMetrics.decodeBucket

        /*
         Fixed-point ceiling division:

             desired = ceil(sourceDimension × zoomKey / 64)

         followed by an upward 256-pixel bucket. The result is capped at source
         resolution because more decoded pixels cannot add information. This
         arithmetic is the reason a continuous pinch produces at most a modest
         sequence of useful decodes rather than one decode per gesture event.
         */
        let scaledDimension = (sourceDimension * decodeScaleKey + scale - 1) / scale
        let bucketedDimension = ((scaledDimension + bucket - 1) / bucket) * bucket
        let targetDimension = min(sourceDimension, max(bucket, bucketedDimension))

        // Do not replace a preview with an equal-or-smaller image. A nil maximum
        // is PageImageStore's compact spelling for exact native resolution.
        guard targetDimension > min(sourceDimension, previewDimension) else {
            return nil
        }

        return PageImageRequest(
            url: url,
            maximumPixelDimension: targetDimension == sourceDimension
                ? nil
                : targetDimension
        )
    }
}

// Demand-load identity mirrors the request dimensions used by PageImageStore.
// Book identity prevents equal extraction URLs from crossing volume lifetimes.
private struct PageImageLoadID: Hashable {
    let book: ObjectIdentifier?
    let url: URL
    let previewDimension: Int
    let decodeScaleKey: Int
}
