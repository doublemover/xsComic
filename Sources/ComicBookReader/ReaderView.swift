import AppKit
import SwiftUI

/*
 ReaderView is the stable desktop scaffold around the mutable reading session.
 ReaderModel owns books, page position, direction, zoom, and image work. This
 view owns only one ephemeral presentation choice: whether its sidebar is open.

 Keeping that line sharp gives the event flow a useful, short shape:

     toolbar / sidebar / menu command
                  ↓
              ReaderModel
                  ↓  Observation invalidates only readers of changed state
       toolbar status and PageCanvas

 There is no view model layered over the reader and no navigation framework
 between an input and its operation. That economy serves readability, launch
 time, and executable size at once.
 */
struct ReaderView: View {
    @Bindable var reader: ReaderModel
    let continueAcrossVolumes: Bool

    // Sidebar visibility belongs to this window session. Persisting it as an
    // application preference would couple otherwise independent presentations.
    @State private var showsSidebar = false

    private var bookTitle: String {
        reader.book?.source.deletingPathExtension().lastPathComponent
            ?? "xsComic"
    }

    private var errorBinding: Binding<Bool> {
        /*
         ReaderModel sensibly stores an optional diagnostic, not an "alert is
         open" flag. This adapter lets dismissal consume that diagnostic while
         preserving the model's more useful representation.
         */
        Binding(
            get: { reader.errorMessage != nil },
            set: { if !$0 { reader.errorMessage = nil } }
        )
    }

    var body: some View {
        // The HStack is always the root. Opening the sidebar inserts one local
        // child instead of replacing the entire reader hierarchy, so canvas
        // tasks and toolbar identity remain stable.
        HStack(spacing: 0) {
            if showsSidebar {
                PageSidebar(reader: reader)
                Divider()
            }
            readerContent
        }
    }

    // Loading, empty, and reading are mutually exclusive contents of the same
    // layout cell. Window chrome and command ownership do not move among them.
    private var readerContent: some View {
        Group {
            if reader.isLoading {
                ProgressView("Opening book…")
            } else if reader.pages.isEmpty {
                emptyState
            } else {
                PageCanvas(reader: reader)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(bookTitle)
        .toolbar { toolbar }
        .alert("Couldn’t Open Book", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reader.errorMessage ?? "Unknown error")
        }
    }

    // The empty state asks ReaderModel to open its small native NSOpenPanel.
    // No document browser or file-import subsystem is kept alive while reading.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Comic Open", systemImage: "books.vertical")
        } description: {
            Text("Open a CBZ, CBR, ZIP, RAR, 7z, or a folder of images.")
        } actions: {
            Button("Open Comic…") { reader.chooseBook() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Navigation controls stay together so their visual order remains
        // independent of the logical LTR/RTL direction. Only the glyph and
        // ReaderModel's key mapping change.
        ToolbarItemGroup(placement: .navigation) {
            Button {
                showsSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle page sidebar")

            Button {
                reader.goBackward(continueAcrossVolumes: continueAcrossVolumes)
            } label: {
                Image(systemName: reader.direction == .leftToRight ? "chevron.left" : "chevron.right")
            }
            .disabled(!reader.canTurnBackward(acrossVolumes: continueAcrossVolumes))
            .help("Previous page")

            PageIndicator(reader: reader)
                .frame(minWidth: 72)

            Button {
                reader.goForward(continueAcrossVolumes: continueAcrossVolumes)
            } label: {
                Image(systemName: reader.direction == .leftToRight ? "chevron.right" : "chevron.left")
            }
            .disabled(!reader.canTurnForward(acrossVolumes: continueAcrossVolumes))
            .help("Next page")
        }

        // Reading policy and zoom are direct bindings to the model: there is
        // one source of truth, and no on-change synchronization code to execute
        // or debug.
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Direction", selection: $reader.direction) {
                ForEach(ReadingDirection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 92)

            Picker("Pages", selection: $reader.pageMode) {
                Image(systemName: "rectangle").tag(PageMode.single)
                Image(systemName: "rectangle.split.2x1").tag(PageMode.double)
            }
            .pickerStyle(.segmented)
            .frame(width: 82)

            ZoomControl(zoom: $reader.zoom)
        }
    }
}

/*
 The sidebar is intentionally an index, not a thumbnail browser. Page numbers
 answer the navigation question without causing image decoding, cache pressure,
 filesystem reads, or hundreds of retained NSImages. `LazyVStack` constructs
 rows only as they approach the viewport; when the sidebar is closed, the whole
 subtree is absent.
 */
private struct PageSidebar: View {
    let reader: ReaderModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(reader.pages.indices, id: \.self) { index in
                    Button {
                        reader.jump(toPage: index + 1)
                    } label: {
                        HStack {
                            Text("Page \(index + 1)").monospacedDigit()
                            Spacer()
                        }
                        .padding(4)
                        .background(
                            isVisible(index)
                                ? Color.accentColor.opacity(0.2)
                                : .clear
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .frame(width: 150)
        .background(.regularMaterial)
    }

    private func isVisible(_ index: Int) -> Bool {
        // In double-page mode both leaves in the spread are selected. This is
        // an index interval, not an array search, so even very long volumes
        // retain constant-time row rendering.
        index >= reader.currentIndex
            && index < reader.currentIndex + reader.step
    }
}

/*
 PageIndicator serves two entry routes with one editor:

   • a double-click begins editing locally;
   • Cmd-Shift-G increments ReaderModel.pageJumpRequest, which this view observes.

 An incrementing token is preferable to a Bool: two successive menu commands are
 two distinct events even if no other state changed between them. Focus remains
 view state because keyboard focus is presentation, not reader data.
 */
private struct PageIndicator: View {
    let reader: ReaderModel
    @State private var isEditing = false
    @State private var pageText = ""
    @FocusState private var fieldHasFocus: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Page", text: $pageText)
                    .focused($fieldHasFocus)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                    .onAppear { fieldHasFocus = true }
            } else {
                Text(reader.status)
                    .monospacedDigit()
                    .onTapGesture(count: 2) { beginEditing() }
            }
        }
        .onChange(of: reader.pageJumpRequest) { beginEditing() }

        // A page number from the former book must never be submitted into the
        // new one. Object identity is a cheap, unambiguous generation marker.
        .onChange(of: reader.bookIdentity) { isEditing = false }
    }

    private func beginEditing() {
        guard !reader.pages.isEmpty else { return }
        pageText = String(reader.currentIndex + 1)
        isEditing = true
    }

    private func commit() {
        // Reject rather than clamp invalid input: silently changing "999" to a
        // volume's last page would conceal the error and make jumps surprising.
        guard let page = Int(pageText.trimmingCharacters(in: .whitespaces)),
            reader.jump(toPage: page)
        else {
            NSSound.beep()
            return
        }
        isEditing = false
    }
}

/*
 ZoomControl is a projection of ZoomMode, not another owner of zoom state.
 Translating the enum to a percentage Binding lets the native Slider write
 directly back to ReaderModel while retaining the semantically distinct `.fit`
 case. The menu itself is built on demand and adds no persistent controller.
 */
private struct ZoomControl: View {
    @Binding var zoom: ZoomMode

    private var label: String {
        switch zoom {
        case .fit: return "Fit"
        case .custom(1): return "1:1"
        case .custom(let scale): return "\(Int((scale * 100).rounded()))%"
        }
    }

    private var percentBinding: Binding<Double> {
        Binding(
            get: { Double(zoom.scale ?? 1) * 100 },
            set: { zoom = .custom(CGFloat($0 / 100)) }
        )
    }

    var body: some View {
        Menu {
            Button("Fit to Window") { zoom = .fit }
            Button("Actual Size") { zoom = .custom(1) }
            Divider()
            HStack {
                Text("10%")
                Slider(value: percentBinding, in: 10...800)
                    .frame(width: 180)
                Text("800%")
            }
            Button("100%") { zoom = .custom(1) }
            Button("200%") { zoom = .custom(2) }
        } label: {
            Text(label)
                .monospacedDigit()
                .frame(minWidth: 50)
        }
        .help("Zoom")
    }
}
