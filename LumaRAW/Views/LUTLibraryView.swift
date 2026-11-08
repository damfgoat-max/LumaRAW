import SwiftUI
import UniformTypeIdentifiers

/// LUT tab panel: current look, intensity, A/B compare, library access.
struct LUTPanel: View {
    @ObservedObject var viewModel: CameraViewModel
    @EnvironmentObject var lutManager: LUTManager
    var onOpenLibrary: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                if let item = lutManager.selectedItem {
                    if let thumb = lutManager.thumbnails[item.id] {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(item.name)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                } else {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(Theme.textDim)
                    Text("No LUT selected")
                        .font(.callout)
                        .foregroundColor(Theme.textDim)
                }
                Spacer()
                Button {
                    viewModel.compareOriginal.toggle()
                } label: {
                    Text("A/B")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(viewModel.compareOriginal ? Theme.accent : Theme.raised)
                        .foregroundColor(viewModel.compareOriginal ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    onOpenLibrary()
                } label: {
                    Text("Library")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.raised)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            ProSlider(title: "INTENSITY",
                      value: $viewModel.lutIntensity,
                      range: 0...1,
                      format: { "\(Int($0 * 100))%" },
                      disabled: lutManager.selectedItem == nil)
            Text(viewModel.compareOriginal
                 ? "Showing the ORIGINAL — tap A/B again for the LUT look"
                 : "The selected LUT is baked into saved photos per your save setting")
                .font(.caption2)
                .foregroundColor(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Full LUT library: pick, import, rename, delete, favorite, reorder.
/// Thumbnails show each LUT applied to the generated sample image.
struct LUTLibraryView: View {
    @EnvironmentObject var lutManager: LUTManager
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var renameTarget: LUTItem?
    @State private var renameText = ""
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        lutManager.select(nil)
                    } label: {
                        HStack {
                            Text("No LUT")
                                .foregroundColor(.white)
                            Spacer()
                            if lutManager.selectedID == nil {
                                Image(systemName: "checkmark").foregroundColor(Theme.accent)
                            }
                        }
                    }
                }
                Section("Library") {
                    ForEach(lutManager.items) { item in
                        row(for: item)
                            .swipeActions(edge: .trailing) {
                                if !item.isBuiltIn {
                                    Button(role: .destructive) {
                                        lutManager.delete(item.id)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                Button {
                                    renameTarget = item
                                    renameText = item.name
                                } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.orange)
                            }
                    }
                    .onMove { offsets, destination in
                        lutManager.move(from: offsets, to: destination)
                    }
                }
                Section {
                    Text("Import .cube files (17/33/65 and other sizes, 1D and 3D) from Files, or send them to \(AppConstants.appName) from another app. Imported LUTs are stored in the app's Documents folder.")
                        .font(.caption)
                        .foregroundColor(Theme.textDim)
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("LUT Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode == .active ? "Done" : "Edit") {
                        editMode = editMode == .active ? .inactive : .active
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        Button("Close") { dismiss() }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    lutManager.importLUT(from: url)
                } else if case .failure(let error) = result {
                    lutManager.lastImportError = error.localizedDescription
                }
            }
            .alert("Rename LUT", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let target = renameTarget {
                        lutManager.rename(target.id, to: renameText)
                    }
                    renameTarget = nil
                }
            }
            .alert("Import failed",
                   isPresented: Binding(
                    get: { lutManager.lastImportError != nil },
                    set: { if !$0 { lutManager.lastImportError = nil } }
                   )) {
                Button("OK", role: .cancel) { lutManager.lastImportError = nil }
            } message: {
                Text(lutManager.lastImportError ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(for item: LUTItem) -> some View {
        HStack(spacing: 12) {
            Group {
                if let thumb = lutManager.thumbnails[item.id] {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 64, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(item.isBuiltIn ? "Built-in" : "Imported")
                    .font(.caption2)
                    .foregroundColor(Theme.textDim)
            }
            Spacer()
            Button {
                lutManager.toggleFavorite(item.id)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundColor(item.isFavorite ? Theme.accent : Theme.textDim)
            }
            .buttonStyle(.plain)
            if lutManager.selectedID == item.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { lutManager.select(item.id) }
    }
}
