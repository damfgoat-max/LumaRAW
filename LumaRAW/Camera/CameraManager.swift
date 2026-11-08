import AVFoundation
import CoreImage
import Foundation

/// A selectable lens, built ONLY from what AVCaptureDevice.DiscoverySession
/// actually reports on the device — LumaRAW never fakes a lens button.
struct LensOption: Identifiable, Equatable {
    let id: String
    let label: String
    let device: AVCaptureDevice
    static func == (lhs: LensOption, rhs: LensOption) -> Bool { lhs.id == rhs.id }
}

/// Live readout values pushed (throttled) from the capture device to the UI.
struct ExposureInfo: Equatable {
    var iso: Float = 0
    var shutterSeconds: Double = 0
    var lensPosition: Float = 0
    var kelvin: Float = 0
    var tint: Float = 0
    var evBias: Float = 0
}

/// What the current device/format can actually do. Drives which controls
/// and format options the UI shows (e.g. no ProRAW picker on devices whose
/// photo output reports no RAW formats).
struct DeviceCapabilities: Equatable {
    var minISO: Float = 50
    var maxISO: Float = 1600
    var minShutter: Double = 1.0 / 8000.0
    var maxShutter: Double = 1.0
    var minEV: Float = -3
    var maxEV: Float = 3
    var maxZoom: CGFloat = 10
    var hasFlash: Bool = false
    var rawPixelFormatTypes: [OSType] = []
    var isProRAWSupported: Bool = false
    var supports48MP: Bool = false
    var supportsHEIF: Bool = false
}

/// Owns the AVCaptureSession. ALL session/device work runs on a dedicated
/// serial session queue; the session is configured exactly once, and device
/// switching reuses the same outputs. Nothing here touches the main thread
/// except the (throttled, main-hopped) callbacks.
final class CameraManager: NSObject {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "com.lumaraw.session")
    let photoOutput = AVCapturePhotoOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()

    private(set) var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var lastInfoPush = Date.distantPast

    /// Interface orientation used for capture connections; set by the UI.
    var captureOrientation: AVCaptureVideoOrientation = .portrait
    /// When true the active format is chosen to favor 48MP photo dimensions.
    var preferHighResolutionPhotos = false

    // Callbacks (always invoked on the main queue).
    var onExposureInfo: ((ExposureInfo) -> Void)?
    var onCapabilitiesChanged: ((DeviceCapabilities) -> Void)?
    var onSessionError: ((String) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted, object: session)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera session error"
        DispatchQueue.main.async { [weak self] in self?.onSessionError?(message) }
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.onSessionError?("Camera was interrupted (call, another app, or system pressure).")
        }
    }

    // MARK: - Lens discovery

    /// Lenses that physically exist on this device: back ultra-wide / wide /
    /// telephoto (only those the hardware reports) plus the front camera.
    func discoverLenses() -> [LensOption] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera,
            .builtInTelephotoCamera, .builtInTrueDepthCamera
        ]
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        func label(for device: AVCaptureDevice) -> String {
            if device.position == .front { return "Front" }
            switch device.deviceType {
            case .builtInUltraWideCamera: return "0.5×"
            case .builtInTelephotoCamera: return "Tele"
            default: return "1×"
            }
        }
        func sortKey(for device: AVCaptureDevice) -> Int {
            if device.position == .front { return 10 }
            switch device.deviceType {
            case .builtInUltraWideCamera: return 0
            case .builtInWideAngleCamera: return 1
            case .builtInTelephotoCamera: return 2
            default: return 3
            }
        }
        return discovered
            .sorted { sortKey(for: $0) < sortKey(for: $1) }
            .map { LensOption(id: $0.uniqueID, label: label(for: $0), device: $0) }
    }

    /// The default device: back wide-angle if present.
    func defaultDevice() -> AVCaptureDevice? {
        discoverLenses().first { $0.device.position == .back && $0.device.deviceType == .builtInWideAngleCamera }?.device
            ?? discoverLenses().first { $0.device.position == .back }?.device
            ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - Session lifecycle

    /// Configures the session once and starts it. `frameDelegate` (the frame
    /// pipeline) receives sample buffers on its own queue; it decides per
    /// frame whether any work is needed.
    func start(frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate,
               frameQueue: DispatchQueue,
               initialDevice: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                }
                self.videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                self.videoDataOutput.setSampleBufferDelegate(frameDelegate, queue: frameQueue)
                if self.session.canAddOutput(self.videoDataOutput) {
                    self.session.addOutput(self.videoDataOutput)
                }
                self.session.commitConfiguration()
                self.isConfigured = true
            }
            self.applyDeviceLocked(initialDevice)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Switches the active capture device (lens). Runs entirely on the
    /// session queue inside one configuration transaction.
    func switchDevice(to device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in self?.applyDeviceLocked(device) }
    }

    /// Must be called on sessionQueue.
    private func applyDeviceLocked(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            currentDevice = device
        }
        session.commitConfiguration()
        guard currentDevice === device else { return }

        // Pick the best format: largest sensor readout that still does 30fps
        // (smooth preview), biased toward 48MP photo dims when requested.
        if let format = bestFormat(for: device) {
            lockDevice { device.activeFormat = format }
        }
        lockDevice {
            let frameDuration = CMTime(value: 1, timescale: 30)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.videoZoomFactor = 1
        }
        installDeviceObservers(for: device)
        pushCapabilities()
        pushExposureInfo(force: true)
    }

    private func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -1.0
        for format in device.formats {
            let dims = format.formatDescription.dimensions
            var score = Double(dims.width) * Double(dims.height)
            if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) {
                score *= 1.5
            }
            if preferHighResolutionPhotos {
                let maxPhotoArea = format.supportedMaxPhotoDimensions
                    .map { Double($0.width) * Double($0.height) }.max() ?? 0
                score += maxPhotoArea / 10.0
            }
            if score > bestScore { bestScore = score; best = format }
        }
        return best
    }

    // MARK: - Device helpers

    private func lockDevice(_ body: () -> Void) {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            body()
            device.unlockForConfiguration()
        } catch {
            // Device busy/removed: controls simply take effect on next try.
        }
    }

    private func installDeviceObservers(for device: AVCaptureDevice) {
        observations.forEach { $0.invalidate() }
        observations = [
            device.observe(\.iso, options: [.new]) { [weak self] _, _ in self?.pushExposureInfo() },
            device.observe(\.exposureDuration, options: [.new]) { [weak self] _, _ in self?.pushExposureInfo() },
            device.observe(\.lensPosition, options: [.new]) { [weak self] _, _ in self?.pushExposureInfo() },
            device.observe(\.exposureTargetBias, options: [.new]) { [weak self] _, _ in self?.pushExposureInfo() }
        ]
    }

    private func pushExposureInfo(force: Bool = false) {
        guard let device = currentDevice else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastInfoPush) > 0.15 else { return }
        lastInfoPush = now
        let tempAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        let info = ExposureInfo(iso: device.iso,
                                shutterSeconds: device.exposureDuration.seconds,
                                lensPosition: device.lensPosition,
                                kelvin: tempAndTint.temperature,
                                tint: tempAndTint.tint,
                                evBias: device.exposureTargetBias)
        DispatchQueue.main.async { [weak self] in self?.onExposureInfo?(info) }
    }

    private func pushCapabilities() {
        guard let device = currentDevice else { return }
        let format = device.activeFormat
        var caps = DeviceCapabilities()
        caps.minISO = format.minISO
        caps.maxISO = format.maxISO
        caps.minShutter = format.minExposureDuration.seconds
        caps.maxShutter = format.maxExposureDuration.seconds
        caps.minEV = device.minExposureTargetBias
        caps.maxEV = device.maxExposureTargetBias
        caps.maxZoom = min(device.activeFormat.videoMaxZoomFactor, 30)
        caps.hasFlash = device.hasFlash
        caps.rawPixelFormatTypes = photoOutput.availableRawPhotoPixelFormatTypes
        caps.isProRAWSupported = photoOutput.isAppleProRAWSupported
        caps.supportsHEIF = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        caps.supports48MP = device.formats.contains { format in
            format.supportedMaxPhotoDimensions.contains { $0.width >= 8000 }
        }
        DispatchQueue.main.async { [weak self] in self?.onCapabilitiesChanged?(caps) }
    }

    /// Largest photo dimensions the active format supports (for 48MP).
    func largestPhotoDimensions() -> CMVideoDimensions? {
        guard let device = currentDevice else { return nil }
        return device.activeFormat.supportedMaxPhotoDimensions.max {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
    }

    // MARK: - Manual controls (all on the session queue)

    func setExposureAuto() {
        sessionQueue.async { [weak self] in
            self?.lockDevice {
                guard let device = self?.currentDevice else { return }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            self?.pushExposureInfo(force: true)
        }
    }

    func setManualExposure(iso: Float, shutterSeconds: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let format = device.activeFormat
            let clampedISO = min(max(iso, format.minISO), format.maxISO)
            let clampedSeconds = min(max(shutterSeconds, format.minExposureDuration.seconds),
                                     format.maxExposureDuration.seconds)
            let duration = CMTime(seconds: clampedSeconds, preferredTimescale: 1_000_000)
            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { }
            self.pushExposureInfo(force: true)
        }
    }

    func setExposureBias(_ ev: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let clamped = min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias)
            self.lockDevice { device.setExposureTargetBias(clamped, completionHandler: nil) }
            self.pushExposureInfo(force: true)
        }
    }

    func setFocusAuto() {
        sessionQueue.async { [weak self] in
            self?.lockDevice {
                guard let device = self?.currentDevice else { return }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
            self?.pushExposureInfo(force: true)
        }
    }

    func setManualFocus(position: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lockDevice {
                self.currentDevice?.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            }
            self.pushExposureInfo(force: true)
        }
    }

    /// Tap-to-focus: sets focus + exposure points of interest and resumes
    /// continuous AF/AE unless the user has locked them.
    func focusAndExpose(at devicePoint: CGPoint, aeafLocked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lockDevice {
                guard let device = self.currentDevice else { return }
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    if !aeafLocked { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    if !aeafLocked { device.exposureMode = .autoExpose }
                }
            }
            self.pushExposureInfo(force: true)
        }
    }

    /// AE/AF lock (long-press): freezes exposure and focus at current values.
    func setAEAFLock(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lockDevice {
                guard let device = self.currentDevice else { return }
                if locked {
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                } else {
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
            }
            self.pushExposureInfo(force: true)
        }
    }

    func setWhiteBalanceAuto() {
        sessionQueue.async { [weak self] in
            self?.lockDevice {
                guard let device = self?.currentDevice else { return }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
            self?.pushExposureInfo(force: true)
        }
    }

    func setManualWhiteBalance(kelvin: Float, tint: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            self.lockDevice { device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil) }
            self.pushExposureInfo(force: true)
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor),
                              device.activeFormat.videoMaxZoomFactor)
            self.lockDevice { device.videoZoomFactor = clamped }
        }
    }

    /// Re-picks the active format when the 12MP/48MP preference changes.
    func setPreferHighResolutionPhotos(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.preferHighResolutionPhotos = enabled
            guard let device = self.currentDevice, let format = self.bestFormat(for: device) else { return }
            self.lockDevice { device.activeFormat = format }
            self.pushCapabilities()
        }
    }

    /// Applies an orientation to every connection that supports it —
    /// including the preview layer's connection (which is part of
    /// session.connections) and the video data output, so CI preview frames
    /// arrive already upright and the pipeline can use `.up`.
    func setOutputOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            for connection in self.session.connections where connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
    }

    func setProRAWEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.photoOutput.isAppleProRAWSupported else { return }
            self.photoOutput.isAppleProRAWEnabled = enabled
        }
    }

    // MARK: - Capture

    /// Captures one photo. Exactly one of `rawFormat` / `codec` is used:
    /// RAW when the user picked RAW and the device reported a RAW format,
    /// otherwise the processed codec (HEIF/JPEG). Completion fires on an
    /// arbitrary queue — callers hop to where they need.
    func capturePhoto(rawFormat: OSType?,
                      codec: AVVideoCodecType?,
                      flash: AVCaptureFlashMode,
                      useLargestDimensions: Bool,
                      completion: @escaping (AVCapturePhoto?, Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings: AVCapturePhotoSettings
            if let rawFormat {
                // RAW capture: the DNG data arrives untouched in
                // photo.fileDataRepresentation(); PhotoSaver can also render
                // a graded sidecar from it via CIRAWFilter.
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            } else if let codec {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            } else {
                settings = AVCapturePhotoSettings()
            }
            if let device = self.currentDevice, device.hasFlash {
                settings.flashMode = flash
            } else {
                settings.flashMode = .off
            }
            settings.photoQualityPrioritization = .quality
            if useLargestDimensions, let dims = self.largestPhotoDimensions() {
                settings.maxPhotoDimensions = dims
            }
            if let connection = self.photoOutput.connection(with: .video) {
                connection.videoOrientation = self.captureOrientation
            }
            let delegate = PhotoCaptureDelegate { [weak self] photo, error in
                self?.sessionQueue.async { self?.inFlight.removeValue(forKey: settings.uniqueID) }
                completion(photo, error)
            }
            self.inFlight[settings.uniqueID] = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}
