import AppKit
import XCTest
@testable import ComicBookReader

/// Specification for the reader's most performance-sensitive ownership edge.
///
/// Equal requests coalesce, previews decode near display size, failures are
/// memoized, visible detail survives speculative pressure, and retained work
/// stays bounded. Identity assertions are intentional: they expose an
/// accidental second decode that pixel equality would miss.
final class PageImageStoreTests: XCTestCase {
    /// These constants are product policy and are copied into every metrics
    /// record: eight pages ahead, two behind, twelve entries, at most 64 MiB.
    func testRuntimePolicyRemainsSmallAndBounded() {
        XCTAssertEqual(PageImageStore.byteLimit, 64 * 1_024 * 1_024)
        XCTAssertEqual(PageImageStore.entryLimit, 12)
        XCTAssertEqual(ReaderModel.forwardPrefetchPageCount, 8)
        XCTAssertEqual(ReaderModel.backwardBufferPageCount, 2)
        print(
            "CBR_POLICY"
                + " image_cache_limit_bytes=\(PageImageStore.byteLimit)"
                + " image_cache_entry_limit=\(PageImageStore.entryLimit)"
                + " forward_prefetch_pages=\(ReaderModel.forwardPrefetchPageCount)"
                + " backward_buffer_pages=\(ReaderModel.backwardBufferPageCount)"
        )
    }

    /// A nil dimension means native detail and must not be silently satisfied by
    /// the smaller preview that speculative work may already have produced.
    func testValidPNGDecodesAtFullResolution() async throws {
        let fixture = try PageImageTestFixture.makePNG(width: 96, height: 48)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = PageImageStore()
        let request = PageImageRequest(url: fixture.file, maximumPixelDimension: nil)
        let result = await store.image(for: request)
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page.sourcePixelSize, CGSize(width: 96, height: 48))
        XCTAssertEqual(page.image.size, CGSize(width: 96, height: 48))
        XCTAssertEqual(page.decodedByteCount, 96 * 48 * 4)
    }

    /// Downsampling saves CPU and resident memory, while source geometry remains
    /// available for physically correct fit-to-window calculations.
    func testViewportRequestDownsamplesButPreservesSourcePixelSize() async throws {
        let fixture = try PageImageTestFixture.makePNG(width: 320, height: 160)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = PageImageStore()
        let previewRequest = PageImageRequest(
            url: fixture.file,
            maximumPixelDimension: 80
        )
        let previewResult = await store.image(for: previewRequest)
        let preview = try XCTUnwrap(previewResult)

        XCTAssertEqual(preview.sourcePixelSize, CGSize(width: 320, height: 160))
        XCTAssertEqual(preview.image.size, CGSize(width: 320, height: 160))
        XCTAssertEqual(preview.decodedByteCount, 80 * 40 * 4)

        let fullRequest = PageImageRequest(url: fixture.file, maximumPixelDimension: nil)
        let fullResult = await store.image(for: fullRequest)
        let full = try XCTUnwrap(fullResult)
        XCTAssertEqual(full.image.size, CGSize(width: 320, height: 160))
        XCTAssertEqual(full.decodedByteCount, 320 * 160 * 4)
        XCTAssertFalse(preview === full)
        XCTAssertLessThan(preview.decodedByteCount, full.decodedByteCount)
    }

    /// Reset is a generation boundary: cache identity is stable within one book
    /// but may never cross into the next book.
    func testSameRequestReturnsCachedIdentityAndResetDropsIt() async throws {
        let fixture = try PageImageTestFixture.makePNG(width: 64, height: 32)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = PageImageStore()
        let request = PageImageRequest(url: fixture.file, maximumPixelDimension: 32)
        let firstResult = await store.image(for: request)
        let first = try XCTUnwrap(firstResult)
        let cachedResult = await store.image(for: request)
        let cached = try XCTUnwrap(cachedResult)
        XCTAssertTrue(first === cached)

        await store.reset()
        let reloadedResult = await store.image(for: request)
        let reloaded = try XCTUnwrap(reloadedResult)
        XCTAssertFalse(first === reloaded)
    }

    /// SwiftUI can ask twice during one render pass. Coalescing avoids duplicate
    /// ImageIO decodes and duplicate decoded-pixel allocations.
    func testConcurrentRequestsCoalesceToTheSamePage() async throws {
        let fixture = try PageImageTestFixture.makePNG(width: 512, height: 512)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = PageImageRequest(url: fixture.file, maximumPixelDimension: 256)

        for _ in 0..<8 {
            let store = PageImageStore()
            async let first = store.image(for: request)
            async let second = store.image(for: request)
            let pages = await (first, second)

            XCTAssertNotNil(pages.0)
            XCTAssertTrue(pages.0 === pages.1)
        }
    }

    /// Speculation is subordinate to the screen: filling every preview slot must
    /// not evict native detail that the user is actively inspecting.
    func testVisibleDetailSurvivesAFullCache() async throws {
        let directory = try PageImageTestFixture.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = (0...12).map {
            directory.appendingPathComponent("page\($0).png")
        }
        for file in files {
            try PageImageTestFixture.writePNG(at: file, width: 32, height: 32)
        }

        let visiblePreview = PageImageRequest(
            url: files[0],
            maximumPixelDimension: 16
        )
        let otherPreviews = files.dropFirst().map {
            PageImageRequest(url: $0, maximumPixelDimension: 16)
        }
        let store = PageImageStore()
        await store.prepare(
            retentionWindow: [visiblePreview] + otherPreviews,
            prefetchRequests: [],
            retainsFullResolution: true
        )

        let visibleDetail = PageImageRequest(url: files[0], maximumPixelDimension: nil)
        let firstDetailResult = await store.image(for: visibleDetail)
        let firstDetail = try XCTUnwrap(firstDetailResult)
        for request in otherPreviews {
            _ = await store.image(for: request)
        }
        let cachedDetailResult = await store.image(for: visibleDetail)
        let cachedDetail = try XCTUnwrap(cachedDetailResult)

        XCTAssertTrue(
            firstDetail === cachedDetail,
            "Demand detail should inherit the visible preview's retention rank."
        )
    }

    /// Failure caching stops repeated I/O on every page turn; reset deliberately
    /// gives a repaired or replaced file a fresh attempt.
    func testCorruptImageFailureIsCachedUntilReset() async throws {
        let directory = try PageImageTestFixture.makeTemporaryDirectory()
        let file = directory.appendingPathComponent("page.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not an image".utf8).write(to: file)

        let store = PageImageStore()
        let request = PageImageRequest(url: file, maximumPixelDimension: 64)
        let corruptResult = await store.image(for: request)
        XCTAssertNil(corruptResult)

        try PageImageTestFixture.writePNG(at: file, width: 64, height: 32)
        let cachedFailure = await store.image(for: request)
        XCTAssertNil(
            cachedFailure,
            "A known failure should not be decoded repeatedly during view updates."
        )

        await store.reset()
        let recoveredResult = await store.image(for: request)
        XCTAssertNotNil(recoveredResult)
    }

    /// Animated formats multiply decoded cost. Prefetch retains a bounded
    /// preview and declines to retain a native animation indefinitely.
    func testGIFPrefetchIsDownsampledAndNativeImageIsNotCached() async throws {
        let fixture = try PageImageTestFixture.makeGIF(width: 320, height: 160)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = PageImageStore()
        let previewRequest = PageImageRequest(
            url: fixture.file,
            maximumPixelDimension: 80
        )
        XCTAssertEqual(previewRequest.maximumPixelDimension, 80)

        let previewResult = await store.image(for: previewRequest)
        let preview = try XCTUnwrap(previewResult)
        XCTAssertEqual(preview.sourcePixelSize, CGSize(width: 320, height: 160))
        XCTAssertLessThan(preview.decodedByteCount, 320 * 160 * 4)

        let nativeRequest = PageImageRequest(
            url: fixture.file,
            maximumPixelDimension: nil
        )
        let firstNativeResult = await store.image(for: nativeRequest)
        let firstNative = try XCTUnwrap(firstNativeResult)
        let secondNativeResult = await store.image(for: nativeRequest)
        let secondNative = try XCTUnwrap(secondNativeResult)
        XCTAssertFalse(
            firstNative === secondNative,
            "Native GIFs may retain multiple frames and must remain outside the bounded cache."
        )
    }
}
