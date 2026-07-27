import Darwin
import Foundation

/*
 An ArchiveBook is deliberately a small value-shaped owner around a potentially
 large on-disk working set.

 Directory books borrow their pages from the user and therefore own no
 temporary storage.  Archive books, by contrast, own one uniquely named
 extraction directory for exactly as long as the ArchiveBook lives.  Keeping
 that ownership here gives us a useful invariant:

     extractedDirectory != nil  ⇔  this object must eventually remove it

 The three stored properties never change, so it is safe to pass the book
 between the detached loader and the main-actor reader.  URL and Array are
 Sendable value types; no mutable FileManager or Process crosses that boundary.
 */
final class ArchiveBook: Sendable {
    let source: URL
    let pages: [URL]
    let extractedDirectory: URL?

    init(source: URL, pages: [URL], extractedDirectory: URL?) {
        self.source = source
        self.pages = pages
        self.extractedDirectory = extractedDirectory
    }

    // This is the ordinary success-path cleanup.  Explicit cleanup is also
    // available because a caller may wish to move the filesystem work off the
    // main actor rather than wait for ARC to choose the releasing thread.
    deinit { removeTemporaryFiles() }

    /*
     This list is intentionally an extension gate, not a second archive parser.
     Once admitted, every format goes through the system bsdtar.  That keeps
     format support broad while adding no decompressor libraries to xsComic's
     executable.  Extraction and page discovery validate the container; the
     image decoder remains the final authority on each page's readability.
     */
    static let supportedArchiveExtensions = [
        "cb7", "cbr", "cbt", "cbz", "7z", "rar", "tar", "zip",
    ]

    // Asking the directory enumerator for exactly this key lets Foundation
    // batch the metadata lookup.  We still require regular files: a symlink,
    // device, or directory named "page.jpg" must not become a page.
    private static let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]

    // MARK: - Opening a volume

    /*
     Loading is synchronous by design and is called from a detached task.
     Making this routine async would not make bsdtar or FileManager asynchronous;
     it would merely spread the ownership and rollback rules across suspension
     points.  Cancellation is cooperative at the expensive boundaries below.

     We fully extract an archive once rather than seeking into it on every page
     turn.  This spends temporary disk space and a little up-front time, but it
     makes all later access ordinary random-access file I/O—important for the
     bounded look-ahead cache—and avoids retaining an archive library or
     decompression state in the process.
     */
    static func load(from source: URL) throws -> ArchiveBook {
        try Task.checkCancellation()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ArchiveError.missingFile
        }

        // A directory already is an extracted book.  Never copy it into our
        // temporary tree; borrowing its URLs is both faster and ownership-safe.
        if isDirectory.boolValue {
            let pages = try findPages(in: source)
            guard !pages.isEmpty else { throw ArchiveError.noImages }
            return ArchiveBook(source: source, pages: pages, extractedDirectory: nil)
        }

        guard supportedArchiveExtensions.contains(source.pathExtension.lowercased()) else {
            throw ArchiveError.unsupportedFormat(source.pathExtension)
        }

        // Each load gets a private directory.  Concurrent opens cannot collide,
        // and failure cleanup can remove the whole subtree with one operation.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicBookReader", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try extract(source, to: destination)
            try Task.checkCancellation()
            let pages = try findPages(in: destination)
            guard !pages.isEmpty else { throw ArchiveError.noImages }
            return ArchiveBook(source: source, pages: pages, extractedDirectory: destination)
        } catch {
            // Before ArchiveBook exists there is no owner to run deinit, so this
            // scope rolls back every failure after directory creation succeeds.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Moving between sibling volumes

    /*
     "Next volume" means the next plausible sibling in Finder-like natural
     order, not the next bytewise filename.  We do this directory scan only
     when the reader crosses a volume boundary; maintaining a live directory
     index would cost state, invalidation machinery, and resident memory for an
     operation users perform comparatively rarely.

     Candidate discovery is cheap (directory-or-supported-extension).  The
     possibly recursive readability check is deferred until we walk away from
     the current item, and stops at the first image it finds.
     */
    static func adjacentVolume(to source: URL, forward: Bool) -> URL? {
        let source = source.standardizedFileURL
        guard
            var volumes = try? FileManager.default.contentsOfDirectory(
                at: source.deletingLastPathComponent(),
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        else {
            return nil
        }

        // Retain the full path as a deterministic tie-breaker.  Two names that
        // compare equally under localized natural ordering must not make volume
        // traversal depend on FileManager's unspecified enumeration order.
        volumes.removeAll { !isPotentialVolume($0) }
        volumes.sort {
            naturallyPrecedes(
                ($0.lastPathComponent, $0.path),
                ($1.lastPathComponent, $1.path)
            )
        }

        guard
            let current = volumes.firstIndex(where: {
                $0.standardizedFileURL == source
            })
        else {
            return nil
        }

        let offset = forward ? 1 : -1
        var adjacent = current + offset
        while volumes.indices.contains(adjacent) {
            let candidate = volumes[adjacent]
            if isReadableVolume(candidate) {
                return candidate
            }
            adjacent += offset
        }
        return nil
    }

    /*
     Cleanup is intentionally idempotent and best-effort.  A caller may remove
     the directory eagerly and deinit may then try again; a failed removal is
     not actionable to the reader and must never turn object destruction into
     user-visible control flow.
     */
    func removeTemporaryFiles() {
        guard let extractedDirectory else { return }
        try? FileManager.default.removeItem(at: extractedDirectory)
    }

    // MARK: - Extraction

    /*
     The platform's /usr/bin/bsdtar is a compact dependency in the literal
     sense: it costs this application no distributed bytes.  A subprocess also
     contains malformed-archive handling outside xsComic's address space.

     stderr goes to a temporary file rather than a Pipe.  A pipe must be drained
     concurrently or a verbose child can fill its kernel buffer and deadlock;
     the file has no such producer/consumer coupling.  We read at most 64 KiB
     after failure, so a hostile archive cannot make its diagnostic consume
     unbounded application memory.
     */
    private static func extract(_ source: URL, to destination: URL) throws {
        let process = Process()
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicBookReader-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw ArchiveError.couldNotLaunch("Could not create an error log.")
        }
        let errorHandle: FileHandle
        do {
            errorHandle = try FileHandle(forUpdating: errorURL)
        } catch {
            try? FileManager.default.removeItem(at: errorURL)
            throw ArchiveError.couldNotLaunch(error.localizedDescription)
        }
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-x", "-f", source.path, "-C", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle

        // Process.run can fail before a child exists (missing executable,
        // permissions, resource exhaustion); keep that distinct from a child
        // that ran and rejected the archive.
        do {
            try process.run()
        } catch {
            throw ArchiveError.couldNotLaunch(error.localizedDescription)
        }

        /*
         Process.waitUntilExit alone is not cancellation-aware.  A short 5 ms
         poll is used here because this whole routine already runs off-main.  It
         directly expresses a bounded wait without the registration, callback,
         and teardown state of a readability source for one subprocess.

         terminate() gives bsdtar roughly 100 ms to unwind.  SIGKILL is the
         bounded fallback for a child blocked on input or decompression.  The
         final wait reaps the process before the extraction directory can be
         removed, avoiding both zombies and a child writing into deleted state.
         */
        var wasCancelled = false
        while process.isRunning {
            if Task.isCancelled {
                wasCancelled = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if wasCancelled {
            for _ in 0..<20 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        try? errorHandle.synchronize()

        if wasCancelled || Task.isCancelled {
            throw CancellationError()
        }

        guard process.terminationStatus == 0 else {
            let maximumErrorBytes = 64 * 1_024
            try? errorHandle.seek(toOffset: 0)
            let errorData = (try? errorHandle.read(upToCount: maximumErrorBytes)) ?? Data()
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.extractionFailed(message.isEmpty ? "The archive could not be read." : message)
        }
    }

    // MARK: - Page discovery

    /*
     A single recursive scan builds the immutable page table.  We do not probe
     image headers here: extension filtering is dramatically cheaper for a
     large book, while the decoder remains the authority when a page is shown.
     Hidden files and package descendants are skipped because they are normally
     metadata or applications, not intentional comic content.

     Cost is O(items + pages log pages).  The scan stores each relative sort key
     once so the comparison phase does not repeatedly reconstruct it.
     */
    private static func findPages(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            throw ArchiveError.cannotReadDirectory
        }

        let directoryPathLength = directory.path.count
        var pages = [(url: URL, sortKey: String)]()
        var itemCount = 0

        while let url = enumerator.nextObject() as? URL {
            itemCount &+= 1
            // Checking every filesystem entry adds cancellation bookkeeping to
            // the hot scan; checking every 256 bounds latency while amortizing
            // that overhead.  Extraction itself has the tighter 5 ms poll above.
            if itemCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }

            guard isImageExtension(url.pathExtension.lowercased()),
                (try? url.resourceValues(forKeys: resourceKeys).isRegularFile) == true
            else {
                continue
            }

            pages.append(
                (
                    url: url,
                    sortKey: String(url.path.dropFirst(directoryPathLength))
                ))
        }

        // A cancellation after enumeration should not enter an O(n log n) sort,
        // and one during the non-suspending sort is observed before returning.
        try Task.checkCancellation()
        pages.sort {
            naturallyPrecedes(($0.sortKey, $0.sortKey), ($1.sortKey, $1.sortKey))
        }
        try Task.checkCancellation()
        return pages.map(\.url)
    }

    // MARK: - Lightweight classification and ordering

    /*
     This deliberately answers "might be a volume?", not "can be opened?".
     Archives are validated only if selected; recursively inspecting every
     neighboring archive would turn boundary navigation into bulk extraction.
     */
    private static func isPotentialVolume(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
            || supportedArchiveExtensions.contains(url.pathExtension.lowercased())
    }

    /*
     Archive candidates have already passed the suffix gate and are cheap to
     accept.  A directory needs one image somewhere below it, but packages are
     opaque by convention.  The enumerator exits on the first match, making the
     usual case proportional to the distance to the first page rather than the
     size of the whole neighboring volume.
     */
    private static func isReadableVolume(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else { return true }
        guard (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true else {
            return false
        }

        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return false
        }
        while let page = enumerator.nextObject() as? URL {
            if isImageExtension(page.pathExtension.lowercased()),
                (try? page.resourceValues(forKeys: resourceKeys).isRegularFile) == true
            {
                return true
            }
        }
        return false
    }

    /*
     localizedStandardCompare supplies the "2 before 10" ordering readers
     expect.  Its equivalence relation is broader than String equality, so the
     stable key gives every pair a total, reproducible order.
     */
    private static func naturallyPrecedes(
        _ lhs: (natural: String, stable: String),
        _ rhs: (natural: String, stable: String)
    ) -> Bool {
        let order = lhs.natural.localizedStandardCompare(rhs.natural)
        return order == .orderedSame
            ? lhs.stable < rhs.stable
            : order == .orderedAscending
    }

    /*
     This allow-list describes formats that macOS ImageIO/AppKit may decode; it
     is not a promise that every file with such a suffix is valid.  Keeping the
     test as a switch avoids UTType registration lookups while scanning and
     makes the supported surface obvious to a source reader.
     */
    private static func isImageExtension(_ ext: String) -> Bool {
        switch ext {
        case "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            return true
        default:
            return false
        }
    }
}

/*
 Errors are kept at the archive boundary and translated once into concise
 reader-facing prose.  Cancellation intentionally is not represented here:
 CancellationError must retain its identity so a superseded open remains
 silent rather than looking like a broken book.
 */
enum ArchiveError: LocalizedError {
    case missingFile
    case unsupportedFormat(String)
    case cannotReadDirectory
    case noImages
    case couldNotLaunch(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFile: return "The selected file no longer exists."
        case .unsupportedFormat(let ext): return "Unsupported archive format: .\(ext)"
        case .cannotReadDirectory: return "The selected directory could not be read."
        case .noImages: return "No readable images were found in this book."
        case .couldNotLaunch(let message): return "The archive tool could not start: \(message)"
        case .extractionFailed(let message): return "The archive could not be opened: \(message)"
        }
    }
}
