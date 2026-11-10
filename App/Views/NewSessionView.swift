import PhotosUI
import SpencilCore
import SwiftUI
import UniformTypeIdentifiers

struct NewSessionView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let onCreate: (Session) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var preview: CGImage?
    @State private var importing = false
    @State private var paper = PaperSize.a4
    @State private var custom = false
    @State private var customShort = 200.0
    @State private var customLong = 300.0
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reference image") {
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                    }
                    PhotosPicker(preview == nil ? "Choose from Photos" : "Choose another photo",
                                 selection: $pickerItem, matching: .images)
                    Button("Choose a file…") { importing = true }
                }
                Section {
                    Toggle("Custom size", isOn: $custom)
                    if custom {
                        LabeledContent("Width (mm)") {
                            TextField("Width", value: $customShort, format: .number).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Height (mm)") {
                            TextField("Height", value: $customLong, format: .number).multilineTextAlignment(.trailing)
                        }
                    } else {
                        Picker("Size", selection: $paper) {
                            ForEach(PaperSize.presets) { Text($0.label).tag($0) }
                        }
                    }
                } header: {
                    Text("Paper")
                } footer: {
                    Text("Put the sheet on a surface that contrasts with it (e.g. white paper on a dark mat) and keep the whole sheet in view.")
                }
                Section("Name") {
                    TextField("My drawing", text: $name)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Drawing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).disabled(imageData == nil)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                guard case let .success(url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                setImage(try? Data(contentsOf: url), suggestedName: url.deletingPathExtension().lastPathComponent)
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { setImage(try? await item.loadTransferable(type: Data.self), suggestedName: nil) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private func setImage(_ data: Data?, suggestedName: String?) {
        guard let data, let cg = ImageLoader.cgImage(data: data, maxPixel: 800) else {
            error = "Couldn't read that image."
            return
        }
        error = nil
        imageData = data
        preview = cg
        if name.isEmpty, let suggestedName { name = suggestedName }
    }

    private func create() {
        guard let imageData, let preview else { return }
        let size = custom
            ? PaperSize(name: "Custom", shortMM: max(20, customShort), longMM: max(20, customLong))
            : paper
        let aspect = Double(preview.height) / Double(preview.width)
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name
        do {
            let s = try library.create(name: finalName, paper: size, imageData: imageData, imageAspect: aspect)
            dismiss()
            onCreate(s)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
