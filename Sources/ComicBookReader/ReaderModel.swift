import AppKit
import Observation
import UniformTypeIdentifiers

/*
 ReaderModel is the reader's small control plane.  It knows which book and
 pages are current, but deliberately knows nothing about SwiftUI layout or the
 details of image decoding.  ArchiveBook owns discovery and extraction;
 PageImageStore owns decoded pixels; the views own presentation.

 There are two useful coordinate systems:

   archive order   page URLs are always stored first-to-last
   presentation    an RTL two-page spread reverses those URLs for display

 Navigation is expressed only in archive order.  Thus "forward" always means
 toward a larger page number, even when the corresponding key or visual motion
 points left.  Keeping this distinction here prevents RTL conditionals from
 leaking into loading, caching, status text, and cross-volume navigation.

 If n is the page count, i is currentIndex, and s is step, the central
 invariants are:

   0 <= i < n                  whenever a nonempty book is open
   i mod s = 0                 at every stable page or spread
   visible pages = [i, min(i + s, n))
   a forward turn exists iff i + s < n

 A final odd page is consequently a valid one-page tail of a two-page book.
 These few equations account for most of the otherwise fiddly boundary cases.
 */

/// The order in which the book is read, not the order in which URLs are stored.
enum ReadingDirection: String, CaseIterable, Identifiable {
    case leftToRight = "LTR"
    case rightToLeft = "RTL"
    var id: Self { self }
}

/// The number of archive pages consumed by one ordinary turn.
enum PageMode: String, CaseIterable, Identifiable {
    case single = "Single"
    case double = "Double"
    var id: Self { self }
}

/*
 A physical key is intentionally translated into a semantic action before the
 model navigates.  That tiny seam gives the RTL preference exactly one place
 to act and leaves goForward/goBackward independent of keyboard conventions.
 */
enum PageTurnKey {
    case left
    case right
}

enum PageTurnAction: Equatable {
    case backward
    case forward
}

/*
 Fit is a mode rather than a stored scale: the answer depends on the current
 viewport and on source dimensions that arrive asynchronously.  Custom scales
 are source-pixel multipliers (1 means one source pixel per layout point);
 PageCanvas decides how many pixels the display can profitably decode.
 */
enum ZoomMode: Equatable {
    case fit
    case custom(CGFloat)

    /// `nil` tells the canvas to derive a scale from its current geometry.
    var scale: CGFloat? {
        switch self {
        case .fit: nil
        case .custom(let scale): scale
        }
    }
}

@Observable
@MainActor
final class ReaderModel {
    /*
     The prefetch *window* is intentionally static and small.  Ordinary comic
     reading advances consecutively at human page-turn speed, so eight pages
     ahead cover several seconds of likely demand while two pages behind make
     a correction or comparison immediate.  In double-page mode the worst
     normal window is exactly:

         2 visible + 8 upcoming + 2 previous = 12 decoded entries

     That matches PageImageStore's independent 12-entry ceiling.  No volume
     history, probability table, timer, watcher, or persistent index is needed.
     The decoded-byte ceiling may evict large pages sooner, but the candidate
     set itself is always bounded by these constants.
     */
    nonisolated static let forwardPrefetchPageCount = 8
    nonisolated static let backwardBufferPageCount = 2

    // MARK: - Observable reader state

    /*
     Only user-visible state participates in Observation.  The loading state
     machine is encoded without an enum or duplicate payload:

         book       isLoading    meaning
         nil        false        no document
         nil        true         first document opening
         non-nil    false        reading
         non-nil    true         replacement opening; old book retained

     errorMessage is orthogonal: a replacement can fail and report its error
     while the non-nil old book remains committed for rollback. currentIndex is
     zero-based internally; status and jump(toPage:) are the one-based boundaries.
     */
    private(set) var book: ArchiveBook?
    private(set) var currentIndex = 0
    private(set) var isLoading = false
    var errorMessage: String?
    var direction: ReadingDirection = .leftToRight

    /*
     An event counter is smaller and less error-prone than a Boolean pulse that
     must be cleared by a view.  Every increment is a distinct observation, and
     wrapping is harmless: equality with a centuries-old request is irrelevant.
     */
    private(set) var pageJumpRequest: UInt = 0

    var pageMode: PageMode = .single {
        didSet {
            // Re-anchor the current page at the first page of its new spread.
            currentIndex -= currentIndex % step
            resetPrefetchBias()
        }
    }
    var zoom: ZoomMode = .fit

    // MARK: - Non-observable machinery

    /*
     ObservationIgnored is more than cosmetic.  Tasks, cache bookkeeping, and
     fit metadata are implementation machinery: publishing their mutations
     would invalidate views that cannot render anything useful from them.

     loadGeneration is the commit token for asynchronous opens.  Cancellation
     is cooperative and therefore not sufficient by itself; an old load may
     finish after a newer one.  Only the task holding the current generation is
     permitted to install a book.
     */
    @ObservationIgnored private let imageStore = PageImageStore()
    @ObservationIgnored private var archiveLoadTask: Task<ArchiveBook, Error>?
    @ObservationIgnored private var loadGeneration: UInt = 0

    /*
     Fit needs only the componentwise maximum source size of the visible page
     or spread.  Keeping this one tuple avoids a per-page metadata table.  The
     index and mode form its validity key; stale values become inert without
     requiring work on every page turn.
     */
    @ObservationIgnored private var fitReference:
        (
            index: Int,
            mode: PageMode,
            maximumSourceSize: CGSize
        )?

    #if !CBR_STATIC_PREFETCH
        /*
         The shipped predictor is one saturating byte.  The static-control build
         omits even this field, allowing scripts/measure-predictor.sh to measure its
         true release cost under otherwise identical -Osize and strip settings.
         */
        @ObservationIgnored private var backwardTurnStreak: UInt8 = 0
    #endif

    // MARK: - Derived page geometry

    /*
     These projections are deliberately computed from ArchiveBook's single
     page array.  Mirroring that array into observable state would spend memory,
     complicate replacement, and create another source of truth.
     */
    var pages: [URL] { book?.pages ?? [] }

    /*
     Identity, rather than source URL, makes reopening the same path a new
     SwiftUI task generation.  ObjectIdentifier supplies that distinction
     without hashing page paths or maintaining another counter.
     */
    var bookIdentity: ObjectIdentifier? { book.map(ObjectIdentifier.init) }
    var step: Int { pageMode == .single ? 1 : 2 }
    var canGoBackward: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex + step < pages.count }

    var status: String {
        guard !pages.isEmpty else { return "" }
        let end = min(currentIndex + step, pages.count)
        return pageMode == .single || end == currentIndex + 1
            ? "\(currentIndex + 1) / \(pages.count)"
            : "\(currentIndex + 1)–\(end) / \(pages.count)"
    }

    var visiblePages: [URL] {
        guard currentIndex < pages.count else { return [] }
        var result = Array(pages[currentIndex..<min(currentIndex + step, pages.count)])

        /*
         Reverse only the presentation copy.  currentIndex and ArchiveBook.pages
         remain in archive order, so direction changes cannot perturb history,
         prefetch ranges, adjacent-volume selection, or page-number semantics.
         */
        if direction == .rightToLeft, pageMode == .double {
            result.reverse()
        }
        return result
    }

    // MARK: - Opening and replacing books

    func chooseBook() {
        let panel = NSOpenPanel()
        panel.title = "Open Comic Book"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ArchiveBook.supportedArchiveExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        beginLoading { try ArchiveBook.load(from: url) }
    }

    /*
     Book replacement is a two-phase transaction:

       1. perform archive I/O and discovery in a detached task;
       2. if its generation is still current, reset pixels and commit on MainActor.

     The old book remains committed throughout phase 1, although ReaderView
     presents loading progress. This makes failure atomic: an invalid new URL
     reports an error without destroying the book already in memory.

     startsAtEnd is used only for backward cross-volume continuation.  The
     final index is aligned down to a spread boundary after the new book is
     known, so both odd and even page counts land on a valid final spread.
     */
    private func beginLoading(
        startsAtEnd: Bool = false,
        _ load: @escaping @Sendable () throws -> ArchiveBook
    ) {
        // Wrapping is safe: only equality with concurrently live tasks matters.
        loadGeneration &+= 1
        let generation = loadGeneration

        /*
         Cancellation saves work when the loader observes it; generation
         comparison below supplies correctness even if it does not.
         */
        archiveLoadTask?.cancel()
        isLoading = true
        errorMessage = nil

        // Archive extraction and directory traversal must never occupy MainActor.
        let loadTask = Task.detached(priority: .userInitiated) {
            try load()
        }
        archiveLoadTask = loadTask

        /*
         This unstructured Task inherits MainActor from beginLoading.  Awaiting
         loadTask suspends the actor rather than blocking it, then state changes
         resume serially on the UI actor.
         */
        Task { [weak self] in
            do {
                let loaded = try await loadTask.value
                guard let self else {
                    // A detached archive load may outlive its window and model.
                    Self.removeTemporaryFilesOffMain(from: loaded)
                    return
                }
                guard generation == self.loadGeneration else {
                    // A newer open won the race; never publish the stale result.
                    Self.removeTemporaryFilesOffMain(from: loaded)
                    return
                }

                let previousBook = self.book

                /*
                 Cache reset is an actor hop and therefore another suspension
                 point.  Recheck the generation afterward: a third open could
                 have begun while the old decoded pages were being discarded.
                 */
                await self.imageStore.reset()
                guard generation == self.loadGeneration else {
                    Self.removeTemporaryFilesOffMain(from: loaded)
                    return
                }
                self.fitReference = nil
                self.book = loaded
                let lastIndex = max(0, loaded.pages.count - 1)
                self.currentIndex =
                    startsAtEnd
                    ? lastIndex - lastIndex % self.step
                    : 0
                self.resetPrefetchBias()
                self.isLoading = false
                self.archiveLoadTask = nil
                Self.removeTemporaryFilesOffMain(from: previousBook)

                /*
                 Recent-document bookkeeping is useful but not part of the book
                 commit.  Yield once so the freshly installed pages can render
                 before asking AppKit to update its menu and persistence state.
                 */
                await Task.yield()
                guard generation == self.loadGeneration else { return }
                NSDocumentController.shared.noteNewRecentDocumentURL(loaded.source)
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                self.archiveLoadTask = nil
                self.isLoading = false

                /*
                 Supersession is silent, as is the absence of a neighbor: turning
                 beyond the first or last available volume should simply stop.
                 Every other failure is actionable and remains visible while the
                 previously committed book stays installed.
                 */
                if !(error is CancellationError), !(error is NoAdjacentVolume) {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /*
     Neighbor enumeration is intentionally demand-driven.  We do not watch the
     directory or build a volume index during ordinary reading; only a boundary
     turn pays for ArchiveBook.adjacentVolume.  The returned volume then follows
     the exact same cancellable, generation-guarded replacement path as Open.
     */
    private func openAdjacent(forward: Bool) {
        guard let source = book?.source, !isLoading else { return }
        beginLoading(startsAtEnd: !forward) {
            try Task.checkCancellation()
            guard
                let adjacent = ArchiveBook.adjacentVolume(
                    to: source,
                    forward: forward
                )
            else {
                throw NoAdjacentVolume()
            }
            return try ArchiveBook.load(from: adjacent)
        }
    }

    // MARK: - Image demand and speculative preparation

    /*
     Views call image(for:) for visible demand.  PageImageStore separately marks
     preparation requests as speculative: identical work coalesces, changed
     resolution demand supersedes obsolete demand, and preparation cancels work
     that has fallen outside the new window.

     The fit reference is updated only if the decoded request is *still*
     visible after the await.  A user may turn a page during decoding; allowing
     that late result to influence the new spread would cause a perceptible zoom
     jump.  In a spread, componentwise maxima incorporate both pages regardless
     of which decode finishes first.
     */
    func image(for request: PageImageRequest) async -> DecodedPage? {
        let page = await imageStore.image(for: request)
        if let page, visiblePages.contains(request.url) {
            let previousSize =
                fitReference.flatMap {
                    $0.index == currentIndex && $0.mode == pageMode
                        ? $0.maximumSourceSize
                        : nil
                } ?? .zero
            fitReference = (
                currentIndex,
                pageMode,
                CGSize(
                    width: max(previousSize.width, page.sourcePixelSize.width),
                    height: max(previousSize.height, page.sourcePixelSize.height)
                )
            )
        }
        return page
    }

    /*
     Construct the complete cache plan for the current page or spread.

       V = visible pages, one or two
       F = up to eight following pages
       B = up to two preceding pages, nearest first

     Both policies submit exactly V union F union B as the retention plan.
     Adaptation changes only ordering, never candidate count, capacity, or
     speculation radius. That is the core performance constraint: prediction
     may improve which decode finishes first and can change the resident byte
     mix, but it cannot raise the hard cache ceiling or wander farther through
     the volume.

     Demand and speculation remain separate.  V enters retentionWindow so it
     receives the strongest eviction rank, but it is absent from
     prefetchRequests because PageImageView requests it at userInitiated
     priority.  F and B are utility-priority work, coalesced by PageImageStore
     if demand catches up with them.  retainsFullResolution tells the store
     whether a still-visible native/full-resolution request remains useful;
     otherwise an expensive detail decode made obsolete by Fit may be canceled.
     */
    func prepareImageWindow(
        maximumPixelDimension: Int,
        retainsFullResolution: Bool
    ) async {
        /*
         Array's copy-on-write snapshot is O(1) here.  It gives all ranges below
         one coherent book generation without copying the URL storage; the only
         suspension occurs after the plan has been fully constructed.
         */
        let pageURLs = pages
        guard !pageURLs.isEmpty else { return }

        let visibleEnd = min(currentIndex + step, pageURLs.count)
        let nextEnd = min(
            visibleEnd + Self.forwardPrefetchPageCount,
            pageURLs.count
        )
        let previousStart = max(
            0,
            currentIndex - Self.backwardBufferPageCount
        )

        let visible = pageURLs[currentIndex..<visibleEnd]
        let upcoming = pageURLs[visibleEnd..<nextEnd]
        let previous = pageURLs[previousStart..<currentIndex].reversed()
        let request: (URL) -> PageImageRequest = {
            PageImageRequest(url: $0, maximumPixelDimension: maximumPixelDimension)
        }

        let upcomingRequests = upcoming.map(request)
        let previousRequests = previous.map(request)
        var retentionWindow = visible.map(request)

        /*
         The default release contains the tiny adaptive ordering.  Defining
         CBR_STATIC_PREFETCH produces the experiment's control binary: the same
         8-forward/2-backward set with no history byte and no reverse bias.

         Two consecutive successful backward turns are sufficient evidence of
         rereading.  One backward turn is commonly a correction, so changing
         policy then would steal decode service from the overwhelmingly common
         forward path.  The counter saturates at two because greater history
         conveys no additional decision.
         */
        let prioritizesBackward: Bool
        #if CBR_STATIC_PREFETCH
            prioritizesBackward = false
        #else
            prioritizesBackward = backwardTurnStreak >= 2
        #endif

        let prefetchRequests: [PageImageRequest]
        if prioritizesBackward {
            /*
             During a sustained reread, previous pages receive both the highest
             speculative decode priority and the highest non-visible retention
             ranks.  Upcoming pages remain in the same bounded plan.
             */
            retentionWindow.append(contentsOf: previousRequests)
            retentionWindow.append(contentsOf: upcomingRequests)
            prefetchRequests = previousRequests + upcomingRequests
        } else {
            /*
             Protect the next possible spread first (at most two pages), then
             the correction buffer, then farther lookahead.  Prefetch itself
             stays wholly forward-first because sequential progression is the
             dominant trace.
             */
            retentionWindow.append(contentsOf: upcomingRequests.prefix(2))
            retentionWindow.append(contentsOf: previousRequests)
            retentionWindow.append(contentsOf: upcomingRequests.dropFirst(2))
            prefetchRequests = upcomingRequests + previousRequests
        }

        await imageStore.prepare(
            retentionWindow: retentionWindow,
            prefetchRequests: prefetchRequests,
            retainsFullResolution: retainsFullResolution
        )
    }

    /*
     Why ship any predictor at all?  The replay corpus found that this one-byte,
     same-window reorder reduced modeled stalled turns during sustained reverse
     reading without a losing trace.  Controlled stripped releases have charged
     only tens of bytes—far below the project's 15 KiB ceiling.  The exact value
     is remeasured by scripts/measure-predictor.sh because compiler layout can
     move it.  A richer predictor was rejected because extra history, allocations,
     or candidates cannot improve the already-covered ordinary next turn enough
     to justify their code and state.  The static build remains a permanent
     escape hatch if future measurements reverse that decision.
     */

    // MARK: - Navigation

    func goForward(continueAcrossVolumes: Bool = false) {
        guard !isLoading else { return }
        guard canGoForward else {
            /*
             Crossing a volume is an explicit boundary behavior, not an eager
             side effect of opening the last page.  Empty books cannot occur
             through ArchiveBook today, but the guard keeps this method total.
             */
            if continueAcrossVolumes, !pages.isEmpty { openAdjacent(forward: true) }
            return
        }
        currentIndex = min(currentIndex + step, max(0, pages.count - 1))

        // Forward motion ends any evidence that the user is rereading backward.
        resetPrefetchBias()
    }

    func goBackward(continueAcrossVolumes: Bool = false) {
        guard !isLoading else { return }
        guard canGoBackward else {
            if continueAcrossVolumes, !pages.isEmpty { openAdjacent(forward: false) }
            return
        }
        currentIndex = max(0, currentIndex - step)

        // Only a successful in-volume turn trains the predictor.
        recordBackwardTurn()
    }

    /*
     Reading direction affects the arrows only in RTL mode.  The optional swap
     restores spatial key semantics for readers who want Left to mean previous
     even while the pages themselves are laid out right-to-left.
     */
    func pageTurnAction(for key: PageTurnKey, swapRTLPageTurnKeys: Bool) -> PageTurnAction {
        let leftKeyGoesForward = direction == .rightToLeft && !swapRTLPageTurnKeys
        switch key {
        case .left:
            return leftKeyGoesForward ? .forward : .backward
        case .right:
            return leftKeyGoesForward ? .backward : .forward
        }
    }

    /// Translate UI convention once, then navigate in archive-order semantics.
    func turnPage(
        for key: PageTurnKey,
        swapRTLPageTurnKeys: Bool,
        continueAcrossVolumes: Bool = false
    ) {
        switch pageTurnAction(for: key, swapRTLPageTurnKeys: swapRTLPageTurnKeys) {
        case .backward:
            goBackward(continueAcrossVolumes: continueAcrossVolumes)
        case .forward:
            goForward(continueAcrossVolumes: continueAcrossVolumes)
        }
    }

    /*
     Across-volume capability is deliberately optimistic.  Asking whether a
     neighbor exists would enumerate the directory during command validation,
     potentially many times per second.  We enable the command for any open
     book and discover the neighbor only when the user actually turns.
     */
    func canTurnBackward(acrossVolumes: Bool) -> Bool {
        !isLoading && (canGoBackward || acrossVolumes && book != nil)
    }

    func canTurnForward(acrossVolumes: Bool) -> Bool {
        !isLoading && (canGoForward || acrossVolumes && book != nil)
    }

    // MARK: - Commands and mode changes

    func requestPageJump() {
        guard !pages.isEmpty else { return }
        pageJumpRequest &+= 1
    }

    /*
     User page numbers are one-based.  Aligning the converted index downward
     means "jump to page 4" in double mode selects the containing 3-4 spread,
     preserving the i mod step invariant.
     */
    @discardableResult
    func jump(toPage page: Int) -> Bool {
        guard page > 0, page <= pages.count else { return false }
        let index = page - 1
        currentIndex = index - index % step
        resetPrefetchBias()
        return true
    }

    func toggleDirection() {
        direction = direction == .leftToRight ? .rightToLeft : .leftToRight
    }

    func togglePageMode() {
        pageMode = pageMode == .single ? .double : .single
    }

    // MARK: - Zoom

    /*
     Entering custom zoom from Fit uses 1 as the command baseline.  Pinch zoom
     supplies the current geometry-derived fit scale directly through
     setZoomScale, so its first movement remains continuous.
     */
    func adjustZoom(by factor: CGFloat) {
        setZoomScale((zoom.scale ?? 1) * factor)
    }

    /// Bound both rendered geometry and downstream decode requests to 10–800%.
    func setZoomScale(_ scale: CGFloat) {
        zoom = .custom(min(8, max(0.1, scale)))
    }

    /*
     fitReference stores source dimensions rather than a viewport-dependent
     answer.  Window resizing can therefore recompute this division cheaply
     without decoding or retaining another image.  Until the visible decode
     supplies trustworthy dimensions, scale 1 is a stable neutral fallback.
     */
    func fitZoomScale(within size: CGSize) -> CGFloat {
        guard let reference = fitReference,
            reference.index == currentIndex,
            reference.mode == pageMode,
            reference.maximumSourceSize.width > 0,
            reference.maximumSourceSize.height > 0
        else {
            return 1
        }
        return min(
            size.width / reference.maximumSourceSize.width,
            size.height / reference.maximumSourceSize.height
        )
    }

    // MARK: - Predictor bookkeeping and cleanup

    /*
     The predictor's complete transition table is:

         reset/open/forward/jump/mode change -> 0
         successful backward from 0         -> 1
         successful backward from 1 or 2    -> 2
         failed boundary turn               -> unchanged

     Only state 2 changes the work order.  Encoding the table in these two
     helpers keeps navigation readable and compiles away in the static control.
     */
    private func resetPrefetchBias() {
        #if !CBR_STATIC_PREFETCH
            backwardTurnStreak = 0
        #endif
    }

    private func recordBackwardTurn() {
        #if !CBR_STATIC_PREFETCH
            // Saturation avoids overflow and represents the entire state machine.
            backwardTurnStreak = min(2, backwardTurnStreak &+ 1)
        #endif
    }

    /*
     ArchiveBook may own an extracted temporary tree. Deleting it can involve
     thousands of filesystem operations, so replacements and discarded load
     results enqueue utility work rather than stalling MainActor. ArchiveBook's
     deinit remains the synchronous, best-effort safety net at ordinary release.
     */
    private nonisolated static func removeTemporaryFilesOffMain(
        from book: ArchiveBook?
    ) {
        guard let book else { return }
        Task.detached(priority: .utility) {
            book.removeTemporaryFiles()
        }
    }

}

/// Internal control flow: absence of a neighbor is not a user-facing failure.
private struct NoAdjacentVolume: Error {}
