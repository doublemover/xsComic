import AppKit
import ImageIO

/*
 A URL alone does not identify a decoded page.  The same source may exist in
 the store as a viewport-sized preview and as a full-resolution image while the
 user zooms.  Making the decode size part of the key prevents a low-resolution
 cache hit from masquerading as the requested detail.  nil means native/full
 resolution; a non-nil value bounds the longer decoded edge in pixels.
 */
struct PageImageRequest: Hashable, Sendable {
    let url: URL
    let maximumPixelDimension: Int?
}

/*
 AppKit predates Swift concurrency, so NSImage does not declare Sendable.  This
 program makes a narrower whole-program promise: construction and decoding
 happen off-main, presentation happens on the main actor, and no consumer may
 mutate `page.image`.  `let` does not make NSImage itself immutable; any future
 call through its mutable API would invalidate this @unchecked conformance.

 sourcePixelSize records the oriented dimensions of the original.  The NSImage
 retains that logical size even when its backing CGImage is downsampled, so
 layout and fit-to-window calculations do not jump as decode quality changes.
 decodedByteCount measures the backing bitmap's stride times height—the useful
 quantity for a memory budget, unlike compressed file size.
 */
final class DecodedPage: @unchecked Sendable {
    let image: NSImage
    let sourcePixelSize: CGSize
    let decodedByteCount: Int

    init(image: NSImage, sourcePixelSize: CGSize, decodedByteCount: Int) {
        self.image = image
        self.sourcePixelSize = sourcePixelSize
        self.decodedByteCount = decodedByteCount
    }
}

/*
 PageImageStore is the bounded, reusable decoded-image cache.  It is not a claim
 about the process's instantaneous peak: visible views hold references, as many
 as two decodes may be in flight, and an over-budget visible page or native GIF
 deliberately lives outside the cache.  The actor protects bookkeeping, but
 never performs image decoding: synchronous ImageIO work runs in detached tasks
 and is admitted by ImageDecodeGate below.

 The policy was chosen around the overwhelmingly common gesture: turn pages
 consecutively at human speed.  ReaderModel asks for eight pages ahead and
 keeps two behind.  Twelve entries leave room for that ten-page neighborhood
 plus the one or two visible pages. A 64 MiB byte ceiling independently bounds
 retained cache rasters; an entry ceiling alone cannot. Transient decode memory
 is not in that byte account, so the two-permit gate bounds its concurrency.

 These are intentionally simple, fixed-size collections.  With a hard limit of
 twelve, an array search stays bounded and needs no linked-LRU nodes or pointer
 maintenance.  The central invariants are:

   • pages and accessOrder contain the same request keys, exactly once;
   • decodedBytes is the sum of pages' decodedByteCount values;
   • pendingLoads has at most one tracked, publishable load for an exact request;
   • lower retentionRanks are more valuable and are evicted later.
 */
actor PageImageStore {
    static let byteLimit = 64 * 1_024 * 1_024
    static let entryLimit = 12

    /*
     id distinguishes successive loads of the same request.  generation
     distinguishes whole books.  Together they prevent a cancelled task that
     finishes late from publishing into newer state.

     isPrefetch distinguishes speculative cancellation and cache-rank promotion:
     speculative work may be abandoned as the window moves, while an on-screen
     demand gets a little more latitude to finish and inherits visible rank.
     */
    private struct PendingLoad {
        let id: UInt
        let isPrefetch: Bool
        let task: Task<DecodedPage?, Never>
    }

    private var pages = [PageImageRequest: DecodedPage]()
    private var accessOrder = [PageImageRequest]()
    private var failedRequests = Set<PageImageRequest>()
    private var pendingLoads = [PageImageRequest: PendingLoad]()
    private var retentionRanks = [PageImageRequest: Int]()
    private var decodedBytes = 0
    private var generation: UInt = 0
    private var nextLoadID: UInt = 0

    // Two concurrent decoders overlap storage latency without letting a flurry
    // of view updates inflate CPU and transient bitmap memory.  The value is
    // deliberately smaller than the cache/window size.
    private let decodeGate = ImageDecodeGate(limit: 2)

    // MARK: - Looking up or decoding a page

    /*
     This method is both lookup and rendezvous point.  Concurrent callers for
     the same request await one PendingLoad and receive the same DecodedPage
     identity.  Demand and prefetch use the same path, so there is only one
     implementation of failure caching, admission, and stale-result rejection.

     The actor is suspended while awaiting a decoder.  It can therefore serve
     hits, revise the retention window, or reset for a new book while ImageIO
     runs elsewhere.
     */
    func image(
        for request: PageImageRequest,
        priority: TaskPriority = .userInitiated,
        isPrefetch: Bool = false
    ) async -> DecodedPage? {
        if !isPrefetch {
            // Pinch zoom can ask for a new resolution while an older demand is
            // still decoding.  Prefer the current request over duplicated work
            // for the same source page, then inherit that page's cache rank.
            cancelSupersededDemandLoads(for: request)
            promoteDemandLoad(request)
        }
        if let page = pages[request] {
            // Hits move to the MRU end.  Retention rank remains the primary
            // eviction criterion; recency breaks ties within a rank.
            touch(request)
            return page
        }
        if failedRequests.contains(request) {
            // SwiftUI may ask for a bad page on every update.  Remembering the
            // failure converts repeated parsing and I/O into this set lookup.
            return nil
        }
        if let pending = pendingLoads[request], !pending.task.isCancelled {
            // Capture the book generation before suspension.  reset() can run
            // while we wait, and a result from that earlier book must then
            // appear to this caller as cancellation, even if decoding ended.
            let pendingGeneration = generation
            let page = await pending.task.value
            return generation == pendingGeneration ? page : nil
        }

        nextLoadID &+= 1
        let loadID = nextLoadID
        let loadGeneration = generation
        let decodeGate = decodeGate

        /*
         Task.detached is purposeful: it neither inherits this actor nor the
         main actor of a visible-page caller.  Only the compact request and gate
         cross into it.  ImageIO's synchronous decode then happens off-main,
         with TaskPriority distinguishing visible work from utility prefetch.
         */
        let task: Task<DecodedPage?, Never> = Task.detached(priority: priority) {
            guard await decodeGate.acquire() else { return nil }
            guard !Task.isCancelled else {
                await decodeGate.release()
                return nil
            }
            let page = Self.decode(request)
            await decodeGate.release()
            return page
        }
        pendingLoads[request] = PendingLoad(
            id: loadID,
            isPrefetch: isPrefetch,
            task: task
        )

        let page = await task.value

        // Cancellation is cooperative.  ImageIO may finish after reset() or
        // after a replacement load has claimed this dictionary key; generation
        // and id make that completed bitmap harmless rather than cacheable.
        guard generation == loadGeneration,
            pendingLoads[request]?.id == loadID
        else {
            return nil
        }

        pendingLoads[request] = nil
        if let page {
            if !isPrefetch {
                promoteDemandLoad(request)
            }
            insert(page, for: request)
        } else if !task.isCancelled {
            // Failure memory is bounded like the page cache.  Which old failure
            // leaves first is unimportant: all retained-window failures survive
            // prepare(), and retrying a distant page is acceptable.
            if failedRequests.count >= Self.entryLimit {
                failedRequests.removeFirst()
            }
            failedRequests.insert(request)
        }
        return page
    }

    // MARK: - Applying the reader's prediction

    /*
     ReaderModel supplies an ordered retentionWindow, not merely a set.  In the
     usual forward-reading state its ranks are:

         visible, next 1–2, previous 1–2, remaining next pages (up to 8)

     After repeated backward turns it puts previous pages first.  This tiny
     rule-based predictor costs almost no executable state, yet matches both
     ordinary sequential reading and the common "flip back to check something"
     correction.  Rank zero is most valuable.

     prefetchRequests expresses decode order separately.  It is awaited one
     request at a time rather than fanning out ten Tasks: a page turn can revise
     the plan between decodes, and sequential speculation avoids a transient
     memory/CPU burst.  Visible demand still runs concurrently through image().
     */
    func prepare(
        retentionWindow: [PageImageRequest],
        prefetchRequests: [PageImageRequest],
        retainsFullResolution: Bool
    ) async {
        guard !Task.isCancelled else { return }

        let retainedRequests = Set(retentionWindow)
        let retainedURLs = Set(retentionWindow.map(\.url))

        // Forget failures outside the useful neighborhood.  Should the reader
        // return much later—perhaps after the file changed—the page gets a
        // fresh decode attempt.
        failedRequests.formIntersection(retainedRequests)

        /*
         This preparation pass does not cancel exact retained requests. A
         visible on-demand decode at another resolution may also continue if it
         remains useful:

           • a bounded preview is cheap and can still serve the page; or
           • a full-resolution load is kept only while the canvas says full
             resolution remains required.

         Speculative loads outside the window have no such claim.  Cancelling
         them is what turns the fixed 8-ahead/2-behind policy into a bound on
         work as well as a bound on resident cache entries.
         */
        let obsoleteRequests = pendingLoads.compactMap { request, pending -> PageImageRequest? in
            if retainedRequests.contains(request) {
                return nil
            }
            if !pending.isPrefetch, retainedURLs.contains(request.url) {
                if request.maximumPixelDimension != nil || retainsFullResolution {
                    return nil
                }
            }
            return request
        }
        for request in obsoleteRequests {
            pendingLoads.removeValue(forKey: request)?.task.cancel()
        }

        // Dictionary lookup makes rank comparisons constant-time during the
        // small eviction loop.  uniqueKeysWithValues is valid because a page
        // request occurs at most once in ReaderModel's contiguous window.
        retentionRanks = Dictionary(
            uniqueKeysWithValues: retentionWindow.enumerated().map { ($1, $0) }
        )

        for request in prefetchRequests {
            // Cancellation is checked between pages, the point at which we can
            // cheaply stop.  The decoder itself checks around its indivisible
            // ImageIO call.
            guard !Task.isCancelled else { return }
            _ = await image(for: request, priority: .utility, isPrefetch: true)
        }
    }

    /*
     reset() is the hard book boundary.  Incrementing generation first makes
     every suspended waiter stale; cancelling tasks reduces wasted work, but
     correctness does not depend on cancellation being instantaneous.

     Keeping collection capacity avoids reallocating the same tiny tables at
     each volume transition.  No page remains retained by this store because
     every element is removed and decodedBytes returns to the empty-state value.
     */
    func reset() {
        generation &+= 1
        for pending in pendingLoads.values {
            pending.task.cancel()
        }
        pendingLoads.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        accessOrder.removeAll(keepingCapacity: true)
        failedRequests.removeAll()
        retentionRanks.removeAll(keepingCapacity: true)
        decodedBytes = 0
    }

    // MARK: - Small-cache bookkeeping

    private func touch(_ request: PageImageRequest) {
        // accessOrder is least-recently used at the front, most-recently used
        // at the back.  Linear removal is a conscious win at twelve elements.
        if let index = accessOrder.firstIndex(of: request) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(request)
    }

    private func cancelSupersededDemandLoads(for request: PageImageRequest) {
        /*
         Resolution changes produce different request keys for one URL.  Two
         simultaneous demand decodes would compete for the two-slot gate and
         often make the now-obsolete bitmap first.  Cancel only demand work:
         an already-running bounded prefetch is cheap and remains useful as an
         immediate placeholder.
         */
        let superseded = pendingLoads.compactMap { candidate, pending in
            candidate.url == request.url
                && candidate != request
                && !pending.isPrefetch
                ? candidate
                : nil
        }
        for candidate in superseded {
            pendingLoads.removeValue(forKey: candidate)?.task.cancel()
        }
    }

    private func promoteDemandLoad(_ request: PageImageRequest) {
        /*
         The retention plan normally names viewport previews.  When the canvas
         asks for full detail of the same visible URL, copy the preview's rank
         to the detail request.  Without this promotion, a full cache would
         classify the very image on screen as unretained and evict it first.
         */
        guard retentionRanks[request] == nil,
            let rank = retentionRanks.first(where: {
                $0.key.url == request.url
            })?.value
        else {
            return
        }
        retentionRanks[request] = rank
    }

    private func insert(_ page: DecodedPage, for request: PageImageRequest) {
        /*
         A native GIF can retain every animation frame behind one NSImage while
         decodedByteCount can measure only the exposed CGImage.  Caching it
         would violate the byte invariant in spirit.  Keep native animation
         visible-only; the bounded store may retain its static, downsampled
         preview because that object has one known bitmap.
         */
        guard
            request.maximumPixelDimension != nil
                || request.url.pathExtension.lowercased() != "gif"
        else {
            return
        }

        // An individual bitmap larger than the entire budget can be displayed,
        // but caching it would require evicting everything without restoring
        // the promised memory bound.
        guard page.decodedByteCount <= Self.byteLimit else { return }

        // Replacement is removed before capacity arithmetic so decodedBytes
        // always describes precisely what remains in pages.
        removeCachedPage(for: request)

        /*
         Enforce both independent ceilings before insertion.  evictionCandidate
         may refuse an incoming low-value prefetch when every resident page has
         a better rank; in that case the decoded result is returned to its
         caller but deliberately not retained.
         */
        while pages.count >= Self.entryLimit
            || decodedBytes > Self.byteLimit - page.decodedByteCount
        {
            guard let victim = evictionCandidate(for: request) else { return }
            removeCachedPage(for: victim)
        }

        pages[request] = page
        decodedBytes += page.decodedByteCount
        accessOrder.append(request)
    }

    private func removeCachedPage(for request: PageImageRequest) {
        // Centralizing the paired removals preserves both cache invariants on
        // replacement, eviction, and any future explicit discard path.
        if let page = pages.removeValue(forKey: request) {
            decodedBytes -= page.decodedByteCount
        }
        accessOrder.removeAll { $0 == request }
    }

    private func evictionCandidate(for incoming: PageImageRequest) -> PageImageRequest? {
        /*
         Lower rank means nearer to current reading intent; Int.max means
         outside the current plan.  max(by:) therefore chooses the least useful
         resident.  Since accessOrder runs oldest-to-newest and equal ranks do
         not compare less, the oldest item wins a rank tie: retention-aware LRU
         in a few lines and no auxiliary heap.

         The final comparison is admission control.  An incoming page may evict
         only an equally or less valuable resident; a distant speculative page
         cannot push out a visible or near-future one merely because it
         completed later.
         */
        let incomingRank = retentionRanks[incoming] ?? Int.max
        guard
            let victim = accessOrder.max(by: {
                (retentionRanks[$0] ?? Int.max) < (retentionRanks[$1] ?? Int.max)
            })
        else {
            return nil
        }

        let victimRank = retentionRanks[victim] ?? Int.max
        return victimRank >= incomingRank ? victim : nil
    }

    // MARK: - Decoding

    /*
     decode is nonisolated because no cache state belongs on the decoding
     thread.  It is synchronous because ImageIO is synchronous; the caller is
     responsible for placing it in a detached task.

     The autorelease pool is significant in a page-turn loop.  ImageIO and
     AppKit create temporary Objective-C objects which otherwise can accumulate
     until an ambient pool drains.  Reclaiming them after each page keeps peak
     memory close to "cached pages + the bounded in-flight decodes" rather than
     "cached pages + every temporary made during this run-loop turn."
     */
    private nonisolated static func decode(_ request: PageImageRequest) -> DecodedPage? {
        guard !Task.isCancelled else { return nil }

        return autoreleasepool {
            let isGIF = request.url.pathExtension.lowercased() == "gif"

            // A full-resolution GIF is opened through NSImage so AppKit retains
            // its animation.  The cache excludes this undercountable object;
            // it exists only while the visible view needs it.
            if isGIF, request.maximumPixelDimension == nil {
                return decodeNativeImage(at: request.url)
            }

            /*
             ImageIO's thumbnail path performs downsampling during decode.
             Decoding a 6000×9000 page and resizing it afterward would briefly
             allocate the full raster, defeating the 64 MiB cache policy before
             admission even ran.  ShouldCache=false also prevents creation of a
             hidden full-size source cache merely to inspect metadata.
             */
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(request.url as CFURL, sourceOptions),
                CGImageSourceGetCount(source) > 0
            else {
                return nil
            }

            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
            let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let fullDimension = max(sourceWidth, sourceHeight)
            let requestedDimension = request.maximumPixelDimension ?? fullDimension
            guard requestedDimension > 0 else {
                // Some valid formats omit usable pixel metadata.  Native AppKit
                // decoding is the compatibility path when no thumbnail bound
                // can be derived.
                return decodeNativeImage(at: request.url)
            }

            /*
             "Thumbnail" is also our deterministic full-resolution decoder when
             requestedDimension equals the source's long edge.  Transform=true
             applies EXIF orientation before the bitmap reaches layout, and
             CacheImmediately=true forces all expensive decoding to finish here
             off-main rather than lazily during the next draw.
             */
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: requestedDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard !Task.isCancelled else { return nil }
            guard
                let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    thumbnailOptions as CFDictionary
                )
            else {
                // Falling back preserves support for static formats whose
                // ImageIO source opens but whose thumbnail path fails.  A GIF
                // does not take this path: accidentally materializing all
                // frames would violate the bounded-memory purpose of prefetch.
                return isGIF ? nil : decodeNativeImage(at: request.url)
            }

            /*
             ImageIO's thumbnail call cannot itself be interrupted, so the
             checks immediately before and after are the useful cancellation
             points.  A superseded decode may consume one final ImageIO call;
             cancellation observed here prevents the following NSImage wrapper,
             while later cancellation is still rejected by the generation/id
             checks before cache admission.
             */
            guard !Task.isCancelled else { return nil }
            let orientedSourceSize: CGSize
            if sourceWidth <= 0 || sourceHeight <= 0 {
                orientedSourceSize = .zero
            } else if (5...8).contains(orientation) {
                // EXIF orientations 5–8 rotate across the diagonal.  The
                // transformed bitmap's layout axes are therefore exchanged.
                orientedSourceSize = CGSize(width: sourceHeight, height: sourceWidth)
            } else {
                orientedSourceSize = CGSize(width: sourceWidth, height: sourceHeight)
            }
            let sourceSize =
                orientedSourceSize == .zero
                ? CGSize(width: cgImage.width, height: cgImage.height)
                : orientedSourceSize

            // Give NSImage the original oriented size, not the thumbnail's
            // pixel dimensions.  A preview and later detail decode then occupy
            // identical layout geometry and zoom remains visually stable.
            let image = NSImage(cgImage: cgImage, size: sourceSize)
            return DecodedPage(
                image: image,
                sourcePixelSize: sourceSize,
                decodedByteCount: byteCount(of: cgImage)
            )
        }
    }

    /*
     Native decoding is the narrow escape hatch for animation and unusual
     static files.  Asking for a CGImage eagerly realizes at least the drawable
     representation here, still off-main.  For an animated image this byte
     count cannot see every retained frame, which is why insert() excludes a
     native GIF rather than pretending the estimate is a hard bound.
     */
    private nonisolated static func decodeNativeImage(at url: URL) -> DecodedPage? {
        guard let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            !Task.isCancelled
        else {
            return nil
        }
        return DecodedPage(
            image: image,
            sourcePixelSize: image.pixelSize,
            decodedByteCount: byteCount(of: cgImage)
        )
    }

    /*
     bytesPerRow includes allocator padding; width × components would
     undercount it.  Overflow maps to Int.max, causing cache admission to reject
     the image safely.  max(1, count) prevents a malformed zero-stride bitmap
     from becoming a free cache entry.
     */
    private nonisolated static func byteCount(of image: CGImage) -> Int {
        let (count, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return overflow ? Int.max : max(1, count)
    }
}

private extension NSImage {
    /*
     NSImage may carry multiple representations (Retina variants, animation
     frames, or format-specific backing).  The largest raster is the least
     surprising account of native source dimensions.  `size` is a point size,
     but remains the best fallback for representation-less images.
     */
    var pixelSize: CGSize {
        let result = representations.reduce(CGSize.zero) { largest, representation in
            let candidate = CGSize(
                width: representation.pixelsWide,
                height: representation.pixelsHigh
            )
            return candidate.width * candidate.height > largest.width * largest.height
                ? candidate
                : largest
        }
        return result == .zero ? size : result
    }
}

// MARK: - Decode concurrency

/*
 ImageDecodeGate is a two-permit, FIFO semaphore expressed as an actor so it
 cooperates with Swift task cancellation.  It exists separately from
 PageImageStore because the store must remain available while callers wait for
 decode capacity.

 Its conservation rule is simple: a permit is either in `available`, held by a
 decoder, or promised to exactly one queued continuation.  release() transfers
 a permit directly to the oldest waiter instead of incrementing and immediately
 decrementing the count.

 The queue is an Array on purpose. Normal preparation offers only the small page
 window, and rapid demand changes cancel obsolete waiters; with those deliberately
 bounded producers, removeFirst and cancellation's linear search avoid a larger
 queue implementation and its binary/source footprint.
 */
private actor ImageDecodeGate {
    private struct Waiter {
        // The monotonically increasing id lets cancellation identify a waiter
        // without retaining or comparing continuation internals.
        let id: UInt
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters = [Waiter]()
    private var nextWaiterID: UInt = 0

    init(limit: Int) {
        available = limit
    }

    func acquire() async -> Bool {
        // A caller cancelled before admission consumes no permit.
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID

        /*
         Cancellation can race with continuation installation in either order:

           1. If cancellation wins first, the body observes Task.isCancelled
              and resumes false without queueing.
           2. If queueing wins first, onCancel asks this actor to remove that id
              and resume false.
           3. If release has already granted the permit, cancel(id) finds
              nothing; image()'s post-acquire cancellation check returns the
              permit immediately.

         Every path resumes exactly once and no permit is leaked.
         */
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(
                        Waiter(
                            id: waiterID,
                            continuation: continuation
                        ))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func release() {
        if waiters.isEmpty {
            // No claimant exists, so the permit becomes freely available.
            available += 1
        } else {
            // Hand off directly in FIFO order.  available is unchanged because
            // the permit never became idle.
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancel(_ waiterID: UInt) {
        // No match means release() already handed off the permit.  The resumed
        // task will observe cancellation and call release() itself.
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
