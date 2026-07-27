import AppKit
import Foundation
import XCTest
@testable import ComicBookReader

/// Reproducible probes for the three costs a page turn can expose: discovering
/// names, opening an archive, and decoding pixels.
///
/// They are opt-in tests rather than production instrumentation. Clocks,
/// fixture generators, and reporting strings therefore add nothing to the
/// distributed executable; `scripts/measure.sh` captures their `CBR_METRIC`
/// lines together with machine and toolchain identity.
final class PerformanceTests: XCTestCase {
    /// 4,096 empty image files isolate recursive enumeration and natural sorting
    /// from image decoding. A warm-up absorbs one-time framework initialization.
    func testDirectoryScanBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CBR_BENCHMARK"] == "1" else {
            throw XCTSkip("Set CBR_BENCHMARK=1 to run performance benchmarks.")
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ComicBookReaderBenchmark-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let chapterCount = 16
        let pagesPerChapter = 256
        let pageCount = chapterCount * pagesPerChapter

        for chapter in (1...chapterCount).reversed() {
            let directory = root.appendingPathComponent("chapter\(chapter)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            for page in (1...pagesPerChapter).reversed() {
                let pageURL = directory.appendingPathComponent("page\(page).jpg")
                XCTAssertTrue(fileManager.createFile(atPath: pageURL.path, contents: Data()))
            }
            XCTAssertTrue(
                fileManager.createFile(
                    atPath: directory.appendingPathComponent("notes.txt").path,
                    contents: Data()
                )
            )
        }

        let warmup = try ArchiveBook.load(from: root)
        XCTAssertEqual(warmup.pages.count, pageCount)

        var samples = [Double]()
        samples.reserveCapacity(7)
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            let book = try ArchiveBook.load(from: root)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertEqual(book.pages.count, pageCount)
            samples.append(Double(elapsed) / 1_000_000)
        }

        // Median, rather than mean, resists an occasional filesystem scheduling
        // outlier while fastest/slowest retain visibility into that spread.
        samples.sort()
        let median = samples[samples.count / 2]
        let fastest = samples[0]
        let slowest = samples[samples.count - 1]
        print(
            String(
                format: "CBR_METRIC archive_scan pages=%d samples=%d median_ms=%.3f fastest_ms=%.3f slowest_ms=%.3f",
                pageCount,
                samples.count,
                median,
                fastest,
                slowest
            )
        )
    }

    /// A deterministic incompressible payload stabilizes archive work without
    /// checking a large opaque fixture into the repository.
    func testCBZOpenBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CBR_BENCHMARK"] == "1" else {
            throw XCTSkip("Set CBR_BENCHMARK=1 to run performance benchmarks.")
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ComicBookReaderBenchmark-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        let archive = root.appendingPathComponent("benchmark.cbz")
        try fileManager.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        // Fixed-seed xorshift data needs neither a random device nor a package.
        var state: UInt32 = 0xC0FFEE
        let pageData = Data(
            (0..<8_192).map { _ in
                state = 1_664_525 &* state &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 24)
            })
        let pageCount = 128
        for page in 1...pageCount {
            try pageData.write(to: input.appendingPathComponent("page\(page).jpg"))
        }
        try ZIPTestFixture.create(at: archive, from: input)

        let warmup = try ArchiveBook.load(from: archive)
        XCTAssertEqual(warmup.pages.count, pageCount)
        warmup.removeTemporaryFiles()

        var samples = [Double]()
        samples.reserveCapacity(5)
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let book = try ArchiveBook.load(from: archive)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertEqual(book.pages.count, pageCount)
            samples.append(Double(elapsed) / 1_000_000)
            book.removeTemporaryFiles()
        }

        samples.sort()
        let archiveBytes = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print(
            String(
                format: "CBR_METRIC cbz_open pages=%d archive_bytes=%d samples=%d median_ms=%.3f fastest_ms=%.3f slowest_ms=%.3f",
                pageCount,
                archiveBytes,
                samples.count,
                samples[samples.count / 2],
                samples[0],
                samples[samples.count - 1]
            )
        )
    }

    /// Cold ImageIO decode and hot identity lookup are reported separately;
    /// averaging them would conceal a regression in either half.
    func testImageDecodeAndCacheBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["CBR_BENCHMARK"] == "1" else {
            throw XCTSkip("Set CBR_BENCHMARK=1 to run performance benchmarks.")
        }

        let fixture = try PageImageTestFixture.makePNG(width: 1_600, height: 1_200)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = PageImageStore()
        let request = PageImageRequest(url: fixture.file, maximumPixelDimension: 768)
        var coldDecodeSamples = [Double]()
        coldDecodeSamples.reserveCapacity(5)

        for _ in 0..<5 {
            await store.reset()
            let start = DispatchTime.now().uptimeNanoseconds
            let result = await store.image(for: request)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let page = try XCTUnwrap(result)
            XCTAssertEqual(page.sourcePixelSize, CGSize(width: 1_600, height: 1_200))
            XCTAssertEqual(page.image.size, CGSize(width: 1_600, height: 1_200))
            XCTAssertEqual(page.decodedByteCount, 768 * 576 * 4)
            coldDecodeSamples.append(Double(elapsed) / 1_000_000)
        }

        let cachedResult = await store.image(for: request)
        let cached = try XCTUnwrap(cachedResult)
        // Batch cache hits so timer quantization and task scheduling are small
        // relative to the measured interval.
        let hitCount = 500
        var cacheHitSamples = [Double]()
        cacheHitSamples.reserveCapacity(7)
        for _ in 0..<7 {
            var identityMismatch = false
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<hitCount {
                guard let hit = await store.image(for: request) else {
                    identityMismatch = true
                    continue
                }
                identityMismatch = identityMismatch || hit !== cached
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertFalse(identityMismatch)
            cacheHitSamples.append(Double(elapsed) / Double(hitCount) / 1_000_000)
        }

        coldDecodeSamples.sort()
        cacheHitSamples.sort()
        print(
            String(
                format: "CBR_METRIC image_decode source_width=%d source_height=%d preview_dimension=%d cold_samples=%d cache_samples=%d cold_ms=%.3f cache_hit_ms=%.6f decoded_bytes=%d",
                1_600,
                1_200,
                768,
                coldDecodeSamples.count,
                cacheHitSamples.count,
                coldDecodeSamples[coldDecodeSamples.count / 2],
                cacheHitSamples[cacheHitSamples.count / 2],
                cached.decodedByteCount
            )
        )
    }
}
