import AppKit

/// Programmatic fixtures keep the repository small and make dimensions visible
/// at every call site. They exercise the same platform encoders and decoders as
/// the app rather than quietly introducing a second image implementation.
enum PageImageTestFixture {
    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComicBookReaderImageTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makePNG(width: Int, height: Int) throws -> (directory: URL, file: URL) {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("page.png")
        do {
            try writePNG(at: file, width: width, height: height)
            return (directory, file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func makeGIF(width: Int, height: Int) throws -> (directory: URL, file: URL) {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("page.gif")
        do {
            try writeBitmap(at: file, width: width, height: height, type: .gif)
            return (directory, file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func writePNG(at file: URL, width: Int, height: Int) throws {
        try writeBitmap(at: file, width: width, height: height, type: .png)
    }

    /// Fill a deterministic, non-uniform RGBA field. A solid image could let a
    /// decoder that returned one repeated pixel pass unnoticed.
    private static func writeBitmap(
        at file: URL,
        width: Int,
        height: Int,
        type: NSBitmapImageRep.FileType
    ) throws {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            ), let pixels = bitmap.bitmapData
        else {
            throw FixtureError.couldNotCreateBitmap
        }

        for y in 0..<height {
            let row = pixels.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8(truncatingIfNeeded: x)
                row[offset + 1] = UInt8(truncatingIfNeeded: y)
                row[offset + 2] = UInt8(truncatingIfNeeded: x &+ y)
                row[offset + 3] = 255
            }
        }

        guard let data = bitmap.representation(using: type, properties: [:]) else {
            throw FixtureError.couldNotEncodePNG
        }
        try data.write(to: file, options: .atomic)
    }

    enum FixtureError: Error {
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }
}

enum ZIPTestFixture {
    /// Tests use the copy of `bsdtar` shipped with macOS, just like production.
    /// No archive library enters either target's dependency graph.
    static func create(at archive: URL, from directory: URL) throws {
        try ArchiveTestFixture.create(at: archive, from: directory, format: "zip")
    }
}

enum ArchiveTestFixture {
    static func create(
        at archive: URL,
        from directory: URL,
        format: String,
        members: [String] = ["."]
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments =
            [
                "--format", format, "-c", "-f", archive.path,
                "-C", directory.path,
            ] + members
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ArchiveTestFixture",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)
                ]
            )
        }
    }
}
