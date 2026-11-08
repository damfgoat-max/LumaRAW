import AVFoundation
import SwiftUI

/// Settings screen: format, saving, LUT behavior, composition aids and
/// general preferences. Opened from the Settings tool tab.
struct SettingsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @EnvironmentObject var lutManager: LUTManager
    @Environment(\.dismiss) private var dismiss
    var onOpenLUTLibrary: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture format") {
                    Picker("Format", selection: $viewModel.format) {
                        ForEach(PhotoFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    if !viewModel.capabilities.rawPixelFormatTypes.isEmpty == false && viewModel.format == .raw {
                        Text("This device does not report RAW support, so RAW falls back to JPEG.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if viewModel.format == .heif && !viewModel.capabilities.supportsHEIF {
                        Text("HEIF is not available on this device; JPEG will be used.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Picker("Resolution", selection: $viewModel.resolution) {
                        ForEach(ResolutionChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    if viewModel.resolution == .mp48 && !viewModel.capabilities.supports48MP {
                        Text("48MP is not supported by this device's camera formats.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Picker("Flash", selection: Binding(
                        get: { viewModel.flashMode.rawValue },
                        set: { viewModel.flashMode = AVCaptureFlashMode(rawValue: $0) ?? .auto }
                    )) {
                        Text("Auto").tag(AVCaptureFlashMode.auto.rawValue)
                        Text("On").tag(AVCaptureFlashMode.on.rawValue)
                        Text("Off").tag(AVCaptureFlashMode.off.rawValue)
                    }
                    Picker("Timer", selection: $viewModel.timerSeconds) {
                        Text("Off").tag(0)
                        Text("3s").tag(3)
                        Text("10s").tag(10)
                    }
                    Toggle("Burst mode (5 shots)", isOn: $viewModel.burstEnabled)
                }

                Section("Saving") {
                    Picker("Save mode", selection: $viewModel.saveMode) {
                        ForEach(PhotoSaveMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Save to “\(AppConstants.albumName)” album", isOn: $viewModel.useAlbum)
                    Text("RAW captures always save the untouched DNG; with a LUT active, “Original + graded” also renders a graded JPEG next to it.")
                        .font(.caption)
                        .foregroundColor(Theme.textDim)
                }

                Section("LUT") {
                    HStack {
                        Text("Active LUT")
                        Spacer()
                        Text(lutManager.selectedItem?.name ?? "None")
                            .foregroundColor(Theme.textDim)
                    }
                    Button("Open LUT Library") { onOpenLUTLibrary() }
                    Toggle("Treat input as Log", isOn: $viewModel.inputIsLog)
                    Text("Applies the built-in Log → Rec.709 conversion before your creative LUT. Leave off for normal Rec.709/sRGB camera output.")
                        .font(.caption)
                        .foregroundColor(Theme.textDim)
                }

                Section("Composition") {
                    Picker("Grid", selection: $viewModel.gridType) {
                        ForEach(GridType.allCases) { grid in
                            Text(grid.title).tag(grid)
                        }
                    }
                    Picker("Aspect guide", selection: $viewModel.aspectGuide) {
                        ForEach(AspectGuide.allCases) { guide in
                            Text(guide.title).tag(guide)
                        }
                    }
                    Toggle("Horizon level", isOn: $viewModel.showLevel)
                }

                Section("General") {
                    Toggle("Haptics", isOn: $viewModel.hapticsEnabled)
                    Toggle("Hide interface", isOn: $viewModel.hideUI)
                }

                Section("About") {
                    HStack {
                        Text("App")
                        Spacer()
                        Text(AppConstants.appName).foregroundColor(Theme.textDim)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                            .foregroundColor(Theme.textDim)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
