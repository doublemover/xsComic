// swift-tools-version: 6.0

import PackageDescription

// The package graph is deliberately boring.
//
// xsComic is one executable, one test target, and no external package graph.
// That is not merely aesthetic minimalism: every outside dependency would
// enlarge the trust surface, prolong cold builds, and make the final binary's
// provenance harder for a reader to establish. AppKit, SwiftUI, ImageIO, and
// command-line tools already shipped with macOS provide everything it needs.
let package = Package(
    name: "ComicBookReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ComicBookReader", targets: ["ComicBookReader"])
    ],
    targets: [
        .executableTarget(
            name: "ComicBookReader",
            path: "Sources/ComicBookReader",
            swiftSettings: [
                // `-Osize` asks LLVM to prefer compact code when speed and size
                // are otherwise comparable.  This is a declared distribution
                // policy: page turns are dominated by image decoding and archive
                // I/O, while Metrics/ records the resulting artifact and timings.
                .unsafeFlags(["-Osize"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "ComicBookReaderTests",
            dependencies: ["ComicBookReader"],
            path: "Tests/ComicBookReaderTests"
        ),
    ],
    // Swift 5 language mode is an explicit source-compatibility policy while
    // the current Swift 6 toolchain compiles and packages the application.
    swiftLanguageModes: [.v5]
)
