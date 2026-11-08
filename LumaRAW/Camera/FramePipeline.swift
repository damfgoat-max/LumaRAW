import AVFoundation
import CoreImage
import Foundation
import MetalKit

/// Image-domain monitoring configuration (the tools that alter or analyze
/// the preview pixels). Overlays like grids/level are pure SwiftUI and
/// don't appear here.
struct MonitorConfig: Equatable {
    var histogram = false
    var waveform = false
    var zebra = false
    var zebraThreshold: Float = 0.9
    var peaking = false
    var peakingColor: PeakingColor = .red
    var falseColor = false

    var anyImageToolOn: Bool { zebra || peaking || falseColor }
    var anyAnalysisOn: Bool { histogram || waveform }
}

/// Renders CIImages into an MTKView with aspect-fill. Frames are handed off
/// through a lock-protected slot; MTKView draws on demand (paused +
/// enableSetNeedsDisplay) so the display never drives the camera — the
/// camera drives the display, and only when a new frame is ready.
final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    let mtkView: MTKView
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext
    private var pendingImage: CIImage?
    private let lock = NSLock()

    override init() {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        mtkView = view
        let device = view.device
        commandQueue = device?.makeCommandQueue()
        ciContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext()
        super.init()
        view.delegate = self
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.backgroundColor = .black
    }

    func display(_ image: CIImage) {
        lock.lock()
        pendingImage = image
        lock.unlock()
        mtkView.setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        lock.lock()
        let image = pendingImage
        pendingImage = nil
        lock.unlock()
        guard let image,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0,
              image.extent.width > 0, image.extent.height > 0 else { return }
        // Aspect-fill: scale to cover the drawable, center, crop overflow.
        let scale = max(drawableSize.width / image.extent.width,
                        drawableSize.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let tx = (drawableSize.width - scaled.extent.width) / 2 - scaled.extent.minX
        let ty = (drawableSize.height - scaled.extent.height) / 2 - scaled.extent.minY
        let placed = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        ciContext.render(placed,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(origin: .zero, size: drawableSize),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// The video-data-output delegate. Runs entirely on its own serial queue.
///
/// Pipeline per frame (pixelBuffer -> CIImage -> [Log decode] -> [LUT] ->
/// [monitor effects] -> renderer), and only when something actually needs
/// the pixels: if no LUT is active and every image monitor is off, the
/// delegate returns immediately and the cheap AVCaptureVideoPreviewLayer
/// path shows the feed. Histogram/waveform analysis runs on a DOWNSCALED
/// image throttled to ~10fps, and results go to the dedicated per-tool
/// stores — never into the main view model.
final class FramePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "com.lumaraw.frames")
    let renderer = MetalPreviewRenderer()
    let histogramStore = HistogramStore()
    let waveformStore = WaveformStore()

    // Configuration, written from the main thread, read on the frame queue.
    private let configLock = NSLock()
    private var _lutProcessor: LUTProcessor?
    private var _logDecodeProcessor: LUTProcessor?
    private var _inputIsLog = false
    private var _compareOriginal = false
    private var _monitors = MonitorConfig()
    private var _orientation: CGImagePropertyOrientation = .right
    private var frameIndex = 0

    // Reused analysis buffers (frame queue only).
    private var analysisContext: CGContext?
    private var analysisBuffer: [UInt8] = []
    private var analysisSize: (Int, Int) = (0, 0)
    private var waveformContext: CGContext?
    private var waveformBuffer: [UInt8] = []

    func updateConfiguration(lutProcessor: LUTProcessor?,
                             logDecodeProcessor: LUTProcessor?,
                             inputIsLog: Bool,
                             compareOriginal: Bool,
                             monitors: MonitorConfig,
                             orientation: CGImagePropertyOrientation) {
        configLock.lock()
        _lutProcessor = lutProcessor
        _logDecodeProcessor = logDecodeProcessor
        _inputIsLog = inputIsLog
        _compareOriginal = compareOriginal
        _monitors = monitors
        _orientation = orientation
        configLock.unlock()
    }

    /// True when the CI preview path must be visible (LUT or image monitor).
    static func previewNeeded(lutActive: Bool, monitors: MonitorConfig) -> Bool {
        lutActive || monitors.anyImageToolOn
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        configLock.lock()
        let lut = _lutProcessor
        let logDecode = _logDecodeProcessor
        let inputIsLog = _inputIsLog
        let compare = _compareOriginal
        let monitors = _monitors
        let orientation = _orientation
        configLock.unlock()

        let renderPreview = Self.previewNeeded(lutActive: lut != nil, monitors: monitors)
        guard renderPreview || monitors.anyAnalysisOn else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // pixelBuffer -> CIImage (zero-copy view of the camera frame).
        let source = CIImage(cvPixelBuffer: pixelBuffer)

        var processed: CIImage?
        if renderPreview {
            var image = source
            if !compare {
                if inputIsLog, let logDecode {
                    image = logDecode.apply(to: image)
                }
                if let lut {
                    image = lut.apply(to: image)
                }
            }
            if monitors.falseColor {
                image = MonitorEffects.applyFalseColor(to: image)
            } else {
                if monitors.zebra {
                    image = MonitorEffects.applyZebra(to: image, threshold: monitors.zebraThreshold)
                }
                if monitors.peaking {
                    image = MonitorEffects.applyPeaking(to: image, color: monitors.peakingColor.ciColor)
                }
            }
            let oriented = image.oriented(orientation)
            renderer.display(oriented)
            processed = oriented
        }

        // Analysis: every 3rd frame (~10fps at 30fps capture).
        frameIndex += 1
        if monitors.anyAnalysisOn && frameIndex % 3 == 0 {
            let analysisImage = processed ?? source.oriented(orientation)
            analyze(analysisImage, histogram: monitors.histogram, waveform: monitors.waveform)
        }
    }

    // MARK: - Analysis (frame queue; works on a <=256px-wide bitmap)

    private func analyze(_ image: CIImage, histogram: Bool, waveform: Bool) {
        let targetWidth = 256
        guard image.extent.width > 0 else { return }
        let scale = CGFloat(targetWidth) / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(small.extent.width.rounded())
        let height = Int(small.extent.height.rounded())
        guard width > 0, height > 0,
              let cgImage = ImageEngine.renderContext.createCGImage(small, from: small.extent) else { return }

        if analysisSize != (width, height) || analysisContext == nil {
            analysisBuffer = [UInt8](repeating: 0, count: width * height * 4)
            analysisSize = (width, height)
            analysisContext = analysisBuffer.withUnsafeMutableBufferPointer { ptr in
                CGContext(data: ptr.baseAddress, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
        }
        guard let ctx = analysisContext else { return }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bins = 64
        var rBins = [Float](repeating: 0, count: bins)
        var gBins = [Float](repeating: 0, count: bins)
        var bBins = [Float](repeating: 0, count: bins)
        var lBins = [Float](repeating: 0, count: bins)

        let waveCols = 96
        let waveRows = 56
        var waveCounts = [UInt16](repeating: 0, count: waveCols * waveRows)
        var waveMax: UInt16 = 1

        let buffer = analysisBuffer
        let totalPixels = width * height
        for i in 0..<totalPixels {
            let base = i * 4
            let b = buffer[base], g = buffer[base + 1], r = buffer[base + 2]
            if histogram {
                rBins[Int(r) >> 2] += 1
                gBins[Int(g) >> 2] += 1
                bBins[Int(b) >> 2] += 1
            }
            let luma = (Float(r) * 0.2126 + Float(g) * 0.7152 + Float(b) * 0.0722) / 255.0
            if histogram { lBins[min(Int(luma * Float(bins)), bins - 1)] += 1 }
            if waveform {
                let x = i % width
                let col = x * waveCols / width
                let row = min(Int(luma * Float(waveRows)), waveRows - 1)
                let idx = (waveRows - 1 - row) * waveCols + col
                waveCounts[idx] &+= 1
                if waveCounts[idx] > waveMax { waveMax = waveCounts[idx] }
            }
        }

        if histogram {
            let norm = Float(totalPixels)
            func normalize(_ binsData: [Float]) -> [Float] {
                let peak = binsData.max() ?? 1
                let denom = peak > 0 ? peak : norm
                return binsData.map { $0 / denom }
            }
            let nr = normalize(rBins), ng = normalize(gBins), nb = normalize(bBins), nl = normalize(lBins)
            DispatchQueue.main.async { [histogramStore] in
                histogramStore.update(red: nr, green: ng, blue: nb, luma: nl)
            }
        }
        if waveform {
            let image = renderWaveform(counts: waveCounts, max: waveMax, cols: waveCols, rows: waveRows)
            DispatchQueue.main.async { [waveformStore] in waveformStore.update(image) }
        }
    }

    private func renderWaveform(counts: [UInt16], max: UInt16, cols: Int, rows: Int) -> CGImage? {
        if waveformContext == nil || waveformBuffer.count != cols * rows * 4 {
            waveformBuffer = [UInt8](repeating: 0, count: cols * rows * 4)
            waveformContext = waveformBuffer.withUnsafeMutableBufferPointer { ptr in
                CGContext(data: ptr.baseAddress, width: cols, height: rows,
                          bitsPerComponent: 8, bytesPerRow: cols * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
        }
        guard waveformContext != nil else { return nil }
        let denom = Float(max)
        for i in 0..<(cols * rows) {
            let base = i * 4
            let intensity = denom > 0 ? pow(Float(counts[i]) / denom, 0.5) : 0
            waveformBuffer[base] = UInt8(intensity * 90)          // B
            waveformBuffer[base + 1] = UInt8(40 + intensity * 215) // G (green trace)
            waveformBuffer[base + 2] = UInt8(intensity * 80)       // R
            waveformBuffer[base + 3] = 255
        }
        // CGContext over the same buffer: makeImage snapshots current bytes.
        return waveformContext?.makeImage()
    }
}
