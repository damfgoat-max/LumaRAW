import CoreImage
import Foundation
import Metal

/// Wraps one parsed LUT as a GPU `CIColorCubeWithColorSpace` filter.
///
/// Intensity is implemented by blending the cube data itself toward the
/// identity cube (entry' = identity*(1-t) + entry*t) instead of chaining a
/// mix filter at render time — that keeps the render pipeline at exactly one
/// filter for a LUT, in the preview and in captured photos alike. Rebuilding
/// the blended cube for a 33³ LUT is ~36k entries (a few ms); for a 64³
/// 1D-baked cube ~262k entries, still fine on slider release / debounced
/// during drags by the caller.
final class LUTProcessor {
    let dimension: Int
    /// Un-blended RGB cube from the parser.
    private let baseRGB: [Float]
    /// Current intensity 0...1 baked into `cubeData`.
    private(set) var intensity: Float = 1
    /// RGBA Float32 cube data handed to CIColorCube.
    private var cubeData: Data
    private var cachedFilter: CIFilter?

    init(parsed: ParsedLUT) {
        dimension = parsed.dimension
        baseRGB = parsed.rgb
        cubeData = Data()
        rebuildCubeData()
    }

    func setIntensity(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - intensity) > 0.001 else { return }
        intensity = clamped
        rebuildCubeData()
        cachedFilter = nil
    }

    private func rebuildCubeData() {
        let d = dimension
        let denom = Float(d - 1)
        var rgba = [Float](repeating: 1, count: d * d * d * 4)
        let t = intensity
        let inv = 1 - t
        for b in 0..<d {
            for g in 0..<d {
                for r in 0..<d {
                    let lattice = (b * d + g) * d + r
                    let src = lattice * 3
                    let dst = lattice * 4
                    rgba[dst]     = Float(r) / denom * inv + baseRGB[src] * t
                    rgba[dst + 1] = Float(g) / denom * inv + baseRGB[src + 1] * t
                    rgba[dst + 2] = Float(b) / denom * inv + baseRGB[src + 2] * t
                    rgba[dst + 3] = 1
                }
            }
        }
        cubeData = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The Core Image filter for this LUT at the current intensity.
    /// `inputColorSpace` tells CIColorCubeWithColorSpace which color space
    /// the cube was authored in — LumaRAW assumes Rec.709/sRGB per spec.
    func makeFilter() -> CIFilter? {
        if let cached = cachedFilter { return cached }
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        cachedFilter = filter
        return filter
    }

    /// Applies the LUT to an image. Input is the raw camera CIImage
    /// (pixelBuffer -> CIImage); output is the graded image in the same extent.
    func apply(to image: CIImage) -> CIImage {
        guard intensity > 0.001, let filter = makeFilter() else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }
}

/// Shared, app-wide Core Image contexts. Creating a CIContext is expensive;
/// the spec's performance rules demand exactly one Metal-backed context for
/// rendering and one for image encoding, reused everywhere.
enum ImageEngine {
    static let renderContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    static let encodeContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()
}
