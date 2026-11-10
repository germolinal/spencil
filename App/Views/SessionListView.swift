import SpencilCore
import SwiftUI

struct SessionListView: View {
    @Environment(Library.self) private var library
    @State private var path: [UUID] = []
    @State private var showingNew = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No drawings yet", systemImage: "pencil.and.scribble")
                    } description: {
                        Text("Pick a reference image, put your paper under the camera, and trace.")
                    } actions: {
                        Button("New Drawing") { showingNew = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(library.sessions) { s in
                            NavigationLink(value: s.id) { SessionRow(session: s) }
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { library.delete(s.id) }
                                }
                        }
                        .onDelete { idx in idx.map { library.sessions[$0].id }.forEach(library.delete) }
                    }
                }
            }
            .navigationTitle("Spencil")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNew = true } label: { Label("New Drawing", systemImage: "plus") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let s = library.session(id) {
                    DrawingView(session: s, library: library)
                }
            }
            .sheet(isPresented: $showingNew) {
                NewSessionView { s in path.append(s.id) }
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(Library.self) private var library
    let session: Session
    @State private var thumb: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb {
                    Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.headline)
                Text("\(session.paper.name) · \(session.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(.vertical, 2)
        .task(id: session.id) {
            let url = library.imageURL(for: session)
            thumb = await Task.detached { ImageLoader.cgImage(url: url, maxPixel: 200) }.value
        }
    }
}
