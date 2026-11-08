import Foundation

/// Programmatically generated built-in LUTs — no external `.cube` assets.
/// Each look is a pure per-pixel color function sampled onto a 33³ lattice.
enum BuiltInLUTs {

    struct Definition {
        let key: String
        let name: String
        let transform: (Float, Float, Float) -> (Float, Float, Float)
    }

    private static func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }

    private static func luminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Smooth S-curve used by several looks.
    private static func sCurve(_ x: Float, strength: Float) -> Float {
        let smooth = x * x * (3 - 2 * x)
        return x + (smooth - x) * strength
    }

    private static func saturate(_ r: Float, _ g: Float, _ b: Float, amount: Float) -> (Float, Float, Float) {
        let l = luminance(r, g, b)
        return (l + (r - l) * amount, l + (g - l) * amount, l + (b - l) * amount)
    }

    static let definitions: [Definition] = [
        Definition(key: "tealOrange", name: "Cinematic Teal & Orange") { r, g, b in
            // Split tone: shadows pushed toward teal, highlights toward
            // orange; mild contrast and saturation on top.
            let l = luminance(r, g, b)
            var (nr, ng, nb) = saturate(r, g, b, amount: 1.12)
            let shadowWeight = (1 - l) * (1 - l) * 0.22
            let highlightWeight = max(0, l - 0.45) * 0.30
            nr += -0.02 * shadowWeight * 8 + 0.05 * highlightWeight * 3
            ng += 0.045 * shadowWeight * 4 + 0.015 * highlightWeight * 3
            nb += 0.075 * shadowWeight * 4 - 0.045 * highlightWeight * 3
            nr = sCurve(nr, strength: 0.35)
            ng = sCurve(ng, strength: 0.35)
            nb = sCurve(nb, strength: 0.35)
            return (clamp01(nr), clamp01(ng), clamp01(nb))
        },
        Definition(key: "bwFilm", name: "B&W Film") { r, g, b in
            // Luminance + filmic contrast + gently lifted blacks.
            var l = luminance(r, g, b)
            l = sCurve(l, strength: 0.55)
            l = l * 0.94 + 0.045
            return (clamp01(l), clamp01(l), clamp01(l))
        },
        Definition(key: "warmVintage", name: "Warm Vintage") { r, g, b in
            // Warm gain, faded blacks, slightly desaturated.
            var (nr, ng, nb) = saturate(r * 1.07, g * 1.0, b * 0.86, amount: 0.85)
            nr = nr * 0.92 + 0.05
            ng = ng * 0.92 + 0.045
            nb = nb * 0.92 + 0.04
            return (clamp01(nr), clamp01(ng), clamp01(nb))
        },
        Definition(key: "logToRec709", name: "Log to Rec.709") { r, g, b in
            // Expands a flat log-style image: strong contrast curve pivoting
            // near log middle gray, plus a saturation restore.
            func expand(_ x: Float) -> Float {
                let y = (x - 0.5) * 1.5 + 0.52
                let curved = sCurve(min(max(y, 0), 1), strength: 0.45)
                return clamp01(curved)
            }
            let (nr, ng, nb) = saturate(expand(r), expand(g), expand(b), amount: 1.18)
            return (clamp01(nr), clamp01(ng), clamp01(nb))
        },
        Definition(key: "neutralPunch", name: "Neutral Punch") { r, g, b in
            let (nr, ng, nb) = saturate(r, g, b, amount: 1.1)
            return (clamp01(sCurve(nr, strength: 0.3)),
                    clamp01(sCurve(ng, strength: 0.3)),
                    clamp01(sCurve(nb, strength: 0.3)))
        }
    ]

    static func definition(forKey key: String) -> Definition? {
        definitions.first { $0.key == key }
    }

    /// Samples a definition onto a 33³ ParsedLUT.
    static func makeLUT(for definition: Definition, dimension: Int = 33) -> ParsedLUT {
        var rgb = [Float]()
        rgb.reserveCapacity(dimension * dimension * dimension * 3)
        let denom = Float(dimension - 1)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let out = definition.transform(Float(r) / denom, Float(g) / denom, Float(b) / denom)
                    rgb.append(out.0); rgb.append(out.1); rgb.append(out.2)
                }
            }
        }
        return ParsedLUT(title: definition.name, dimension: dimension, rgb: rgb)
    }

    /// The Log decode cube used when the user enables "treat input as Log":
    /// it is simply the Log to Rec.709 built-in, applied BEFORE the creative
    /// LUT so creative LUTs still see a Rec.709-like image.
    static func makeLogDecodeProcessor() -> LUTProcessor? {
        guard let def = definition(forKey: "logToRec709") else { return nil }
        return LUTProcessor(parsed: makeLUT(for: def))
    }
}
