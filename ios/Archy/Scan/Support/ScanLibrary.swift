import Foundation
import Observation
import os

/// One scan on disk, as the Scan intro lists it: a finished model, or photos still to process.
struct SavedScan: Identifiable {
    let folder: ScanFolder
    let date: Date
    /// How many photos a scan without a model has, so it can be processed; nil once it has a model.
    let unprocessedPhotos: Int?
    /// Nil until measured, or when the model file couldn't be read.
    var summary: ScanSummary?
    var id: String { folder.root.lastPathComponent }
}

/// What the list shows beyond the date. Cached as `summary.json` in the scan folder so each scan is measured once.
/// Both values are nil when the arch couldn't be measured.
struct ScanSummary: Codable {
    /// Bump when the analyzer's results change, so cached summaries are measured again.
    static let currentVersion = 2

    let version: Int
    var lengthMM: Double?
    var isFlat: Bool?

    init(_ arch: Result<FootArchAnalysis, any Error>) {
        let arch = try? arch.get()
        version = Self.currentVersion
        lengthMM = arch.map { $0.footLengthCM * 10 }
        isFlat = arch.map { $0.archType == .flat }
    }
}

extension ScanFolder {
    fileprivate var summaryURL: URL { root.appending(path: "summary.json") }
}

/// A scan loaded for the viewer: its mesh and the arch read from it, or why the arch couldn't be measured.
struct OpenedScan {
    let folder: ScanFolder
    let mesh: FootMesh
    let arch: Result<FootArchAnalysis, any Error>
}

/// The scans under `Documents/Scans` that have a model or enough photos to process, plus opening,
/// importing and deleting them.
@MainActor @Observable
final class ScanLibrary {
    private(set) var scans: [SavedScan] = []

    enum ImportError: LocalizedError {
        case unsupported
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose an STL or USDZ file."
            case .unreadable: "Couldn't read that file as a foot scan. archy opens binary STL and USDZ."
            }
        }
    }

    /// Lists scans newest first right away, then fills in each model's length and arch (cached after the first time).
    func reload() async {
        let roots = (try? FileManager.default.contentsOfDirectory(at: ScanFolder.scansRoot, includingPropertiesForKeys: nil)) ?? []
        scans = roots.map(ScanFolder.init).compactMap { folder in
            if folder.hasModel {
                return SavedScan(folder: folder, date: folder.date, unprocessedPhotos: nil, summary: Self.cachedSummary(for: folder))
            }
            let photos = folder.imageCount()
            guard photos >= ScanFlowModel.minimumShots else { return nil }
            return SavedScan(folder: folder, date: folder.date, unprocessedPhotos: photos)
        }.sorted { $0.date > $1.date }

        for scan in scans where scan.summary == nil && scan.unprocessedPhotos == nil {
            let folder = scan.folder
            // Off the main actor: reading and measuring a full scan takes a second or more.
            let arch = await Task.detached(priority: .userInitiated) { () -> Result<FootArchAnalysis, any Error>? in
                guard let mesh = try? folder.loadMesh() else { return nil }
                return Result { try FootArchAnalyzer.analyze(mesh) }
            }.value
            guard let arch else { continue }
            let summary = ScanSummary(arch)
            Self.cache(summary, for: scan.folder)
            if let index = scans.firstIndex(where: { $0.id == scan.id }) { scans[index].summary = summary }
        }
    }

    /// Reads a saved scan for the viewer.
    func open(_ folder: ScanFolder) throws -> OpenedScan {
        let mesh = try folder.loadMesh()
        return OpenedScan(folder: folder, mesh: mesh, arch: Result { try FootArchAnalyzer.analyze(mesh) })
    }

    /// Copies an STL or USDZ the user picked into a new scan folder, so it joins the list, and opens it.
    /// Works with a security-scoped URL from the file picker or a plain file path.
    func importScan(from url: URL) throws -> OpenedScan {
        let ext = url.pathExtension.lowercased()
        guard ["stl", "usdz"].contains(ext) else { throw ImportError.unsupported }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let folder = try ScanFolder.createNew(captureFolders: false)
        do {
            try FileManager.default.copyItem(at: url, to: ext == "stl" ? folder.stlURL : folder.modelURL)
            let opened = try open(folder)
            let summary = ScanSummary(opened.arch)
            Self.cache(summary, for: folder)
            scans.insert(SavedScan(folder: folder, date: folder.date, unprocessedPhotos: nil, summary: summary), at: 0)
            Log.files.notice("Imported \(url.lastPathComponent, privacy: .public) as \(folder.root.lastPathComponent, privacy: .public)")
            return opened
        } catch {
            folder.delete()
            Log.files.error("Import of \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error is FootMesh.LoadError ? ImportError.unreadable : error
        }
    }

    func delete(_ scan: SavedScan) {
        scan.folder.delete()
        scans.removeAll { $0.id == scan.id }
    }

    /// The cached summary, unless it's missing or from an older analyzer.
    private static func cachedSummary(for folder: ScanFolder) -> ScanSummary? {
        (try? Data(contentsOf: folder.summaryURL))
            .flatMap { try? JSONDecoder().decode(ScanSummary.self, from: $0) }
            .flatMap { $0.version == ScanSummary.currentVersion ? $0 : nil }
    }

    private static func cache(_ summary: ScanSummary, for folder: ScanFolder) {
        try? JSONEncoder().encode(summary).write(to: folder.summaryURL, options: .atomic)
    }
}
