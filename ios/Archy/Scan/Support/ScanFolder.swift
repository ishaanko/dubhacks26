//
//  ScanFolder.swift
//  archy
//

import Foundation
import os

/// On-disk layout for one scan: `Documents/Scans/<timestamp>/{Images/, Checkpoint/, foot.usdz, foot.stl}`.
/// Images are kept after reconstruction so the scan can be reprocessed on a Mac. The checkpoint
/// (the biggest part, 300–650 MB) only helps while the scan's flow runs, so it's deleted once the
/// model is built or the flow ends.
nonisolated struct ScanFolder {
    let root: URL

    var images: URL { root.appending(path: "Images", directoryHint: .isDirectory) }
    var checkpoint: URL { root.appending(path: "Checkpoint", directoryHint: .isDirectory) }
    var modelURL: URL { root.appending(path: "foot.usdz") }
    var stlURL: URL { root.appending(path: "foot.stl") }
    /// Zip of `Images/` for sharing. Lives in the temporary folder, which iOS clears on its own,
    /// so it doesn't double each scan's size on disk.
    var imagesZipURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "\(root.lastPathComponent)-Images.zip")
    }

    static var scansRoot: URL {
        URL.documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory)
    }

    /// ObjectCaptureSession refuses to start with less free space than this.
    static let requiredFreeBytes: Int64 = 4_000_000_000

    /// Creates a new scan folder named after the current time (no colons, so AirDrop/Finder friendly).
    /// `captureFolders: false` makes a bare folder for an imported file, which has no photos.
    static func createNew(captureFolders: Bool = true) throws -> ScanFolder {
        var root = scansRoot.appending(path: nameFormatter.string(from: .now), directoryHint: .isDirectory)
        // Two imports in the same second must not share a folder.
        var suffix = 2
        while FileManager.default.fileExists(atPath: root.path) {
            root = scansRoot.appending(path: "\(nameFormatter.string(from: .now))-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        let folder = ScanFolder(root: root)
        do {
            let directories = captureFolders ? [folder.images, folder.checkpoint] : [folder.root]
            for directory in directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            Log.files.error("Couldn't create scan folder \(folder.root.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        Log.files.notice("Created scan folder \(folder.root.path, privacy: .public)")
        return folder
    }

    private static var nameFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }

    /// When the scan was made: the time in its folder name, or the folder's creation date for odd names.
    var date: Date {
        let name = String(root.lastPathComponent.prefix(19))
        if let parsed = Self.nameFormatter.date(from: name) { return parsed }
        return (try? root.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// A finished scan has a model file: `foot.usdz` from the camera, or the `foot.stl` of an import.
    var hasModel: Bool {
        [modelURL, stlURL].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Reads whichever model file the folder has. The reconstructed USDZ wins; an imported STL is read as is.
    func loadMesh() throws -> FootMesh {
        FileManager.default.fileExists(atPath: modelURL.path)
            ? try FootMesh.load(from: modelURL)
            : try FootMesh.loadSTL(from: stlURL)
    }

    /// Number of captured HEIC images in `Images/`.
    func imageCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "heic" }.count
    }

    /// Removes `foot.usdz`, `foot.stl` and the shared zip from an earlier attempt so reprocessing starts
    /// clean, and recreates `Checkpoint/` for photogrammetry if it was removed while the photos waited.
    func prepareForProcessing() {
        for url in [modelURL, stlURL, imagesZipURL] {
            Self.remove(url)
        }
        try? FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
    }

    /// Frees the checkpoint once the model has been built.
    func removeCheckpoint() {
        let freed = Self.remove(checkpoint)
        Log.files.notice("Removed checkpoint, freed \(Self.formatted(freed), privacy: .public)")
    }

    func delete() {
        Self.remove(root)
    }

    /// For a scan nothing can resume any more: drops the checkpoint, or the whole folder when it has
    /// neither a model nor enough photos to build one. Returns how many bytes that freed.
    @discardableResult
    func tidyUp() -> Int64 {
        if !hasModel && imageCount() < ScanFlowModel.minimumShots {
            return Self.remove(root)
        }
        return Self.remove(checkpoint)
    }

    // MARK: - Storage

    /// Free space iOS will make available for app data, or nil if it won't say.
    static func freeBytes() -> Int64? {
        try? URL.documentsDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func storageMessage(requiredBytes: Int64 = requiredFreeBytes) -> String {
        let free = freeBytes().map { ", this iPhone has \(formatted($0))" } ?? ""
        return "Not enough space. archy needs about \(formatted(requiredBytes)) free\(free). "
            + "Delete old scans in Files › archy › Scans, or free up space in Settings."
    }

    nonisolated static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// File size in MB for logging, or 0 if the file is missing.
    static func sizeInMB(of url: URL) -> Double {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Double(bytes) / 1_000_000
    }

    /// Run once at launch, before any scan folder of this launch exists, so no flow can resume anything.
    /// Tidies every folder (see `tidyUp`) and removes zips that older builds kept inside scan folders.
    /// Models and photos enough to process stay.
    static func cleanUp() {
        let fileManager = FileManager.default
        let scans = (try? fileManager.contentsOfDirectory(at: scansRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var freed: Int64 = 0
        for root in scans where isDirectory(root) {
            freed += ScanFolder(root: root).tidyUp()
            freed += remove(root.appending(path: "Images.zip"))
        }
        let free = freeBytes().map(formatted) ?? "unknown"
        Log.files.notice("Cleanup: freed \(formatted(freed), privacy: .public). Free space: \(free, privacy: .public)")
    }

    /// Deletes a file or folder if it exists and returns how many bytes that freed.
    @discardableResult
    private static func remove(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let size = allocatedSize(of: url)
        do {
            try FileManager.default.removeItem(at: url)
            Log.files.notice("Deleted \(url.path, privacy: .public) (\(formatted(size), privacy: .public))")
            return size
        } catch {
            Log.files.error("Couldn't delete \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        guard isDirectory(url) else {
            return Int64((try? url.resourceValues(forKeys: [key]).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key])
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [key]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
