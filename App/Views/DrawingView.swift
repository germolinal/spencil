import SpencilCore
import SwiftUI

struct DrawingView: View {
    @State private var model: DrawingModel
    @Environment(\.scenePhase) private var scenePhase

    init(session: Session, library: Library) {
        _model = State(initialValue: DrawingModel(session: session, library: library))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalView(model: model)
                .ignoresSafeArea()
                .gesture(drag)
                .simultaneousGesture(magnify)
                .simultaneousGesture(rotate)
                .onTapGesture(count: 2) { model.resetZoom() }

            VStack(spacing: 10) {
                StatusPill(model: model)
                if let toast = model.toast {
                    Text(toast).font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .transition(.opacity)
                }
                if let err = model.cameraError {
                    Text(err).font(.callout).multilineTextAlignment(.center).padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                ControlPanel(model: model)
            }
            .padding()
            .animation(.default, value: model.toast)
        }
        .navigationTitle(model.session.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar { toolbar }
        .task { await model.start() }
        .onAppear { setIdleTimer(disabled: true) }
        .onDisappear {
            model.stop()
            setIdleTimer(disabled: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.rotatePaper() } label: {
                Label("Rotate paper", systemImage: "rotate.right")
            }
            .help("The sheet is upside down? Tap to flip which way is up.")
            Menu {
                Picker("View", selection: Binding(get: { model.session.viewMode }, set: model.setViewMode)) {
                    Label("Camera", systemImage: "camera").tag(ViewMode.camera)
                    Label("Flat paper", systemImage: "doc").tag(ViewMode.flat)
                }
                if model.session.viewMode == .flat {
                    Button("Turn flat view 90°", systemImage: "rotate.right") { model.rotateFlatView() }
                }
                if model.cameraOptions.count > 1 {
                    Picker("Camera", selection: Binding(get: { model.selectedCamera }, set: model.selectCamera)) {
                        ForEach(model.cameraOptions) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            } label: {
                Label("View options", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { model.dragChanged(start: $0.startLocation, location: $0.location) }
            .onEnded { _ in model.dragEnded() }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { model.magnifyChanged($0.magnification, anchor: $0.startLocation) }
            .onEnded { _ in model.magnifyEnded() }
    }

    private var rotate: some Gesture {
        RotateGesture()
            .onChanged { model.rotateChanged($0.rotation.degrees) }
            .onEnded { _ in model.rotateEnded() }
    }

    private func setIdleTimer(disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

private struct StatusPill: View {
    let model: DrawingModel

    var body: some View {
        let (text, color): (String, Color) = switch model.status {
        case .searching: ("Looking for the paper…", .orange)
        case .tracking: (model.session.pinned ? "Pinned" : "Paper found: place your image", .green)
        case .holding: ("Paper hidden: holding position", .yellow)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct ControlPanel: View {
    let model: DrawingModel

    var body: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: Binding(get: { model.session.pinned }, set: model.setPinned)) {
                Label("Place", systemImage: "hand.draw").tag(false)
                Label("Draw", systemImage: "pin.fill").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.session.opacity }, set: { model.session.opacity = $0 }), in: 0.05...1)
                Button {
                    model.overlayVisible.toggle()
                } label: {
                    Image(systemName: model.overlayVisible ? "eye" : "eye.slash")
                        .frame(width: 28)
                }
                .help("Hide the image to check your drawing")
            }

            HStack {
                Toggle(isOn: Binding(get: { model.session.lineArt }, set: model.setLineArt)) {
                    Label("Lines", systemImage: "scribble")
                }
                .toggleStyle(.button)

                Spacer()

                if model.session.pinned {
                    Button { model.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { model.resetZoom() } label: { Text(String(format: "%.1f×", model.zoom)).monospacedDigit() }
                    Button { model.zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                } else {
                    Button("Fit to paper", systemImage: "arrow.up.left.and.arrow.down.right") { model.fitImageToPaper() }
                }
            }
            .buttonStyle(.bordered)

            if !model.session.pinned {
                Text("Drag, pinch and twist to put the image where you want it on the paper, then switch to Draw.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
