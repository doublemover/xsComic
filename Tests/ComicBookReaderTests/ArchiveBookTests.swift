import Darwin
import Foundation
import XCTest
@testable import ComicBookReader

/// Executable specification for the boundary between a "book" and the host
/// filesystem.
///
/// These tests favor small real directories and real archive processes over
/// mocks. Traversal order, package detection, `bsdtar` behavior, cancellation,
/// and temporary-directory ownership are the feature; a mock would mostly
/// prove that it agrees with itself.
final class ArchiveBookTests: XCTestCase {
    /// One fixture combines recursion, filtering, and natural order because the
    /// important invariant is the final reader-visible sequence.
    func testDirectoryScanRecursesSortsNaturallyAndFiltersUnsupportedEntries() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for path in [
            "Chapter10/page1.PNG",
            "Chapter2/page10.JPG",
            "Chapter2/page2.JPEG",
            "cover1.webp",
            "notes.txt",
            ".hidden.png",
            ".hidden/page1.png",
            "Ignored.app/Contents/page1.png",
        ] {
            try writeFile(path, in: directory)
        }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("not-a-regular-file.png", isDirectory: true),
            withIntermediateDirectories: true
        )

        let book = try ArchiveBook.load(from: directory)

        XCTAssertEqual(
            relativePaths(of: book.pages, under: directory),
            [
                "Chapter2/page2.JPEG",
                "Chapter2/page10.JPG",
                "Chapter10/page1.PNG",
                "cover1.webp",
            ])
        XCTAssertNil(book.extractedDirectory)
    }

    /// A comic directory may contain aliases or symlinks created by an archive
    /// tool. Following one would make the page table escape the selected book
    /// and would turn later decoding into an arbitrary filesystem read.
    func testDirectoryScanDoesNotFollowSymbolicLinks() throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("book", isDirectory: true)
        let outside = root.appendingPathComponent("outside.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFile("page.png", in: directory)
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.png"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let book = try ArchiveBook.load(from: directory)

        XCTAssertEqual(book.pages.map(\.lastPathComponent), ["page.png"])
    }

    /// Extension matching is centralized and case-insensitive. This table test
    /// makes adding a decoder format an explicit contract change.
    func testEverySupportedImageExtensionIsRecognizedCaseInsensitively() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let extensions = [
            "AVIF", "BMP", "GIF", "HEIC", "HEIF", "JPEG",
            "JPG", "PNG", "TIF", "TIFF", "WEBP",
        ]
        let expectedNames = extensions.enumerated().map { "page\($0.offset + 1).\($0.element)" }
        for name in expectedNames.reversed() {
            try writeFile(name, in: directory)
        }

        let book = try ArchiveBook.load(from: directory)
        XCTAssertEqual(book.pages.map(\.lastPathComponent), expectedNames)
    }

    /// ReaderModel presents this error directly, so it must explain the category
    /// rather than leak an opaque Cocoa error number.
    func testUnsupportedFileProducesUsefulError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try ArchiveBook.load(from: file)) { error in
            guard let archiveError = error as? ArchiveError else {
                return XCTFail("Expected ArchiveError, got \(error)")
            }
            guard case .unsupportedFormat(let pathExtension) = archiveError else {
                return XCTFail("Expected unsupportedFormat, got \(archiveError)")
            }
            XCTAssertEqual(pathExtension, "pdf")
            XCTAssertTrue(error.localizedDescription.contains("Unsupported archive format"))
        }
    }

    /// A vanished Finder item follows a distinct path from an unsupported file;
    /// preserving that distinction makes recovery obvious.
    func testMissingFileProducesUsefulError() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("cbz")

        XCTAssertThrowsError(try ArchiveBook.load(from: file)) { error in
            guard let archiveError = error as? ArchiveError else {
                return XCTFail("Expected ArchiveError, got \(error)")
            }
            guard case .missingFile = archiveError else {
                return XCTFail("Expected missingFile, got \(archiveError)")
            }
            XCTAssertEqual(error.localizedDescription, "The selected file no longer exists.")
        }
    }

    /// Neighbor discovery reuses page sorting: "Volume 10" follows "Volume 2",
    /// while unrelated files cannot become navigation targets.
    func testAdjacentVolumesUseNaturalOrderAndIgnoreUnsupportedFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume2 = directory.appendingPathComponent("Volume 2.cbz")
        let volume10 = directory.appendingPathComponent("Volume 10.cbz")
        for url in [
            directory.appendingPathComponent("Volume 1.cbz"),
            volume2,
            volume10,
            directory.appendingPathComponent("notes.pdf"),
            directory.appendingPathComponent(".hidden.cbz"),
        ] {
            try Data().write(to: url)
        }
        try writeFile("Volume 3 Notes/readme.txt", in: directory)
        try writeFile("Volume 4.app/Contents/page.png", in: directory)

        XCTAssertEqual(
            ArchiveBook.adjacentVolume(to: volume2, forward: true)?.resolvingSymlinksInPath(),
            volume10.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            ArchiveBook.adjacentVolume(to: volume10, forward: false)?.resolvingSymlinksInPath(),
            volume2.resolvingSymlinksInPath()
        )
    }

    /// Empty directories are rejected so adjacent-volume traversal cannot enter
    /// a volume from which no page turn is possible.
    func testDirectoryWithoutImagesReportsError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile("notes.txt", in: directory)

        XCTAssertThrowsError(try ArchiveBook.load(from: directory)) { error in
            guard case ArchiveError.noImages = error else {
                return XCTFail("Expected noImages, got \(error)")
            }
        }
    }

    /// Exercise the complete external-tool path and finally prove RAII cleanup
    /// of the extraction tree when the ArchiveBook is released.
    func testCBZArchiveIsExtractedAndSorted() throws {
        let root = try makeTemporaryDirectory()
        let input = root.appendingPathComponent("input", isDirectory: true)
        let archive = root.appendingPathComponent("sample.cbz")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["003.png", "001.png", "002.png"] {
            try writeFile(name, in: input, contents: Data([0]))
        }

        try ZIPTestFixture.create(at: archive, from: input)
        XCTAssertEqual(
            Array(try Data(contentsOf: archive, options: .mappedIfSafe).prefix(4)),
            [0x50, 0x4b, 0x03, 0x04],
            "The fixture must be a ZIP archive, not a tar file with a .cbz extension."
        )

        var book: ArchiveBook? = try ArchiveBook.load(from: archive)
        XCTAssertEqual(book?.pages.map(\.lastPathComponent), ["001.png", "002.png", "003.png"])
        let extractedDirectory = try XCTUnwrap(book?.extractedDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedDirectory.path))

        book = nil
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: extractedDirectory.path),
            "Releasing a book must remove its extracted files."
        )
    }

    /// The tar branch is a separate system-codec path from ZIP. Keep one real
    /// CBT fixture so the public format table cannot drift into wishful prose.
    func testCBTArchiveIsExtractedAndSorted() throws {
        let root = try makeTemporaryDirectory()
        let input = root.appendingPathComponent("input", isDirectory: true)
        let archive = root.appendingPathComponent("sample.cbt")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["page10.png", "page2.png"] {
            try writeFile(name, in: input)
        }

        try ArchiveTestFixture.create(at: archive, from: input, format: "ustar")
        let book = try ArchiveBook.load(from: archive)

        XCTAssertEqual(book.pages.map(\.lastPathComponent), ["page2.png", "page10.png"])
    }

    /// libarchive's extraction policy rejects parent traversal before writing.
    /// This test fixes that host-tool assumption in place: changing tools or
    /// flags may not silently turn opening a comic into an arbitrary file write.
    func testArchiveCannotEscapeItsExtractionDirectory() throws {
        let root = try makeTemporaryDirectory()
        let input = root.appendingPathComponent("input", isDirectory: true)
        let nested = input.appendingPathComponent("nested", isDirectory: true)
        let escapedName = "escape-\(UUID().uuidString).png"
        let archive = root.appendingPathComponent("traversal.cbz")
        let escaped = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicBookReader", isDirectory: true)
            .appendingPathComponent(escapedName)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile(escapedName, in: input)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: escaped)
        }

        try ArchiveTestFixture.create(
            at: archive,
            from: nested,
            format: "zip",
            members: ["../\(escapedName)"]
        )

        XCTAssertThrowsError(try ArchiveBook.load(from: archive)) { error in
            guard case ArchiveError.extractionFailed = error else {
                return XCTFail("Expected extractionFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        let temporaryRoot = escaped.deletingLastPathComponent()
        let leakedNames =
            FileManager.default.enumerator(atPath: temporaryRoot.path)?
            .compactMap { item -> String? in
                guard let path = item as? String else { return nil }
                return URL(fileURLWithPath: path).lastPathComponent
            } ?? []
        XCTAssertFalse(leakedNames.contains(escapedName))
    }

    /// Failure after successful extraction is the subtle ownership case: the
    /// partially useful directory still belongs to ArchiveBook and must vanish.
    func testArchiveWithoutImagesReportsErrorAndRemovesExtractionDirectory() throws {
        let root = try makeTemporaryDirectory()
        let input = root.appendingPathComponent("input", isDirectory: true)
        let archive = root.appendingPathComponent("no-images.cbz")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("notes.txt", in: input, contents: Data("not an image".utf8))
        try ZIPTestFixture.create(at: archive, from: input)

        let extractionDirectoriesBefore = temporaryExtractionDirectories()
        XCTAssertThrowsError(try ArchiveBook.load(from: archive)) { error in
            guard let archiveError = error as? ArchiveError else {
                return XCTFail("Expected ArchiveError, got \(error)")
            }
            guard case .noImages = archiveError else {
                return XCTFail("Expected noImages, got \(archiveError)")
            }
            XCTAssertEqual(error.localizedDescription, "No readable images were found in this book.")
        }
        XCTAssertEqual(temporaryExtractionDirectories(), extractionDirectoriesBefore)
    }

    /// A tool failure must report extraction—not merely "empty book"—and leave
    /// no UUID directory behind in temporary storage.
    func testCorruptArchiveReportsExtractionFailureAndRemovesExtractionDirectory() throws {
        let root = try makeTemporaryDirectory()
        let archive = root.appendingPathComponent("corrupt.cbz")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("this is not an archive".utf8).write(to: archive)

        let extractionDirectoriesBefore = temporaryExtractionDirectories()
        XCTAssertThrowsError(try ArchiveBook.load(from: archive)) { error in
            guard let archiveError = error as? ArchiveError else {
                return XCTFail("Expected ArchiveError, got \(error)")
            }
            guard case .extractionFailed(let message) = archiveError else {
                return XCTFail("Expected extractionFailed, got \(archiveError)")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(error.localizedDescription.contains("The archive could not be opened:"))
        }
        XCTAssertEqual(temporaryExtractionDirectories(), extractionDirectoriesBefore)
    }

    /// Cancellation is a latency guarantee. A FIFO holds `bsdtar` indefinitely
    /// so cancelling Swift work must terminate the child and reclaim its output.
    func testCancellingLoadTerminatesBlockedArchiveProcessPromptly() async throws {
        let root = try makeTemporaryDirectory()
        let archive = root.appendingPathComponent("blocked.cbz")
        defer { try? FileManager.default.removeItem(at: root) }
        guard Darwin.mkfifo(archive.path, S_IRUSR | S_IWUSR) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let extractionDirectoriesBefore = temporaryExtractionDirectories()
        let loadTask = Task.detached(priority: .userInitiated) {
            try ArchiveBook.load(from: archive)
        }
        let probe = ArchiveLoadCompletionProbe()
        let observer = Task.detached {
            do {
                _ = try await loadTask.value
                await probe.finish(wasCancelled: false)
            } catch is CancellationError {
                await probe.finish(wasCancelled: true)
            } catch {
                await probe.finish(wasCancelled: false)
            }
        }

        let writerDescriptor = try await openFIFOWhenReaderIsReady(archive)
        loadTask.cancel()
        let completedPromptly = await waitForCompletion(probe, timeoutNanoseconds: 500_000_000)

        _ = Darwin.close(writerDescriptor)
        let eventuallyCompleted: Bool
        if completedPromptly {
            eventuallyCompleted = true
        } else {
            eventuallyCompleted = await waitForCompletion(
                probe,
                timeoutNanoseconds: 2_000_000_000
            )
        }
        observer.cancel()

        XCTAssertTrue(eventuallyCompleted, "The blocked archive process did not exit after its FIFO closed.")
        XCTAssertTrue(
            completedPromptly,
            "Cancelling ArchiveBook.load must terminate a blocked bsdtar subprocess promptly."
        )
        let completion = await probe.snapshot()
        XCTAssertTrue(completion.wasCancelled, "A cancelled archive load must throw CancellationError.")
        XCTAssertEqual(temporaryExtractionDirectories(), extractionDirectoriesBefore)
    }

    // Helpers build actual filesystem states while keeping ownership local to
    // each test. Defer/teardown cleanup also runs when an assertion throws.

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComicBookReaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeFile(_ relativePath: String, in directory: URL, contents: Data = Data()) throws {
        let file = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file)
    }

    private func relativePaths(of pages: [URL], under directory: URL) -> [String] {
        let baseComponents = directory.resolvingSymlinksInPath().pathComponents
        return pages.map {
            $0.resolvingSymlinksInPath().pathComponents
                .dropFirst(baseComponents.count)
                .joined(separator: "/")
        }
    }

    private func temporaryExtractionDirectories() -> Set<String> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicBookReader", isDirectory: true)
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
        return Set(contents.map(\.lastPathComponent))
    }

    private func openFIFOWhenReaderIsReady(_ fifo: URL) async throws -> Int32 {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let descriptor = fifo.path.withCString {
                Darwin.open($0, O_WRONLY | O_NONBLOCK)
            }
            if descriptor >= 0 {
                return descriptor
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ArchiveTestError.fifoReaderDidNotStart
    }

    private func waitForCompletion(
        _ probe: ArchiveLoadCompletionProbe,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let state = await probe.snapshot()
            if state.didComplete {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let state = await probe.snapshot()
        return state.didComplete
    }
}

private actor ArchiveLoadCompletionProbe {
    // A race-free rendezvous between the detached load and timeout observer;
    // fixed sleeps would make this cancellation test needlessly flaky.
    private var didComplete = false
    private var wasCancelled = false

    func finish(wasCancelled: Bool) {
        self.wasCancelled = wasCancelled
        didComplete = true
    }

    func snapshot() -> (didComplete: Bool, wasCancelled: Bool) {
        (didComplete, wasCancelled)
    }
}

private enum ArchiveTestError: Error {
    case fifoReaderDidNotStart
}
