import Photos
import SwiftUI
import UIKit

/// Root camera screen. Layout mirrors the Blackmagic-style workflow —
/// status bar, preview, readout row, tool tabs, control panel, shutter —
/// with an original near-black/amber design.
///
/// IMPORTANT (performance): this view's body reads only slow-changing view
/// model state. Frame-rate data (histogram, waveform, level, preview
/// frames) lives in dedicated stores rendered by leaf views, so the root
/// never re-renders per frame.
struct CameraView: View {
    @ObservedObject var viewModel: CameraViewModel
    @EnvironmentObject var lutManager: LUTManager
    @State private var showLUTLibrary = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if viewModel.cameraDenied {
                PermissionDeniedView()
            } else {
                GeometryReader { geo in
                    if geo.size.width > geo.size.height {
                        landscapeLayout
                    } else {
                        portraitLayout
                    }
                }
            }
        }
        .background(Color.black)
        .onAppear { viewModel.onAppear() }
        .sheet(isPresented: $showLUTLibrary) {
            LUTLibraryView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel, onOpenLUTLibrary: {
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showLUTLibrary = true
                }
            })
        }
        .onChange(of: viewModel.statusMessage) { message in
            guard message != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if viewModel.statusMessage == message {
                    viewModel.statusMessage = nil
                }
            }
        }
    }

    // MARK: - Layouts

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            StatusBarView(viewModel: viewModel)
            previewArea
            if !viewModel.hideUI {
                lensBar
                ReadoutRow(viewModel: viewModel)
                tabBar
                panel
                shutterRow
            }
        }
    }

    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                StatusBarView(viewModel: viewModel)
                previewArea
                if !viewModel.hideUI {
                    lensBar
                    ReadoutRow(viewModel: viewModel)
                }
            }
            if !viewModel.hideUI {
                VStack(spacing: 0) {
                    tabBar
                    panel
                    Spacer()
                    shutterRow
                }
                .frame(width: 330)
                .background(Theme.panel)
            }
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PreviewLayerView(session: viewModel.camera.session,
                                 onVolumeCapture: { viewModel.capture() })
                    .opacity(viewModel.pipelineActive ? 0 : 1)
                MetalPreviewView(renderer: viewModel.pipeline.renderer)
                    .opacity(viewModel.pipelineActive ? 1 : 0)

                // Gesture surface: tap = focus point, long-press = AE/AF lock.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let point = CGPoint(x: value.location.x / max(geo.size.width, 1),
                                                    y: value.location.y / max(geo.size.height, 1))
                                viewModel.tapToFocus(at: point)
                            }
                    )
                    .onLongPressGesture(minimumDuration: 0.5) {
                        viewModel.toggleAEAFLock()
                    }

                if viewModel.gridType != .off {
                    GridOverlayView(type: viewModel.gridType)
                }
                if let ratio = viewModel.aspectGuide.ratio {
                    AspectGuideView(ratio: ratio)
                }

                // Scopes (leaf views on their own stores).
                VStack {
                    HStack(alignment: .top, spacing: 8) {
                        if viewModel.monitors.histogram {
                            HistogramView(store: viewModel.pipeline.histogramStore)
                                .frame(width: 148, height: 54)
                        }
                        Spacer()
                        if viewModel.monitors.waveform {
                            WaveformView(store: viewModel.pipeline.waveformStore)
                                .frame(width: 148, height: 82)
                        }
                    }
                    Spacer()
                    if viewModel.showLevel {
                        LevelOverlayView(store: viewModel.levelStore)
                            .padding(.bottom, 10)
                    }
                }
                .padding(10)

                if let point = viewModel.focusReticle {
                    FocusReticleView(normalizedPoint: point, locked: viewModel.aeafLocked)
                }

                if viewModel.aeafLocked {
                    Text("AE/AF LOCK")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                        .allowsHitTesting(false)
                }

                if let countdown = viewModel.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(radius: 12)
                        .allowsHitTesting(false)
                }

                if viewModel.hideUI {
                    Button {
                        viewModel.hideUI = false
                    } label: {
                        Image(systemName: "eye")
                            .font(.callout)
                            .padding(10)
                            .background(Color.black.opacity(0.55))
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(14)
                }

                if let message = viewModel.statusMessage {
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .clipped()
    }

    // MARK: - Chrome (lens bar, tabs, panel, shutter)

    private var lensBar: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.lenses) { lens in
                Button {
                    viewModel.selectLens(lens)
                } label: {
                    Text(lens.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(viewModel.selectedLensID == lens.id ? Theme.accent : Theme.raised)
                        .foregroundColor(viewModel.selectedLensID == lens.id ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if viewModel.burstEnabled {
                Label("BURST ×5", systemImage: "square.stack.3d.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.accent)
            }
            Button {
                viewModel.hideUI = true
            } label: {
                Image(systemName: "eye.slash")
                    .foregroundColor(Theme.textDim)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ControlTab.allCases) { tab in
                Button {
                    if tab == .settings {
                        showSettings = true
                    } else {
                        viewModel.activeTab = tab
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15))
                        Text(tab.title)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(viewModel.activeTab == tab ? Theme.accent : Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.panel)
        .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1), alignment: .top)
    }

    @ViewBuilder
    private var panel: some View {
        Group {
            switch viewModel.activeTab {
            case .exposure: ExposurePanel(viewModel: viewModel)
            case .focus: FocusPanel(viewModel: viewModel)
            case .wb: WBPanel(viewModel: viewModel)
            case .lut: LUTPanel(viewModel: viewModel, onOpenLibrary: { showLUTLibrary = true })
            case .monitor: MonitorPanel(viewModel: viewModel)
            case .settings: ExposurePanel(viewModel: viewModel)
            }
        }
        .frame(height: 148)
        .background(Theme.panel)
        .clipped()
    }

    private var shutterRow: some View {
        HStack {
            GalleryThumbnailView(latestCapture: viewModel.lastCaptureThumbnail)
                .frame(width: 46, height: 46)
            Spacer()
            Button {
                viewModel.capture()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 74, height: 74)
                    Circle()
                        .fill(viewModel.isCapturing ? Color.gray : Color.white)
                        .frame(width: 60, height: 60)
                    if viewModel.timerSeconds > 0 {
                        Text("\(viewModel.timerSeconds)s")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isCapturing)
            Spacer()
            Button {
                viewModel.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Theme.raised)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color.black)
    }
}

/// Gallery thumbnail next to the shutter: shows the in-app capture first,
/// otherwise the most recent photo in the library. Tapping opens Photos.
private struct GalleryThumbnailView: View {
    let latestCapture: UIImage?
    @State private var libraryImage: UIImage?

    var body: some View {
        Button {
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        } label: {
            Group {
                if let image = latestCapture ?? libraryImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Theme.raised
                        Image(systemName: "photo")
                            .foregroundColor(Theme.textDim)
                    }
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onAppear(perform: fetchLatest)
    }

    private func fetchLatest() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else { return }
            let manager = PHImageManager.default()
            manager.requestImage(for: asset,
                                 targetSize: CGSize(width: 92, height: 92),
                                 contentMode: .aspectFill,
                                 options: nil) { image, _ in
                DispatchQueue.main.async { libraryImage = image }
            }
        }
    }
}
