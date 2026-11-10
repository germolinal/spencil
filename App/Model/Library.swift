import Foundation
import Observation
import SpencilCore

/// All saved drawing sessions.
@Observable
@MainActor
final class Library {
    let store: SessionStore
    private(set) var sessions: [Session] = []

    init(store: SessionStore = SessionStore(root: SessionStore.defaultRoot())) {
        self.store = store
        reload()
    }

    func reload() { sessions = store.loadAll() }

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    func create(name: String, paper: PaperSize, imageData: Data, imageAspect: Double) throws -> Session {
        let s = try store.create(name: name, paper: paper, imageData: imageData, imageAspect: imageAspect)
        sessions.insert(s, at: 0)
        return s
    }

    func save(_ s: Session) {
        var s = s
        s.updatedAt = Date()
        try? store.save(s)
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
    }

    func delete(_ id: UUID) {
        try? store.delete(id)
        sessions.removeAll { $0.id == id }
    }

    func imageURL(for s: Session) -> URL { store.imageURL(for: s) }
}
