import CoreImage
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One entry in the LUT library. Built-ins have no file on disk; imported
/// LUTs store `fileName` inside `Documents/LUTs/`.
struct LUTItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var fileName: String?
    var builtInKey: String?
    var isFavorite: Bool = false

    var isBuiltIn: Bool { builtInKey != nil }
}

/// Owns the LUT library: built-ins + user imports, persistence (files in the
/// Documents directory + a small JSON index), selection, thumbnails and a
/// cache of ready-to-render `LUTProcessor`s.
@MainActor
final class LUTManager: ObservableObject {
    @Published private(set) var items: [LUTItem] = []
    @Published var selectedID: UUID?
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published var lastImportError: String?

    private var processorCache: [UUID: LUTProcessor] = [:]
    private let selectionKey = "lumaraw.selectedLUTID"

    static var lutDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(AppConstants.lutDirectoryName, isDirectory: true)
    }
    private var indexURL: URL { Self.lutDirectory.appendingPathComponent("index.json") }

    init() {
        try? FileManager.default.createDirectory(at: Self.lutDirectory, withIntermediateDirectories: true)
        items = Self.seedItems()
        loadIndex()
        if let saved = UserDefaults.standard.string(forKey: selectionKey),
           let uuid = UUID(uuidString: saved),
           items.contains(where: { $0.id == uuid }) {
            selectedID = uuid
        }
        rebuildThumbnails()
    }

    // MARK: - Built-ins & seeding

    private static func seedItems() -> [LUTItem] {
        // Deterministic IDs so the saved selection/order survive updates.
        BuiltInLUTs.definitions.enumerated().map { index, def in
            let suffix = String(format: "%012d", index + 1)
            let uuid = UUID(uuidString: "00000000-0000-4000-8000-\(suffix)") ?? UUID()
            return LUTItem(id: uuid, name: def.name, fileName: nil, builtInKey: def.key)
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([LUTItem].self, from: data) else { return }
        // Merge: keep saved order/metadata, drop imports whose file is gone,
        // append any built-ins the saved index predates.
        var merged: [LUTItem] = []
        for item in saved {
            if let fileName = item.fileName {
                let path = Self.lutDirectory.appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: path) { merged.append(item) }
            } else {
                merged.append(item)
            }
        }
        for seed in items where !merged.contains(where: { $0.id == seed.id }) {
            merged.append(seed)
        }
        items = merged
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: - Selection & processors

    var selectedItem: LUTItem? { items.first { $0.id == selectedID } }

    func select(_ id: UUID?) {
        selectedID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectionKey)
        }
    }

    /// The processor for the currently selected LUT (nil = no LUT).
    var currentProcessor: LUTProcessor? {
        guard let id = selectedID else { return nil }
        return processor(for: id)
    }

    func processor(for id: UUID) -> LUTProcessor? {
        if let cached = processorCache[id] { return cached }
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let parsed: ParsedLUT?
        if let key = item.builtInKey, let def = BuiltInLUTs.definition(forKey: key) {
            parsed = BuiltInLUTs.makeLUT(for: def)
        } else if let fileName = item.fileName {
            let url = Self.lutDirectory.appendingPathComponent(fileName)
            parsed = (try? Data(contentsOf: url)).flatMap { try? LUTParser.parse(data: $0) }
        } else {
            parsed = nil
        }
        guard let parsed else { return nil }
        let processor = LUTProcessor(parsed: parsed)
        processorCache[id] = processor
        return processor
    }

    // MARK: - Import

    /// Imports a `.cube` from the Files app / share sheet / "Open in…".
    /// The file is parsed first — malformed files are rejected with a clear
    /// error (`lastImportError`) and never reach the library.
    func importLUT(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try LUTParser.parse(data: data)
            let fileName = UUID().uuidString + ".cube"
            try data.write(to: Self.lutDirectory.appendingPathComponent(fileName), options: .atomic)
            let fallbackName = url.deletingPathExtension().lastPathComponent
            let item = LUTItem(id: UUID(),
                               name: parsed.title?.isEmpty == false ? parsed.title! : fallbackName,
                               fileName: fileName,
                               builtInKey: nil)
            items.append(item)
            saveIndex()
            rebuildThumbnail(for: item)
            select(item.id)
        } catch {
            lastImportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func importFromURL(_ url: URL) { importLUT(from: url) }

    // MARK: - Library editing

    func rename(_ id: UUID, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[i].name = trimmed
        saveIndex()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), let fileName = items[i].fileName else { return }
        try? FileManager.default.removeItem(at: Self.lutDirectory.appendingPathComponent(fileName))
        items.remove(at: i)
        processorCache[id] = nil
        thumbnails[id] = nil
        if selectedID == id { select(nil) }
        saveIndex()
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isFavorite.toggle()
        saveIndex()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
        saveIndex()
    }

    // MARK: - Thumbnails

    /// The shared sample image every LUT thumbnail is rendered from:
    /// generated programmatically (gray ramp, color patches, hue sweep) so
    /// no image assets are needed.
    static func makeSampleImage() -> CIImage? {
        let width = 480, height = 300
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top band: grayscale ramp.
        for x in 0..<width {
            let v = CGFloat(x) / CGFloat(width - 1)
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 200, width: 1, height: 100))
        }
        // Middle band: color patches incl. two skin tones.
        let patches: [(CGFloat, CGFloat, CGFloat)] = [
            (0.9, 0.15, 0.15), (0.15, 0.8, 0.2), (0.15, 0.3, 0.95), (0.1, 0.8, 0.85),
            (0.9, 0.2, 0.8), (0.95, 0.85, 0.15), (0.87, 0.66, 0.52), (0.58, 0.4, 0.3)
        ]
        let patchW = width / patches.count
        for (i, p) in patches.enumerated() {
            ctx.setFillColor(CGColor(red: p.0, green: p.1, blue: p.2, alpha: 1))
            ctx.fill(CGRect(x: i * patchW, y: 100, width: patchW, height: 100))
        }
        // Bottom band: hue sweep at mid brightness.
        for x in 0..<width {
            let hue = CGFloat(x) / CGFloat(width)
            let color = UIColor(hue: hue, saturation: 0.75, brightness: 0.8, alpha: 1)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 100))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    private func rebuildThumbnails() {
        for item in items { rebuildThumbnail(for: item) }
    }

    private func rebuildThumbnail(for item: LUTItem) {
        guard let sample = Self.makeSampleImage(),
              let processor = processor(for: item.id) else { return }
        let graded = processor.apply(to: sample)
        // Downscale to thumbnail width before rendering.
        let scale = 192.0 / graded.extent.width
        let small = graded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cg = ImageEngine.renderContext.createCGImage(small, from: small.extent) {
            thumbnails[item.id] = UIImage(cgImage: cg)
        }
    }
}
