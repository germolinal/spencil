import Foundation

public enum ViewMode: String, Codable, CaseIterable, Sendable {
    /// Live camera with the image warped onto the paper.
    case camera
    /// Paper flattened to a straight-on view.
    case flat
}

/// One drawing in progress: the reference image, where it sits on the paper,
/// and enough about the paper to pick up where you left off.
public struct Session: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var paper: PaperSize
    public var imageFileName: String
    /// Reference image height / width.
    public var imageAspect: Double
    public var placement: Placement
    public var pinned: Bool
    public var opacity: Double
    public var lineArt: Bool
    public var viewMode: ViewMode
    /// Quarter turns (clockwise) for the flat view.
    public var flatRotation: Int
    /// Last known look of the paper, for re-orienting on resume.
    public var snapshot: [UInt8]?

    public init(id: UUID = UUID(), name: String, paper: PaperSize, imageFileName: String, imageAspect: Double) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.paper = paper
        self.imageFileName = imageFileName
        self.imageAspect = imageAspect
        self.placement = .fitted(paper: paper, imageAspect: imageAspect)
        self.pinned = false
        self.opacity = 0.5
        self.lineArt = false
        self.viewMode = .camera
        self.flatRotation = 0
        self.snapshot = nil
    }
}

/// Stores each session as a folder: `<root>/<id>/session.json` + the reference image.
public final class SessionStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Spencil/Sessions", isDirectory: true)
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func imageURL(for s: Session) -> URL { folder(s.id).appendingPathComponent(s.imageFileName) }

    public func loadAll() -> [Session] {
        let dec = JSONDecoder()
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
            return try? dec.decode(Session.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func create(name: String, paper: PaperSize, imageData: Data, imageAspect: Double) throws -> Session {
        let s = Session(name: name, paper: paper, imageFileName: "reference", imageAspect: imageAspect)
        try fm.createDirectory(at: folder(s.id), withIntermediateDirectories: true)
        try imageData.write(to: imageURL(for: s), options: .atomic)
        try save(s)
        return s
    }

    public func save(_ s: Session) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fm.createDirectory(at: folder(s.id), withIntermediateDirectories: true)
        try enc.encode(s).write(to: folder(s.id).appendingPathComponent("session.json"), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        try fm.removeItem(at: folder(id))
    }
}
