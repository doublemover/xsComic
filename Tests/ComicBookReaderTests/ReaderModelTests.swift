import XCTest
@testable import ComicBookReader

/// Behavioral specification for the reader state machine.
///
/// ReaderModel owns navigation and transactional book replacement; SwiftUI
/// merely presents that state. These tests invoke the model as a user would so
/// menu, toolbar, keyboard, and gesture entry points cannot acquire subtly
/// different semantics.
@MainActor
final class ReaderModelTests: XCTestCase {
    /// A compact happy-path grammar: open, turn, change spread/direction, and
    /// verify both indices and the user-visible status at each boundary.
    func testOpenNavigationPageModesDirectionAndStatus() async throws {
        let directory = try makeBook(pageCount: 5)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reader = ReaderModel()
        reader.open(directory)
        try await waitUntilLoaded(reader)

        XCTAssertNil(reader.errorMessage)
        XCTAssertEqual(
            reader.pages.map(\.lastPathComponent),
            [
                "page1.png", "page2.png", "page3.png", "page4.png", "page5.png",
            ])
        XCTAssertEqual(reader.currentIndex, 0)
        XCTAssertEqual(reader.status, "1 / 5")
        XCTAssertFalse(reader.canGoBackward)
        XCTAssertTrue(reader.canGoForward)

        reader.goBackward()
        XCTAssertEqual(reader.currentIndex, 0)
        reader.goForward()
        XCTAssertEqual(reader.currentIndex, 1)
        XCTAssertEqual(reader.status, "2 / 5")

        reader.togglePageMode()
        XCTAssertEqual(reader.pageMode, .double)
        XCTAssertEqual(reader.currentIndex, 0)
        XCTAssertEqual(reader.status, "1–2 / 5")
        XCTAssertEqual(reader.visiblePages.map(\.lastPathComponent), ["page1.png", "page2.png"])

        reader.toggleDirection()
        XCTAssertEqual(reader.direction, .rightToLeft)
        XCTAssertEqual(reader.visiblePages.map(\.lastPathComponent), ["page2.png", "page1.png"])

        reader.goForward()
        XCTAssertEqual(reader.currentIndex, 2)
        XCTAssertEqual(reader.status, "3–4 / 5")
        reader.goForward()
        XCTAssertEqual(reader.currentIndex, 4)
        XCTAssertEqual(reader.status, "5 / 5")
        XCTAssertFalse(reader.canGoForward)
        reader.goBackward()
        XCTAssertEqual(reader.currentIndex, 2)
    }

    /// Opening is transactional. A failed replacement reports an error without
    /// destroying the volume that is still readable.
    func testFailedOpenPreservesCurrentBookAndReportsError() async throws {
        let directory = try makeBook(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reader = ReaderModel()
        reader.open(directory)
        try await waitUntilLoaded(reader)
        let originalBook = try XCTUnwrap(reader.book)

        reader.open(directory.appendingPathComponent("missing.cbz"))
        try await waitUntilLoaded(reader)

        XCTAssertTrue(reader.book === originalBook)
        XCTAssertEqual(reader.pages.count, 2)
        XCTAssertEqual(reader.errorMessage, "The selected file no longer exists.")
    }

    /// The 10–800% bounds prevent degenerate transforms, while visiting fit mode
    /// must not corrupt subsequent custom zoom arithmetic.
    func testZoomAdjustmentClampsAndTogglesRemainReversible() {
        let reader = ReaderModel()

        reader.adjustZoom(by: 100)
        XCTAssertEqual(reader.zoom, .custom(8))
        reader.adjustZoom(by: 0.0001)
        XCTAssertEqual(reader.zoom, .custom(0.1))
        reader.setZoomScale(2.5)
        XCTAssertEqual(reader.zoom, .custom(2.5))

        reader.toggleDirection()
        reader.togglePageMode()
        XCTAssertEqual(reader.direction, .rightToLeft)
        XCTAssertEqual(reader.pageMode, .double)
        reader.toggleDirection()
        reader.togglePageMode()
        XCTAssertEqual(reader.direction, .leftToRight)
        XCTAssertEqual(reader.pageMode, .single)
    }

    /// A spread is constrained by both page aspect ratios. Measuring only the
    /// first image would clip asymmetric art or waste half the window.
    func testFitScaleUsesEveryVisiblePageInASpread() async throws {
        let directory = try PageImageTestFixture.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page1 = directory.appendingPathComponent("page1.png")
        let page2 = directory.appendingPathComponent("page2.png")
        try PageImageTestFixture.writePNG(at: page1, width: 100, height: 200)
        try PageImageTestFixture.writePNG(at: page2, width: 300, height: 100)

        let reader = ReaderModel()
        reader.open(directory)
        try await waitUntilLoaded(reader)
        reader.togglePageMode()

        for page in reader.pages {
            let decoded = await reader.image(
                for: PageImageRequest(
                    url: page,
                    maximumPixelDimension: 100
                ))
            XCTAssertNotNil(decoded)
        }
        XCTAssertEqual(
            reader.fitZoomScale(within: CGSize(width: 300, height: 300)),
            1,
            accuracy: 0.001
        )

        reader.toggleDirection()
        XCTAssertEqual(
            reader.fitZoomScale(within: CGSize(width: 300, height: 300)),
            1,
            accuracy: 0.001
        )

        reader.togglePageMode()
        let singlePage = await reader.image(
            for: PageImageRequest(
                url: reader.pages[0],
                maximumPixelDimension: 100
            ))
        XCTAssertEqual(singlePage?.sourcePixelSize, CGSize(width: 100, height: 200))
        XCTAssertEqual(
            reader.fitZoomScale(within: CGSize(width: 300, height: 300)),
            1.5,
            accuracy: 0.001
        )
    }

    /// LTR is the control case: an RTL-specific preference cannot perturb it.
    func testLTRPageTurnKeysAreUnaffectedByRTLSetting() {
        let reader = ReaderModel()
        reader.direction = .leftToRight

        for swapKeys in [false, true] {
            XCTAssertEqual(reader.pageTurnAction(for: .left, swapRTLPageTurnKeys: swapKeys), .backward)
            XCTAssertEqual(reader.pageTurnAction(for: .right, swapRTLPageTurnKeys: swapKeys), .forward)
        }
    }

    /// By default, physical arrows follow the visual reading direction in RTL.
    func testDefaultRTLPageTurnKeysFollowReadingDirection() {
        let reader = ReaderModel()
        reader.direction = .rightToLeft

        XCTAssertEqual(reader.pageTurnAction(for: .left, swapRTLPageTurnKeys: false), .forward)
        XCTAssertEqual(reader.pageTurnAction(for: .right, swapRTLPageTurnKeys: false), .backward)
    }

    /// Some readers prefer invariant physical keys; this opt-in is separate so
    /// its otherwise confusing double-negative remains executable documentation.
    func testRTLPageTurnKeysCanBeSwapped() {
        let reader = ReaderModel()
        reader.direction = .rightToLeft

        XCTAssertEqual(reader.pageTurnAction(for: .left, swapRTLPageTurnKeys: true), .backward)
        XCTAssertEqual(reader.pageTurnAction(for: .right, swapRTLPageTurnKeys: true), .forward)
    }

    /// Page numbers are one-based, bounded, and aligned to a spread beginning so
    /// a valid requested page cannot wind up hidden off-spread.
    func testJumpValidatesPageNumberAndAlignsSpreads() async throws {
        let directory = try makeBook(pageCount: 5)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reader = ReaderModel()
        reader.open(directory)
        try await waitUntilLoaded(reader)

        XCTAssertTrue(reader.jump(toPage: 4))
        XCTAssertEqual(reader.currentIndex, 3)
        reader.togglePageMode()
        XCTAssertEqual(reader.currentIndex, 2)
        XCTAssertTrue(reader.jump(toPage: 5))
        XCTAssertEqual(reader.currentIndex, 4)
        XCTAssertFalse(reader.jump(toPage: .min))
        XCTAssertFalse(reader.jump(toPage: 0))
        XCTAssertFalse(reader.jump(toPage: 6))
        XCTAssertEqual(reader.currentIndex, 4)
    }

    /// Crossing an endpoint is one logical turn. Verify natural neighbor order
    /// and first/last-page placement in both directions.
    func testBoundaryTurnsContinueThroughNaturallySortedVolumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComicBookReaderVolumes-\(UUID().uuidString)",
            isDirectory: true
        )
        let volume2 = root.appendingPathComponent("Volume 2", isDirectory: true)
        let volume10 = root.appendingPathComponent("Volume 10", isDirectory: true)
        try makeBook(at: volume2, pageCount: 2)
        try makeBook(at: volume10, pageCount: 3)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Volume 3 Notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = ReaderModel()
        reader.open(volume2)
        try await waitUntilLoaded(reader)
        reader.goForward()
        reader.goForward()
        XCTAssertEqual(reader.book?.source, volume2)

        reader.goForward(continueAcrossVolumes: true)
        try await waitUntilLoaded(reader)
        XCTAssertEqual(
            reader.book?.source.resolvingSymlinksInPath(),
            volume10.resolvingSymlinksInPath()
        )
        XCTAssertEqual(reader.currentIndex, 0)

        reader.goBackward(continueAcrossVolumes: true)
        try await waitUntilLoaded(reader)
        XCTAssertEqual(
            reader.book?.source.resolvingSymlinksInPath(),
            volume2.resolvingSymlinksInPath()
        )
        XCTAssertEqual(reader.currentIndex, 1)
    }

    /// Disabling continuation restores a hard boundary without weakening
    /// ordinary within-volume navigation predicates.
    func testBoundaryTurnsStayPutWhenContinuationIsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComicBookReaderVolumes-\(UUID().uuidString)",
            isDirectory: true
        )
        let volume1 = root.appendingPathComponent("Volume 1", isDirectory: true)
        let volume2 = root.appendingPathComponent("Volume 2", isDirectory: true)
        try makeBook(at: volume1, pageCount: 1)
        try makeBook(at: volume2, pageCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = ReaderModel()
        reader.open(volume1)
        try await waitUntilLoaded(reader)

        reader.goForward()
        XCTAssertEqual(
            reader.book?.source.resolvingSymlinksInPath(),
            volume1.resolvingSymlinksInPath()
        )
        XCTAssertFalse(reader.isLoading)
    }

    private func makeBook(pageCount: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComicBookReaderModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try makeBook(at: directory, pageCount: pageCount)
        return directory
    }

    private func makeBook(at directory: URL, pageCount: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for page in (1...pageCount).reversed() {
            try Data().write(to: directory.appendingPathComponent("page\(page).png"))
        }
    }

    private func waitUntilLoaded(_ reader: ReaderModel) async throws {
        for _ in 0..<300 {
            if !reader.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reader did not finish loading within three seconds.")
    }
}
