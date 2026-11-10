import SwiftUI

@main
struct SpencilApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environment(library)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 860)
        #endif
    }
}
