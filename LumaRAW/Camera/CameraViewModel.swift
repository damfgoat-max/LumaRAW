import AVFoundation
import Combine
import CoreImage
import Foundation
import Photos
import SwiftUI
import UIKit

enum PhotoFormat: String, CaseIterable, Identifiable {
    case heif, jpeg, raw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heif: return "HEIF"
        case .jpeg: return "JPEG"
        case .raw: return "RAW"
        }
    }
}

enum ResolutionChoice: String, CaseIterable, Identifiable {
    case mp12, mp48
    var id: String { rawValue }
    var title: String { self == .mp12 ? "12MP" : "48MP" }
}

enum GridType: String, CaseIterable, Identifiable {
    case off, thirds, center, golden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .thirds: return "Thirds"
        case .center: return "Center"
        case .golden: return "Golden"
        }
    }
}

enum AspectGuide: String, CaseIterable, Identifiable {
    case full, r43, r32, r169, r11
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "Full"
        case .r43: return "4:3"
        case .r32: return "3:2"
        case .r169: return "16:9"
        case .r11: return "1:1"
        }
    }
    /// width / height, nil for full-frame.
    var ratio: CGFloat? {
        switch self {
        case .full: return nil
        case .r43: return 4.0 / 3.0
        case .r32: return 3.0 / 2.0
        case .r169: return 16.0 / 9.0
        case .r11: return 1.0
        }
    }
}

enum ControlTab: String, CaseIterable, Identifiable {
    case exposure, focus, wb, lut, monitor, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exposure: return "Exposure"
        case .focus: return "Focus"
        case .wb: return "WB"
        case .lut: return "LUT"
        case .monitor: return "Monitor"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .exposure: return "sun.max"
        case .focus: return "scope"
        case .wb: return "thermometer.sun"
        case .lut: return "wand.and.stars"
        case .monitor: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

/// The main view model. Holds USER-FACING state only — no per-frame data
/// ever lands here (frame-rate data lives in the pipeline's per-tool
/// stores), so SwiftUI never re-renders the root view at frame rate.
@MainActor
final class CameraViewModel: ObservableObject {
    let camera = CameraManager()
    let pipeline = FramePipeline()
    let lutManager: LUTManager
    let levelStore = LevelStore()

    // Permission / session
    @Published var cameraAuthorized = false
    @Published var cameraDenied = false
    @Published var statusMessage: String?

    // Lenses
    @Published var lenses: [LensOption] = []
    @Published var selectedLensID: String?

    // Live readouts + capabilities
    @Published var exposureInfo = ExposureInfo()
    @Published var capabilities = DeviceCapabilities()

    // Exposure controls
    @Published var autoExposure = true { didSet { applyExposureMode() } }
    @Published var iso: Double = 100 { didSet { if !autoExposure { applyManualExposure() } } }
    @Published var shutterSeconds: Double = 1.0 / 125.0 { didSet { if !autoExposure { applyManualExposure() } } }
    @Published var evBias: Double = 0 { didSet { camera.setExposureBias(Float(evBias)) } }

    // Focus controls
    @Published var autoFocus = true { didSet { applyFocusMode() } }
    @Published var focusPosition: Double = 0.5 { didSet { if !autoFocus { camera.setManualFocus(position: Float(focusPosition)) } } }
    @Published var aeafLocked = false
    @Published var focusReticle: CGPoint?

    // White balance
    @Published var autoWB = true { didSet { applyWBMode() } }
    @Published var kelvin: Double = 5600 { didSet { if !autoWB { applyManualWB() } } }
    @Published var tint: Double = 0 { didSet { if !autoWB { applyManualWB() } } }

    // Zoom / flash / timer / burst
    @Published var zoomFactor: Double = 1 { didSet { camera.setZoom(CGFloat(zoomFactor)) } }
    @Published var flashMode: AVCaptureFlashMode = .auto
    @Published var timerSeconds: Int = 0
    @Published var burstEnabled = false

    // Capture format & saving
    @Published var format: PhotoFormat = .jpeg { didSet { persistSettings(); syncProRAW(); } }
    @Published var resolution: ResolutionChoice = .mp12 { didSet { persistSettings(); camera.setPreferHighResolutionPhotos(resolution == .mp48) } }
    @Published var saveMode: PhotoSaveMode = .both { didSet { persistSettings() } }
    @Published var useAlbum = true { didSet { persistSettings() } }
    @Published var hapticsEnabled = true { didSet { persistSettings() } }
    @Published var inputIsLog = false { didSet { persistSettings(); syncPipeline() } }

    // LUT
    @Published var lutIntensity: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(lutIntensity, forKey: "lumaraw.lutIntensity")
            lutManager.currentProcessor?.setIntensity(Float(lutIntensity))
        }
    }
    @Published var compareOriginal = false { didSet { syncPipeline() } }

    // Monitoring & composition aids
    @Published var monitors = MonitorConfig() { didSet { syncPipeline() } }
    @Published var showLevel = false {
        didSet {
            if showLevel { levelStore.start() } else { levelStore.stop() }
        }
    }
    @Published var gridType: GridType = .thirds
    @Published var aspectGuide: AspectGuide = .full
    @Published var hideUI = false

    // UI flow
    @Published var activeTab: ControlTab = .exposure
    @Published var isCapturing = false
    @Published var countdown: Int?
    @Published var lastCaptureThumbnail: UIImage?
    @Published var pipelineActive = false

    private var cancellables = Set<AnyCancellable>()
    private var logDecodeProcessor: LUTProcessor?
    private var started = false
    private var countdownTask: Task<Void, Never>?

    init(lutManager: LUTManager) {
        self.lutManager = lutManager
        loadPersistedSettings()
        logDecodeProcessor = BuiltInLUTs.makeLogDecodeProcessor()

        camera.onExposureInfo = { [weak self] info in self?.exposureInfo = info }
        camera.onCapabilitiesChanged = { [weak self] caps in
            guard let self else { return }
            self.capabilities = caps
            // Graceful format fallback: if the new device has no RAW, the
            // RAW choice silently becomes JPEG (spec §3).
            if self.format == .raw && caps.rawPixelFormatTypes.isEmpty {
                self.format = .jpeg
            }
            if self.resolution == .mp48 && !caps.supports48MP {
                self.resolution = .mp12
            }
            self.reapplyManualSettings()
        }
        camera.onSessionError = { [weak self] message in
            self?.statusMessage = message
        }

        lutManager.$selectedID
            .sink { [weak self] _ in
                guard let self else { return }
                self.lutManager.currentProcessor?.setIntensity(Float(self.lutIntensity))
                self.syncPipeline()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(orientationChanged),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Lifecycle

    func onAppear() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationChanged()
        guard !started else { return }
        started = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cameraAuthorized = granted
                self.cameraDenied = !granted
                if granted { self.startCamera() }
            }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    private func startCamera() {
        lenses = camera.discoverLenses()
        guard let device = camera.defaultDevice() else {
            statusMessage = "No camera is available on this device."
            return
        }
        selectedLensID = lenses.first { $0.device.uniqueID == device.uniqueID }?.id
        camera.start(frameDelegate: pipeline, frameQueue: pipeline.queue, initialDevice: device)
        syncPipeline()
    }

    // MARK: - Orientation

    @objc private func orientationChanged() {
        // AVCaptureVideoOrientation landscape directions are mirrored
        // relative to UIDeviceOrientation (the AVCam convention).
        let capture: AVCaptureVideoOrientation
        switch UIDevice.current.orientation {
        case .portrait: capture = .portrait
        case .portraitUpsideDown: capture = .portraitUpsideDown
        case .landscapeLeft: capture = .landscapeRight
        case .landscapeRight: capture = .landscapeLeft
        default: return
        }
        camera.captureOrientation = capture
        camera.setOutputOrientation(capture)
    }

    // MARK: - Lens switching

    var selectedLens: LensOption? { lenses.first { $0.id == selectedLensID } }

    func selectLens(_ lens: LensOption) {
        guard lens.id != selectedLensID else { return }
        selectedLensID = lens.id
        zoomFactor = 1
        camera.switchDevice(to: lens.device)
        tapHaptic()
    }

    func flipCamera() {
        guard let current = selectedLens else { return }
        let target = current.device.position == .back ? AVCaptureDevice.Position.front : .back
        if let lens = lenses.first(where: { $0.device.position == target }) {
            selectLens(lens)
        }
    }

    // MARK: - Control application

    private func applyExposureMode() {
        if autoExposure {
            camera.setExposureAuto()
        } else {
            // Seed the manual sliders from the live values so switching to
            // MANUAL doesn't jump the exposure.
            if exposureInfo.iso > 0 { iso = Double(exposureInfo.iso) }
            if exposureInfo.shutterSeconds > 0 { shutterSeconds = exposureInfo.shutterSeconds }
            applyManualExposure()
        }
    }

    private func applyManualExposure() {
        camera.setManualExposure(iso: Float(iso), shutterSeconds: shutterSeconds)
    }

    private func applyFocusMode() {
        if autoFocus { camera.setFocusAuto() } else { camera.setManualFocus(position: Float(focusPosition)) }
    }

    private func applyWBMode() {
        if autoWB { camera.setWhiteBalanceAuto() } else { applyManualWB() }
    }

    private func applyManualWB() {
        camera.setManualWhiteBalance(kelvin: Float(kelvin), tint: Float(tint))
    }

    private func reapplyManualSettings() {
        if !autoExposure { applyManualExposure() }
        if !autoFocus { camera.setManualFocus(position: Float(focusPosition)) }
        if !autoWB { applyManualWB() }
        camera.setExposureBias(Float(evBias))
        camera.setZoom(CGFloat(zoomFactor))
    }

    private func syncProRAW() {
        camera.setProRAWEnabled(format == .raw)
    }

    // MARK: - Tap focus / AE-AF lock

    func tapToFocus(at normalizedPoint: CGPoint) {
        focusReticle = normalizedPoint
        camera.focusAndExpose(at: normalizedPoint, aeafLocked: aeafLocked)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if self?.focusReticle == normalizedPoint { self?.focusReticle = nil }
        }
    }

    func toggleAEAFLock() {
        aeafLocked.toggle()
        camera.setAEAFLock(aeafLocked)
        statusMessage = aeafLocked ? "AE/AF locked" : "AE/AF unlocked"
        tapHaptic()
    }

    // MARK: - Pipeline sync

    func syncPipeline() {
        let lut = lutManager.currentProcessor
        pipelineActive = FramePipeline.previewNeeded(lutActive: lut != nil, monitors: monitors)
        pipeline.updateConfiguration(lutProcessor: lut,
                                     logDecodeProcessor: logDecodeProcessor,
                                     inputIsLog: inputIsLog,
                                     compareOriginal: compareOriginal,
                                     monitors: monitors,
                                     orientation: .up)
    }

    // MARK: - Capture

    func capture() {
        guard cameraAuthorized, !isCapturing, countdown == nil else { return }
        if timerSeconds > 0 {
            countdown = timerSeconds
            countdownTask = Task { [weak self] in
                guard let self else { return }
                var remaining = self.timerSeconds
                while remaining > 0 {
                    self.countdown = remaining
                    self.tapHaptic()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { self.countdown = nil; return }
                    remaining -= 1
                }
                self.countdown = nil
                self.performCapture()
            }
            return
        }
        performCapture()
    }

    private func performCapture() {
        isCapturing = true
        captureHaptic()
        captureMultiple(remaining: burstEnabled ? 5 : 1)
    }

    private func captureMultiple(remaining: Int) {
        let rawFormat = currentRawFormat()
        let codec: AVVideoCodecType?
        if rawFormat != nil {
            codec = nil
        } else if format == .heif && capabilities.supportsHEIF {
            codec = .hevc
        } else {
            codec = .jpeg
        }
        let useLargest = resolution == .mp48 && capabilities.supports48MP
        camera.capturePhoto(rawFormat: rawFormat,
                            codec: codec,
                            flash: flashMode,
                            useLargestDimensions: useLargest) { [weak self] photo, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let photo {
                    self.updateThumbnail(from: photo)
                    self.save(photo: photo)
                } else if let error {
                    self.statusMessage = error.localizedDescription
                }
                if remaining > 1 {
                    self.captureMultiple(remaining: remaining - 1)
                } else {
                    self.isCapturing = false
                }
            }
        }
    }

    private func currentRawFormat() -> OSType? {
        guard format == .raw else { return nil }
        let types = capabilities.rawPixelFormatTypes
        guard !types.isEmpty else { return nil }
        if capabilities.isProRAWSupported {
            // The Apple ProRAW pixel format is the non-Bayer entry in the
            // list; the Bayer constants below are the classic RAW formats.
            let bayerFormats: Set<OSType> = [
                kCVPixelFormatType_14Bayer_RGGB, kCVPixelFormatType_14Bayer_BGGR,
                kCVPixelFormatType_14Bayer_GRBG, kCVPixelFormatType_14Bayer_GBRG
            ]
            if let proRAW = types.first(where: { !bayerFormats.contains($0) }) {
                return proRAW
            }
        }
        return types.first
    }

    private func save(photo: AVCapturePhoto) {
        let processor = lutManager.currentProcessor
        processor?.setIntensity(Float(lutIntensity))
        PhotoSaver.save(photo: photo,
                        mode: saveMode,
                        formatIsHEIF: format == .heif,
                        processor: saveMode == .original ? nil : processor,
                        useAlbum: useAlbum) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self?.statusMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updateThumbnail(from photo: AVCapturePhoto) {
        if let pixelBuffer = photo.previewPixelBuffer {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            if let cg = ImageEngine.renderContext.createCGImage(image, from: image.extent) {
                lastCaptureThumbnail = UIImage(cgImage: cg)
            }
        }
    }

    // MARK: - Haptics

    func tapHaptic() {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func captureHaptic() {
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Persistence (settings only; LUT selection lives in LUTManager)

    private func loadPersistedSettings() {
        let defaults = UserDefaults.standard
        lutIntensity = defaults.object(forKey: "lumaraw.lutIntensity") as? Double ?? 1.0
        if let raw = defaults.string(forKey: "lumaraw.format"), let value = PhotoFormat(rawValue: raw) { format = value }
        if let raw = defaults.string(forKey: "lumaraw.resolution"), let value = ResolutionChoice(rawValue: raw) { resolution = value }
        if let raw = defaults.string(forKey: "lumaraw.saveMode"), let value = PhotoSaveMode(rawValue: raw) { saveMode = value }
        useAlbum = defaults.object(forKey: "lumaraw.useAlbum") as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: "lumaraw.haptics") as? Bool ?? true
        inputIsLog = defaults.object(forKey: "lumaraw.inputIsLog") as? Bool ?? false
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(format.rawValue, forKey: "lumaraw.format")
        defaults.set(resolution.rawValue, forKey: "lumaraw.resolution")
        defaults.set(saveMode.rawValue, forKey: "lumaraw.saveMode")
        defaults.set(useAlbum, forKey: "lumaraw.useAlbum")
        defaults.set(hapticsEnabled, forKey: "lumaraw.haptics")
        defaults.set(inputIsLog, forKey: "lumaraw.inputIsLog")
    }
}
