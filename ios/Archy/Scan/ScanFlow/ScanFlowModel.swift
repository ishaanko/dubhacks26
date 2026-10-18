//
//  ScanFlowModel.swift
//  archy
//

import Foundation
import Observation
import RealityKit
import SwiftUI  // ObjectCaptureSession lives in RealityKit's SwiftUI overlay.
import os

/// Owns the scan state machine, the current scan folder and the `ObjectCaptureSession`.
/// Views read `phase` and call the action methods; nothing else changes the phase.
@MainActor
@Observable
final class ScanFlowModel {
    private(set) var phase: ScanPhase = .ready {
        didSet {
            guard phase != oldValue else { return }
            Log.flow.notice("Phase \(String(describing: oldValue), privacy: .public) → \(String(describing: self.phase), privacy: .public)")
        }
    }

    /// The live capture session; nil once capture is over (and on devices that can't capture).
    private(set) var session: ObjectCaptureSession?
    /// The scan being captured, or the one just captured.
    private(set) var folder: ScanFolder?

    /// `startDetecting()` couldn't find an object under the dot.
    private(set) var detectionFailed = false
    /// The user just completed a scan pass; the UI offers Another Pass / Finish.
    private(set) var isPassComplete = false
    private(set) var passNumber = 1
    /// When the last photo was taken (or capture last resumed); drives the "keep moving" nudge.
    private(set) var lastPhotoDate = Date.now

    /// The "How to scan" sheet is up over the paused camera (the "?" button).
    private(set) var isShowingTips = false

    /// The running reconstruction, for the progress screen.
    private(set) var reconstructor: Reconstructor?
    /// Bounding-box size of the finished model in meters (width, height, depth).
    private(set) var modelSize: SIMD3<Float>?
    /// Flat vs. normal arch for the finished model, or why it couldn't be measured; nil until measured.
    private(set) var arch: Result<FootArchAnalysis, any Error>?
    /// The last failure happened while processing saved photos, so they can be processed again.
    private(set) var canRetryProcessing = false

    /// The session needs at least this many images to finish (same as Apple's sample).
    nonisolated static let minimumShots = 10

    let isSupported = ObjectCaptureSession.isSupported
    /// "Too bright" check for the capture screens.
    let brightness = BrightnessMonitor()

    private var sessionTasks: [Task<Void, Never>] = []
    /// Startup cleanup of `Documents/Scans` has run in this app launch.
    private static var hasCleanedUp = false

    init() {
        Log.flow.notice("Scanner launched. ObjectCaptureSession.isSupported = \(self.isSupported)")
        // Once per app launch, before any scan folder of this launch exists.
        if !Self.hasCleanedUp {
            Self.hasCleanedUp = true
            ScanFolder.cleanUp()
        }
        #if DEBUG
        openScanFromLaunchArgument()
        #endif
    }

    #if DEBUG
    /// Debug builds only: launching with `-ArchyOpenScan <scan folder name>` opens that saved scan in the
    /// viewer without scanning. This is how the viewer gets checked in the Simulator.
    private func openScanFromLaunchArgument() {
        guard let name = UserDefaults.standard.string(forKey: "ArchyOpenScan") else { return }
        let folder = ScanFolder(root: ScanFolder.scansRoot.appending(path: name, directoryHint: .isDirectory))
        do {
            let mesh = try FootMesh.load(from: folder.modelURL)
            modelSize = mesh.size
            arch = Self.analyzeArch(mesh)
            self.folder = folder
            phase = .viewing
            Log.flow.notice("Opened saved scan \(name, privacy: .public) from launch argument")
        } catch {
            Log.flow.error("Couldn't open saved scan \(name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
    #endif

    // MARK: - Actions

    /// Starts a new scan: checks free space, then starts the camera. The intro screen has already
    /// covered the tips. Does nothing while a scan is under way, so repeated calls are harmless.
    func begin() {
        guard isSupported else {
            Log.capture.error("Not starting a session: this device doesn't support Object Capture")
            return
        }
        guard session == nil, phase == .ready, !isShowingTips else { return }

        // Before creating a folder: the session fails right away below 4 GB free.
        let freeBytes = ScanFolder.freeBytes()
        Log.files.notice("Free space: \(freeBytes.map(ScanFolder.formatted) ?? "unknown", privacy: .public)")
        if let freeBytes, freeBytes < ScanFolder.requiredFreeBytes {
            fail(ScanFolder.storageMessage())
            return
        }

        startCaptureSession()
    }

    /// Creates a fresh scan folder and capture session.
    private func startCaptureSession() {
        guard session == nil, phase == .ready else { return }

        let folder: ScanFolder
        do {
            folder = try ScanFolder.createNew()
        } catch {
            fail("Couldn't create the scan folder: \(error.localizedDescription)")
            return
        }

        let session = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = folder.checkpoint
        // Takes extra shots the iPhone doesn't use, for a higher-detail reprocess on a Mac.
        configuration.isOverCaptureEnabled = true
        session.start(imagesDirectory: folder.images, configuration: configuration)

        self.folder = folder
        self.session = session
        Log.capture.notice("Session started. Images → \(folder.images.path, privacy: .public)")

        if case .failed(let error) = session.state {
            sessionFailed(error)
            return
        }
        observe(session)
    }

    func startDetecting() {
        guard let session else { return }
        detectionFailed = !session.startDetecting()
        if detectionFailed {
            Log.capture.notice("startDetecting: no object found under the dot")
        } else {
            Log.capture.notice("startDetecting: bounding box shown")
        }
    }

    func resetBox() {
        guard let session else { return }
        let didReset = session.resetDetection()
        Log.capture.notice("resetDetection → \(didReset)")
    }

    func startCapturing() {
        Log.capture.notice("startCapturing")
        session?.startCapturing()
    }

    func beginNewPass() {
        guard let session else { return }
        passNumber += 1
        isPassComplete = false
        lastPhotoDate = .now
        Log.capture.notice("Beginning scan pass \(self.passNumber)")
        // A foot can't be flipped, so the next pass keeps the same bounding box.
        session.beginNewScanPass()
        session.resume()
    }

    /// The "?" button. The camera stays on screen under the sheet, so the session is paused by hand
    /// (as Apple's sample does for its sheets). The capture overlay only offers "?" once the session is
    /// past `.initializing`: pausing a session that hasn't finished starting can leave the camera stuck.
    func showTips() {
        guard !isShowingTips else { return }
        isShowingTips = true
        session?.pause()
        Log.capture.notice("Tips sheet shown, session paused")
    }

    /// The sheet's binding setter. It only records the state; the work waits for `tipsDismissed()`.
    func setTipsPresented(_ presented: Bool) {
        isShowingTips = presented
    }

    /// Runs once the tips sheet has finished closing. Resumes the paused camera.
    func tipsDismissed() {
        isShowingTips = false
        guard let session else { return }
        lastPhotoDate = .now
        session.resume()
        Log.capture.notice("Tips sheet closed, session resumed")
    }

    func finish() {
        guard let session else { return }
        isPassComplete = false
        Log.capture.notice("finish requested with \(session.numberOfShotsTaken) shots")
        session.finish()
    }

    /// Abandons the current scan. The session reports `.failed(.cancelled)`, which deletes its folder.
    func cancel() {
        Log.capture.notice("cancel requested")
        session?.cancel()
    }

    /// Back to the idle state (the intro screen) from a result, a failure or a cancelled scan.
    /// The flow is over, so the scan is tidied (`ScanFolder.tidyUp`): its checkpoint goes, and photos
    /// enough to process stay under Previous scans as not processed.
    func reset() {
        Log.flow.notice("Reset")
        tearDownSession()
        reconstructor = nil
        modelSize = nil
        arch = nil
        canRetryProcessing = false
        folder?.tidyUp()
        folder = nil
        phase = .ready
    }

    func cancelReconstruction() {
        reconstructor?.cancel()
    }

    /// Processes the current scan's saved photos again after a failure or cancel.
    func retryProcessing() {
        Log.flow.notice("Retry processing")
        startReconstruction()
    }

    /// Builds the model for a saved scan whose photos were never processed (Previous scans).
    func process(_ folder: ScanFolder) {
        guard session == nil, phase == .ready else { return }
        Log.flow.notice("Processing saved scan \(folder.root.lastPathComponent, privacy: .public)")
        self.folder = folder
        startReconstruction()
    }

    // MARK: - Reconstruction

    private func startReconstruction() {
        // One reconstruction at a time: a double-tapped "Try again" must not start a second session on the same folder.
        guard let folder, reconstructor == nil else { return }
        folder.prepareForProcessing()
        canRetryProcessing = false
        modelSize = nil
        arch = nil
        let reconstructor = Reconstructor(folder: folder)
        self.reconstructor = reconstructor
        phase = .reconstructing
        // Owned by the model, not a view, so screen changes can't cancel it.
        Task {
            do {
                try await reconstructor.run()
                try await exportSTL(from: folder)
                folder.removeCheckpoint()
                self.reconstructor = nil
                phase = .viewing
            } catch is CancellationError {
                failProcessing("Processing was cancelled. Your photos are saved under Previous scans.")
            } catch {
                Log.reconstruction.error("Reconstruction failed: \(String(describing: error), privacy: .public)")
                failProcessing(describe(error, as: "Building the model failed"))
            }
        }
    }

    /// Reads the mesh back from `foot.usdz`, logs its size (a scale check), writes `foot.stl`, and measures the arch.
    /// The work runs off the main actor so the "Saving model" screen keeps drawing.
    private func exportSTL(from folder: ScanFolder) async throws {
        let (size, arch) = try await Task.detached(priority: .userInitiated) {
            let mesh = try FootMesh.load(from: folder.modelURL)
            let cm = mesh.size * 100
            Log.reconstruction.notice("Mesh: \(mesh.vertices.count) vertices, \(mesh.triangleCount) triangles, size \(cm.x, format: .fixed(precision: 1)) × \(cm.y, format: .fixed(precision: 1)) × \(cm.z, format: .fixed(precision: 1)) cm (x × y × z, y up)")
            try STLExporter.write(mesh, to: folder.stlURL)
            Log.files.notice("foot.stl written: \(ScanFolder.sizeInMB(of: folder.stlURL), format: .fixed(precision: 1)) MB at \(folder.stlURL.path, privacy: .public)")
            return (mesh.size, Self.analyzeArch(mesh))
        }.value
        modelSize = size
        self.arch = arch
    }

    /// A failed measurement doesn't fail the scan: the model and STL are still good, the viewer just says so.
    nonisolated private static func analyzeArch(_ mesh: FootMesh) -> Result<FootArchAnalysis, any Error> {
        let result = Result { try FootArchAnalyzer.analyze(mesh) }
        switch result {
        case .success(let arch):
            Log.analysis.notice("Arch height \(arch.archHeightMM, format: .fixed(precision: 1)) mm → \(arch.archType.rawValue, privacy: .public) (Arch Index \(arch.archIndex, format: .fixed(precision: 3))); sole tilt \(arch.soleTiltDegrees, format: .fixed(precision: 1))°\(arch.isSoleUneven ? " UNEVEN" : "", privacy: .public); foot \(arch.footLengthCM, format: .fixed(precision: 1)) × \(arch.footWidthCM, format: .fixed(precision: 1)) cm")
        case .failure(let error):
            Log.analysis.error("Arch analysis failed: \(String(describing: error), privacy: .public)")
        }
        return result
    }

    private func failProcessing(_ message: String) {
        reconstructor = nil
        canRetryProcessing = (folder?.imageCount() ?? 0) >= Self.minimumShots
        fail(message)
    }

    // MARK: - Session events

    private func observe(_ session: ObjectCaptureSession) {
        sessionTasks.append(Task { [weak self] in
            for await state in session.stateUpdates {
                self?.sessionStateChanged(state)
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await completed in session.userCompletedScanPassUpdates where completed {
                self?.scanPassCompleted()
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await count in session.numberOfShotsTakenUpdates {
                self?.lastPhotoDate = .now
                Log.capture.info("Photos taken: \(count)")
            }
        })
        sessionTasks.append(Task {
            for await feedback in session.feedbackUpdates {
                Log.capture.info("Feedback: \(String(describing: feedback), privacy: .public)")
            }
        })
        sessionTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.brightness.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        })
    }

    private func sessionStateChanged(_ state: ObjectCaptureSession.CaptureState) {
        Log.capture.notice("Session state: \(String(describing: state), privacy: .public)")
        switch state {
        case .initializing, .ready:
            phase = .ready
        case .detecting:
            phase = .detecting
        case .capturing:
            if phase != .capturing { lastPhotoDate = .now }
            phase = .capturing
        case .finishing:
            phase = .finishing
        case .completed:
            captureCompleted()
        case .failed(let error):
            sessionFailed(error)
        @unknown default:
            Log.capture.warning("Unknown session state: \(String(describing: state), privacy: .public)")
        }
    }

    private func scanPassCompleted() {
        guard let session else { return }
        Log.capture.notice("Scan pass \(self.passNumber) complete with \(session.numberOfShotsTaken) shots")
        // Stop taking shots while the prompt is up, like Apple's sample does under its sheets.
        session.pause()
        isPassComplete = true
    }

    private func captureCompleted() {
        guard let folder else { return }
        Log.capture.notice("Capture complete: \(folder.imageCount()) images in \(folder.images.path, privacy: .public)")
        // Release the capture session (camera, GPU memory) before reconstruction starts.
        tearDownSession()
        startReconstruction()
    }

    private func sessionFailed(_ error: Error) {
        if case ObjectCaptureSession.Error.cancelled = error {
            Log.capture.notice("Session cancelled; discarding this scan")
            folder?.delete()
            reset()
        } else {
            Log.capture.error("Session failed: \(String(describing: error), privacy: .public)")
            tearDownSession()
            // Enough photos to build a model from: offer that, as after a processing failure.
            // Otherwise `reset()` deletes the folder on the way out.
            let photos = folder?.imageCount() ?? 0
            canRetryProcessing = photos >= Self.minimumShots
            let reason = describe(error, as: "Capture failed")
            fail(canRetryProcessing ? "\(reason)\n\nTry again to build the model from the \(photos) photos taken." : reason)
        }
    }

    /// User-facing text for a framework error. Calls the concrete types' own descriptions, because
    /// `any Error` falls back to "The operation couldn't be completed (… error 1)".
    private func describe(_ error: Error, as context: String) -> String {
        if let captureError = error as? ObjectCaptureSession.Error {
            if case .insufficientStorage(let required) = captureError {
                return ScanFolder.storageMessage(requiredBytes: required)
            }
            return "\(context): \(captureError.localizedDescription)"
        }
        if let photogrammetryError = error as? PhotogrammetrySession.Error {
            if case .insufficientStorage(let required) = photogrammetryError {
                return ScanFolder.storageMessage(requiredBytes: required)
            }
            return "\(context): \(photogrammetryError.localizedDescription)"
        }
        return "\(context): \(error.localizedDescription)"
    }

    private func fail(_ message: String) {
        Log.flow.error("Failing: \(message, privacy: .public)")
        phase = .failed(message)
    }

    private func tearDownSession() {
        sessionTasks.forEach { $0.cancel() }
        sessionTasks.removeAll()
        brightness.reset()
        session = nil
        detectionFailed = false
        isPassComplete = false
        isShowingTips = false
        passNumber = 1
    }
}
