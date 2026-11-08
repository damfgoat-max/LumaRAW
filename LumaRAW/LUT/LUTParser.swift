import Foundation

/// Errors thrown while parsing a `.cube` file. Every case carries enough
/// information for the UI to show a clear, human-readable message.
enum LUTParseError: LocalizedError {
    case emptyFile
    case missingSize
    case invalidSize(String)
    case invalidNumber(String)
    case notEnoughData(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The file is empty."
        case .missingSize:
            return "Not a valid .cube file: no LUT_3D_SIZE or LUT_1D_SIZE line was found."
        case .invalidSize(let text):
            return "Invalid LUT size value: “\(text)”."
        case .invalidNumber(let text):
            return "Invalid number in LUT data: “\(text)”."
        case .notEnoughData(let expected, let got):
            return "The LUT data is truncated: expected \(expected) numbers but found \(got)."
        }
    }
}

/// A parsed LUT, always normalized to a single 3D cube so the renderer only
/// ever deals with one representation.
struct ParsedLUT {
    var title: String?
    /// Cube dimension (e.g. 17, 33, 65 for parsed 3D LUTs).
    var dimension: Int
    /// RGB triples, `dimension^3 * 3` floats. Ordering matches the `.cube`
    /// file format AND `CIColorCube`: blue is the slowest-varying axis,
    /// red the fastest — entry index = ((b * D) + g) * D + r.
    var rgb: [Float]

    func entry(r: Int, g: Int, b: Int) -> (Float, Float, Float) {
        let base = ((b * dimension + g) * dimension + r) * 3
        return (rgb[base], rgb[base + 1], rgb[base + 2])
    }
}

/// Robust `.cube` parser.
///
/// Supported keywords: TITLE, LUT_3D_SIZE, LUT_1D_SIZE, DOMAIN_MIN,
/// DOMAIN_MAX, LUT_1D_INPUT_RANGE / LUT_3D_INPUT_RANGE (accepted, values not
/// needed for the bake), and `#` comments anywhere.
///
/// The tricky part: a file may contain a 1D LUT, a 3D LUT, or BOTH (the 1D
/// section comes first in the data). CIColorCube only accepts a 3D cube, so
/// when a 1D section exists we BAKE it into the 3D cube: each lattice point
/// of the output cube is first pushed through the 1D LUT (per channel), and
/// the result is used as the sampling coordinate into the 3D LUT (trilinear
/// interpolation). For a 1D-only file the output cube (dimension 64) is just
/// the 1D curve applied per channel. DOMAIN_MIN/MAX are honored during the
/// bake by converting normalized coordinates into the declared domain before
/// indexing — with the default 0...1 domain this is an identity mapping.
enum LUTParser {

    static func parse(data: Data) throws -> ParsedLUT {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LUTParseError.emptyFile
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> ParsedLUT {
        var title: String?
        var size3D: Int?
        var size1D: Int?
        var domainMin: (Float, Float, Float) = (0, 0, 0)
        var domainMax: (Float, Float, Float) = (1, 1, 1)
        var numbers: [Float] = []
        numbers.reserveCapacity(200_000)

        for rawLine in text.components(separatedBy: .newlines) {
            // Strip comments: everything from '#' to end of line.
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = tokens.first else { continue }
            let keyword = head.uppercased()

            switch keyword {
            case "TITLE":
                // Title is the rest of the line, optionally quoted.
                let rest = line.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
                title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard tokens.count >= 2, let v = Int(tokens[1]), v >= 2, v <= 256 else {
                    throw LUTParseError.invalidSize(tokens.count >= 2 ? tokens[1] : "")
                }
                size3D = v
            case "LUT_1D_SIZE":
                guard tokens.count >= 2, let v = Int(tokens[1]), v >= 2, v <= 65536 else {
                    throw LUTParseError.invalidSize(tokens.count >= 2 ? tokens[1] : "")
                }
                size1D = v
            case "DOMAIN_MIN":
                if tokens.count >= 4, let r = Float(tokens[1]), let g = Float(tokens[2]), let b = Float(tokens[3]) {
                    domainMin = (r, g, b)
                }
            case "DOMAIN_MAX":
                if tokens.count >= 4, let r = Float(tokens[1]), let g = Float(tokens[2]), let b = Float(tokens[3]) {
                    domainMax = (r, g, b)
                }
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                break // accepted; the bake below only needs DOMAIN_MIN/MAX
            default:
                if keyword.hasPrefix("LUT_") || keyword.hasPrefix("DOMAIN") {
                    break // unknown LUT-related keyword: ignore, stay robust
                }
                // Anything else must be numeric data.
                for token in tokens {
                    guard let value = Float(token) else {
                        throw LUTParseError.invalidNumber(token)
                    }
                    numbers.append(value)
                }
            }
        }

        if size3D == nil && size1D == nil && numbers.isEmpty && title == nil {
            throw LUTParseError.emptyFile
        }
        guard size3D != nil || size1D != nil else { throw LUTParseError.missingSize }

        let count1D = (size1D ?? 0) * 3
        let count3D = (size3D ?? 0) * (size3D ?? 0) * (size3D ?? 0) * 3
        let expected = count1D + count3D
        guard numbers.count >= expected else {
            throw LUTParseError.notEnoughData(expected: expected, got: numbers.count)
        }

        let table1D: [Float]? = size1D != nil ? Array(numbers[0..<count1D]) : nil
        let table3D: [Float]? = size3D != nil ? Array(numbers[count1D..<(count1D + count3D)]) : nil

        // Fast path: pure 3D LUT with a default domain needs no baking at all.
        if let d = size3D, table1D == nil, domainMin == (0, 0, 0), domainMax == (1, 1, 1), let cube = table3D {
            return ParsedLUT(title: title, dimension: d, rgb: cube)
        }

        // General path: bake 1D + domain mapping into a single cube.
        let outDimension = size3D ?? 64
        var out = [Float](repeating: 0, count: outDimension * outDimension * outDimension * 3)
        let denom = Float(outDimension - 1)

        func sample1D(_ table: [Float], size: Int, channel: Int, at position: Float) -> Float {
            let scaled = min(max(position, 0), 1) * Float(size - 1)
            let i0 = Int(scaled)
            let i1 = min(i0 + 1, size - 1)
            let frac = scaled - Float(i0)
            let a = table[i0 * 3 + channel]
            let b = table[i1 * 3 + channel]
            return a + (b - a) * frac
        }

        func sample3D(_ table: [Float], size: Int, r: Float, g: Float, b: Float) -> (Float, Float, Float) {
            // Trilinear interpolation over the parsed cube.
            let d = Float(size - 1)
            let x = min(max(r, 0), 1) * d, y = min(max(g, 0), 1) * d, z = min(max(b, 0), 1) * d
            let x0 = Int(x), y0 = Int(y), z0 = Int(z)
            let x1 = min(x0 + 1, size - 1), y1 = min(y0 + 1, size - 1), z1 = min(z0 + 1, size - 1)
            let fx = x - Float(x0), fy = y - Float(y0), fz = z - Float(z0)
            func at(_ rr: Int, _ gg: Int, _ bb: Int, _ ch: Int) -> Float {
                table[((bb * size + gg) * size + rr) * 3 + ch]
            }
            var result: (Float, Float, Float) = (0, 0, 0)
            for ch in 0..<3 {
                let c00 = at(x0, y0, z0, ch) + (at(x1, y0, z0, ch) - at(x0, y0, z0, ch)) * fx
                let c10 = at(x0, y1, z0, ch) + (at(x1, y1, z0, ch) - at(x0, y1, z0, ch)) * fx
                let c01 = at(x0, y0, z1, ch) + (at(x1, y0, z1, ch) - at(x0, y0, z1, ch)) * fx
                let c11 = at(x0, y1, z1, ch) + (at(x1, y1, z1, ch) - at(x0, y1, z1, ch)) * fx
                let c0 = c00 + (c10 - c00) * fy
                let c1 = c01 + (c11 - c01) * fy
                let v = c0 + (c1 - c0) * fz
                if ch == 0 { result.0 = v } else if ch == 1 { result.1 = v } else { result.2 = v }
            }
            return result
        }

        // Convert a normalized pipeline coordinate (0...1) into a table index
        // position, honoring DOMAIN_MIN/DOMAIN_MAX. The pipeline feeds values
        // in 0...1; the table position is (value - min) / (max - min).
        func domainPosition(_ value: Float, channel: Int) -> Float {
            let lo = channel == 0 ? domainMin.0 : (channel == 1 ? domainMin.1 : domainMin.2)
            let hi = channel == 0 ? domainMax.0 : (channel == 1 ? domainMax.1 : domainMax.2)
            guard hi > lo else { return value }
            return min(max((value - lo) / (hi - lo), 0), 1)
        }

        for b in 0..<outDimension {
            for g in 0..<outDimension {
                for r in 0..<outDimension {
                    var pr = Float(r) / denom
                    var pg = Float(g) / denom
                    var pb = Float(b) / denom
                    // Step 1: input-side 1D LUT (per channel), if present.
                    // With no 1D section, the domain mapping still applies
                    // before the 3D lookup.
                    if let table = table1D, let size = size1D {
                        pr = sample1D(table, size: size, channel: 0, at: domainPosition(pr, channel: 0))
                        pg = sample1D(table, size: size, channel: 1, at: domainPosition(pg, channel: 1))
                        pb = sample1D(table, size: size, channel: 2, at: domainPosition(pb, channel: 2))
                    } else {
                        pr = domainPosition(pr, channel: 0)
                        pg = domainPosition(pg, channel: 1)
                        pb = domainPosition(pb, channel: 2)
                    }
                    // Step 2: 3D lookup, or the 1D result IS the output.
                    let base = ((b * outDimension + g) * outDimension + r) * 3
                    if let table = table3D, let size = size3D {
                        let v = sample3D(table, size: size, r: pr, g: pg, b: pb)
                        out[base] = v.0; out[base + 1] = v.1; out[base + 2] = v.2
                    } else {
                        out[base] = pr; out[base + 1] = pg; out[base + 2] = pb
                    }
                }
            }
        }
        return ParsedLUT(title: title, dimension: outDimension, rgb: out)
    }
}
