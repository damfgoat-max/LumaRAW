import CoreImage
import Foundation
import SwiftUI

/// Image-domain monitoring tools, applied to the live PREVIEW image only —
/// never to captured photos. All functions take and return CIImages and use
/// built-in Core Image filters (plus one small CIColorKernel for zebra), so
/// they run entirely on the GPU through the shared CIContext.
enum MonitorEffects {

    // MARK: - Zebra stripes

    private static var zebraKernel: CIColorKernel? = {
        // Diagonal white stripes painted over pixels whose luma is at or
        // above the threshold. Stripe pattern derives from destCoord(), so
        // it stays fixed to the screen while the image moves underneath.
        let source = """
        kernel vec4 zebra(sampler src, float threshold) {
            vec4 c = sample(src, samplerCoord(src));
            float l = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
            vec2 dc = destCoord();
            float stripe = mod(dc.x + dc.y, 16.0);
            if (l >= threshold && stripe < 8.0) {
                c.rgb = vec3(1.0, 1.0, 1.0);
            }
            return c;
        }
        """
        return CIColorKernel(source: source)
    }()

    static func applyZebra(to image: CIImage, threshold: Float) -> CIImage {
        guard let kernel = zebraKernel else { return image }
        return kernel.apply(extent: image.extent,
                            roiCallback: { _, rect in rect },
                            arguments: [image, threshold]) ?? image
    }

    // MARK: - False color

    /// A 256x1 gradient strip mapping luma to the classic false-color
    /// palette (purple shadows -> blue -> green -> gray mid -> yellow ->
    /// orange -> red highlights). Built once; CIColorMap indexes it by the
    /// input pixel's luminance.
    private static let falseColorStrip: CIImage? = {
        let width = 256
        guard let ctx = CGContext(data: nil, width: width, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // (stop, RGB) segments across the luma range.
        let stops: [(Float, (CGFloat, CGFloat, CGFloat))] = [
            (0.00, (0.10, 0.00, 0.30)), // near black: deep purple
            (0.12, (0.05, 0.15, 0.80)), // shadows: blue
            (0.28, (0.00, 0.65, 0.35)), // low mids: green
            (0.45, (0.55, 0.55, 0.55)), // middle gray
            (0.60, (0.95, 0.85, 0.30)), // upper mids: yellow
            (0.78, (0.98, 0.55, 0.10)), // highlights: orange
            (0.93, (0.95, 0.05, 0.05)), // near clip: red
            (1.00, (1.00, 0.20, 0.20))  // clipped: bright red
        ]
        for x in 0..<width {
            let t = Float(x) / Float(width - 1)
            var color = stops[stops.count - 1].1
            for i in 1..<stops.count where t <= stops[i].0 {
                let (t0, c0) = stops[i - 1]
                let (t1, c1) = stops[i]
                let f = CGFloat((t - t0) / max(t1 - t0, 0.0001))
                color = (c0.0 + (c1.0 - c0.0) * f, c0.1 + (c1.1 - c0.1) * f, c0.2 + (c1.2 - c0.2) * f)
                break
            }
            ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }()

    static func applyFalseColor(to image: CIImage) -> CIImage {
        guard let strip = falseColorStrip,
              let filter = CIFilter(name: "CIColorMap") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(strip, forKey: "inputGradientImage")
        return filter.outputImage ?? image
    }

    // MARK: - Focus peaking

    /// Edge-detect, turn edge strength into an alpha mask, tint it with the
    /// chosen color and composite over the original image.
    static func applyPeaking(to image: CIImage, color: CIColor) -> CIImage {
        guard let edges = CIFilter(name: "CIEdges") else { return image }
        edges.setValue(image, forKey: kCIInputImageKey)
        edges.setValue(2.5, forKey: kCIInputIntensityKey)
        guard let edgeImage = edges.outputImage else { return image }

        // Boost edge strength a little so weak edges are visible.
        guard let boost = CIFilter(name: "CIColorMatrix") else { return image }
        boost.setValue(edgeImage, forKey: kCIInputImageKey)
        let scale = CIVector(x: 1.6, y: 1.6, z: 1.6, w: 0)
        boost.setValue(scale, forKey: "inputRVector")
        boost.setValue(scale, forKey: "inputGVector")
        boost.setValue(scale, forKey: "inputBVector")
        guard let boosted = boost.outputImage else { return image }

        guard let maskFilter = CIFilter(name: "CIMaskToAlpha") else { return image }
        maskFilter.setValue(boosted, forKey: kCIInputImageKey)
        guard let mask = maskFilter.outputImage else { return image }

        let colorImage = CIImage(color: color).cropped(to: image.extent)
        guard let sourceIn = CIFilter(name: "CISourceInCompositing") else { return image }
        sourceIn.setValue(colorImage, forKey: kCIInputImageKey)
        sourceIn.setValue(mask, forKey: kCIInputBackgroundImageKey)
        guard let tinted = sourceIn.outputImage else { return image }

        guard let over = CIFilter(name: "CISourceOverCompositing") else { return image }
        over.setValue(tinted, forKey: kCIInputImageKey)
        over.setValue(image, forKey: kCIInputBackgroundImageKey)
        return over.outputImage ?? image
    }
}

/// Peaking color choices offered in the Monitor tab.
enum PeakingColor: String, CaseIterable, Identifiable {
    case red, green, blue, yellow, white
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var ciColor: CIColor {
        switch self {
        case .red: return CIColor(red: 1, green: 0.1, blue: 0.1)
        case .green: return CIColor(red: 0.1, green: 1, blue: 0.25)
        case .blue: return CIColor(red: 0.2, green: 0.45, blue: 1)
        case .yellow: return CIColor(red: 1, green: 0.9, blue: 0.1)
        case .white: return CIColor(red: 1, green: 1, blue: 1)
        }
    }
    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .yellow: return .yellow
        case .white: return .white
        }
    }
}
