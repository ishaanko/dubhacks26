import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

/// Scan tab entry point. Rests on the intro; Start opens the camera as a full-screen cover, and
/// processing, the viewer and failures swap in over the tab as the scan phase advances.
/// DEBUG routes (`-ArchyRoute`): scan.intro, scan.previous, scan.sample, scan.tips, scan.reconstructing.preview,
/// scan.failed.preview, scan.capture.preview, scan.capture.lap.preview. `-ArchyImportScan <path to .stl or .usdz>`
/// imports that file and opens it, skipping the picker.
struct ScanTab: View {
    @Environment(ScanFlowModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var library = ScanLibrary()
    @State private var sample: SampleScan?
    /// A saved or imported scan open in the viewer.
    @State private var opened: OpenedScan?
    /// Why a sample, saved or imported scan couldn't be shown.
    @State private var openError: String?
    @State private var showingTips = false
    @State private var showingImporter = false
    #if DEBUG
    @State private var preview: DebugPreview?
    #endif

    /// Which screen the tab shows. Changing it plays the step transition.
    private enum Screen: Hashable {
        case intro, reconstructing, viewing, failed, sample, saved
    }

    private var screen: Screen {
        #if DEBUG
        if let preview { return preview.screen }
        #endif
        if sample != nil { return .sample }
        if opened != nil { return .saved }
        if openError != nil { return .failed }
        switch model.phase {
        case .reconstructing: return .reconstructing
        case .viewing: return model.folder == nil ? .intro : .viewing
        case .failed: return .failed
        case .ready, .detecting, .capturing, .finishing: return .intro
        }
    }

    /// The screen stays awake while the camera runs and while the model builds.
    private var keepsScreenAwake: Bool {
        model.session != nil || model.phase == .reconstructing
    }

    var body: some View {
        ZStack {
            content
                .transition(.step)
                .id(screen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .archyScreen()
        .animation(Motion.smooth.reduced(reduceMotion), value: screen)
        .fullScreenCover(item: cover) { cover in
            switch cover {
            case .camera:
                if let session = model.session { CaptureView(session: session) }
            #if DEBUG
            case .debugCapture(let isLapComplete):
                CapturePreview(isLapComplete: isLapComplete)
            #endif
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.importTypes) { result in
            switch result {
            case .success(let url): importScan(from: url)
            case .failure(let error): openError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingTips) {
            ScanTipsSheet { showingTips = false }
        }
        .task(id: screen == .intro) {
            if screen == .intro { await library.reload() }
        }
        .onChange(of: keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onChange(of: scenePhase) { _, newPhase in
            // iOS may suspend processing in the background; this shows up in the logs if it happens.
            Log.flow.notice("App scene phase \(String(describing: newPhase), privacy: .public) during \(String(describing: model.phase), privacy: .public)")
        }
        #if DEBUG
        .task { openDebugRoute() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .intro:
            ScanIntroView(isSupported: model.isSupported,
                          previous: library.scans,
                          onStart: { model.begin() },
                          onSample: openSample,
                          onTips: { showingTips = true },
                          onImport: { showingImporter = true },
                          onOpen: openSaved,
                          onProcess: { model.process($0.folder) },
                          onDelete: library.delete,
                          startsAtEnd: router.debugRoute == "scan.previous")
        case .reconstructing:
            reconstruction
        case .viewing:
            if let folder = model.folder {
                ModelViewerView(source: .scan(folder, size: model.modelSize, arch: model.arch), onClose: { model.reset() })
            }
        case .failed:
            failure
        case .sample:
            if let sample {
                ModelViewerView(source: .sample(sample), onClose: { self.sample = nil })
            }
        case .saved:
            if let opened {
                ModelViewerView(source: .saved(opened), onClose: { self.opened = nil })
            }
        }
    }

    @ViewBuilder
    private var reconstruction: some View {
        if let reconstructor = model.reconstructor {
            ReconstructionView(reconstructor: reconstructor)
        } else {
            #if DEBUG
            if preview == .reconstructing {
                ReconstructionProgressView(fraction: 0.62, stage: "Building mesh…", remaining: 95,
                                           photos: 148, onCancel: {})
            } else { savingModel }
            #else
            savingModel
            #endif
        }
    }

    /// Between the last progress update and the viewer: the model is being saved.
    private var savingModel: some View {
        ReconstructionProgressView(fraction: 1, stage: "Saving model", remaining: nil,
                                   photos: model.folder?.imageCount() ?? 0, onCancel: {})
    }

    @ViewBuilder
    private var failure: some View {
        if let openError {
            ScanFailedView(message: openError, canRetry: false, dismissTitle: "Back",
                           onRetry: {}, onNewScan: { self.openError = nil })
        } else {
            ScanFailedView(message: failureMessage, canRetry: model.canRetryProcessing,
                           onRetry: { model.retryProcessing() }, onNewScan: { model.reset() })
        }
    }

    private var failureMessage: String {
        if case .failed(let message) = model.phase { return message }
        #if DEBUG
        return ScanFolder.storageMessage()
        #else
        return ""
        #endif
    }

    // MARK: - Camera cover

    private enum Cover: Identifiable {
        case camera
        #if DEBUG
        case debugCapture(isLapComplete: Bool)
        #endif

        var id: String {
            switch self {
            case .camera: "camera"
            #if DEBUG
            case .debugCapture(let isLapComplete): isLapComplete ? "debug-lap" : "debug-capture"
            #endif
            }
        }
    }

    /// The camera is up exactly while a capture session exists; it goes away on its own when capture
    /// ends, is cancelled or fails.
    private var cover: Binding<Cover?> {
        Binding {
            if model.session != nil { return .camera }
            #if DEBUG
            if case .capture(let isLapComplete) = preview { return .debugCapture(isLapComplete: isLapComplete) }
            #endif
            return nil
        } set: { _ in
            #if DEBUG
            preview = nil
            #endif
        }
    }

    // MARK: - Sample

    /// Reads the bundled STL and shows it in the viewer.
    private func openSample() {
        do {
            sample = try SampleScan.load()
        } catch {
            Log.viewer.error("Sample scan failed: \(String(describing: error), privacy: .public)")
            openError = error.localizedDescription
        }
    }

    // MARK: - Saved and imported scans

    /// STL and USDZ, the two formats the viewer reads.
    private static let importTypes = [UTType(filenameExtension: "stl"), UTType.usdz].compactMap { $0 }

    private func openSaved(_ scan: SavedScan) {
        do {
            opened = try library.open(scan.folder)
        } catch {
            Log.viewer.error("Couldn't open \(scan.id, privacy: .public): \(String(describing: error), privacy: .public)")
            openError = "Couldn't open this scan. Its files may be damaged."
        }
    }

    private func importScan(from url: URL) {
        do {
            opened = try library.importScan(from: url)
        } catch {
            openError = error.localizedDescription
        }
    }

    #if DEBUG
    /// Static screens that need no camera or photogrammetry, for screenshots.
    private enum DebugPreview: Equatable {
        case reconstructing, failed
        case capture(isLapComplete: Bool)

        var screen: Screen {
            switch self {
            case .reconstructing: .reconstructing
            case .failed: .failed
            case .capture: .intro
            }
        }
    }

    private func openDebugRoute() {
        if let path = UserDefaults.standard.string(forKey: "ArchyImportScan") {
            importScan(from: URL(filePath: path))
            return
        }
        switch router.debugRoute {
        case "scan.sample": openSample()
        case "scan.tips": showingTips = true
        case "scan.reconstructing.preview": preview = .reconstructing
        case "scan.failed.preview": preview = .failed
        case "scan.capture.preview": preview = .capture(isLapComplete: false)
        case "scan.capture.lap.preview": preview = .capture(isLapComplete: true)
        default: break
        }
    }
    #endif
}
