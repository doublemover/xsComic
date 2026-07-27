import AppKit
import SwiftUI

/*
 The executable deliberately begins and ends with Apple's native UI frameworks.
 There is no custom application delegate, dependency container, third-party
 settings layer, or command router to initialize. Besides keeping the
 distributed image small, that choice leaves launch mostly to AppKit: establish
 the process, restore one window, and construct this short scene graph.

 The scene/model boundary is equally deliberate. `ComicBookReaderApp` owns the
 one long-lived `ReaderModel`; views merely observe it. Durable preferences
 remain here, where commands and settings can share them without teaching the
 reading model about UserDefaults or presentation policy.
 */
@main
struct ComicBookReaderApp: App {
    // `@State` gives this @Observable reference a stable owner for the scene's
    // lifetime. Recomputing `body` therefore never creates a second reader,
    // cancels its in-flight work, or throws away its decoded-page cache.
    @State private var reader = ReaderModel()

    // These are true application preferences, rather than transient window
    // state, so the tiny system-provided `@AppStorage` bridge is the whole
    // persistence layer. The defaults also document the out-of-box policy.
    @AppStorage("swapRTLPageTurnKeys") private var swapRTLPageTurnKeys = false
    @AppStorage("continueAcrossVolumes") private var continueAcrossVolumes = true
    @AppStorage("useAlternateIcon") private var useAlternateIcon = false

    var body: some Scene {
        // A named `Window` expresses the product's single-reader architecture.
        // Its root layout remains ReaderView for every loading and reading
        // state; only local content changes, which keeps scene identity stable.
        Window("xsComic", id: "reader") {
            ReaderView(
                reader: reader,
                continueAcrossVolumes: continueAcrossVolumes
            )
            .frame(minWidth: 640, minHeight: 480)

            // Files opened through Finder follow the same model entry point as
            // the Open panel. This keeps archive loading and cancellation in
            // one place rather than duplicating it in scene plumbing.
            .onOpenURL { reader.open($0) }

            // SwiftUI has no API for the process's Dock icon. Keep that AppKit
            // escape hatch at this scene edge. The bundle already installs the
            // primary icon, so an ordinary launch performs no redundant decode.
            .onAppear {
                if useAlternateIcon { applyIcon() }
            }
            .onChange(of: useAlternateIcon) { applyIcon() }
        }
        .commands {
            // "New" has no useful meaning for a reader. Replacing it with Open
            // also avoids manufacturing empty document/window machinery.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { reader.chooseBook() }
                    .keyboardShortcut("o")
            }

            // Menu items are alternate inputs, not alternate implementations.
            // Each ends at the same ReaderModel operation used by the toolbar;
            // direction, bounds, prefetch bias, and cross-volume behavior can
            // therefore be reasoned about independently of the invoking UI.
            CommandMenu("Reading") {
                Button("Left") { turnPage(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Right") { turnPage(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Toggle Reading Direction") { reader.toggleDirection() }
                    .keyboardShortcut("d")
                Button("Toggle Page Mode") { reader.togglePageMode() }
                    .keyboardShortcut("p")

                // The request is an event token observed by PageIndicator.
                // Keeping field focus in the view, rather than the model, is a
                // small but important separation of domain and presentation.
                Button("Jump to Page…") { reader.requestPageJump() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(reader.pages.isEmpty)
                Button("Zoom to Window") { reader.zoom = .fit }
                    .keyboardShortcut("0")
                Button("Actual Size") { reader.zoom = .custom(1) }
                    .keyboardShortcut("1")
                Button("Zoom In") { reader.adjustZoom(by: 1.25) }
                    .keyboardShortcut("+")
                Button("Zoom Out") { reader.adjustZoom(by: 0.8) }
                    .keyboardShortcut("-")
            }
        }

        // Three scalar preferences do not justify a settings coordinator or
        // another observable object. The system owns this Settings scene's
        // lifecycle, leaving no preferences controller resident in our model.
        Settings {
            Form {
                Toggle("Swap left and right page-turn keys in RTL mode", isOn: $swapRTLPageTurnKeys)
                Toggle("Continue into adjacent volumes", isOn: $continueAcrossVolumes)
                Toggle("Use alternate app icon", isOn: $useAlternateIcon)
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 430)
        }
    }

    private func turnPage(_ key: PageTurnKey) {
        // Physical arrow keys acquire their semantic meaning here because the
        // mapping depends on both a durable preference and live reading
        // direction. ReaderModel still owns the resulting navigation.
        reader.turnPage(
            for: key,
            swapRTLPageTurnKeys: swapRTLPageTurnKeys,
            continueAcrossVolumes: continueAcrossVolumes
        )
    }

    private func applyIcon() {
        /*
         The bundle icon remains the canonical Finder identity; this assignment
         changes the running process's Dock/app-switcher image. The alternate
         SVG is consequently decoded only when selected. On an ordinary launch
         the bundle supplies the primary icon without entering this method.

         `applicationIconImage` treats an override as finished artwork: unlike
         an app-icon asset, it receives no system mask. Rather than approximate
         a radius that can change with macOS, we clip the alternate with the
         alpha of AppKit's current primary icon. A 256-point temporary raster is
         ample for the Dock and app switcher and bounds the selected-only cost.
         Clearing the override on the return trip is equally important; loading
         the raw ICNS here would bypass the modern catalog and its native plate.

         Failure is intentionally quiet. If a hand-built or test bundle omits
         an asset, AppKit's existing application icon is the correct fallback.
         */
        guard useAlternateIcon else {
            NSApplication.shared.applicationIconImage = nil
            return
        }
        let application = NSApplication.shared
        guard let nativeIcon = application.applicationIconImage,
            let url = Bundle.main.url(forResource: "AppIcon-Azusa", withExtension: "svg"),
            let artwork = NSImage(contentsOf: url)
        else { return }

        let icon = NSImage(size: NSSize(width: 256, height: 256))
        let bounds = NSRect(origin: .zero, size: icon.size)
        icon.lockFocus()
        artwork.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        nativeIcon.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
        icon.unlockFocus()
        application.applicationIconImage = icon
    }
}
