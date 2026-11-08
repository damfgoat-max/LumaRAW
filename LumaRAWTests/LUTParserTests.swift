import XCTest
@testable import LumaRAW

final class LUTParserTests: XCTestCase {

    /// Builds an identity .cube string for a given 3D size.
    private func identityCubeText(size: Int) -> String {
        var lines = ["LUT_3D_SIZE \(size)"]
        let denom = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    lines.append("\(Float(r) / denom) \(Float(g) / denom) \(Float(b) / denom)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func testParseMinimal3D() throws {
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try LUTParser.parse(text)
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.rgb.count, 2 * 2 * 2 * 3)
        let entry = lut.entry(r: 1, g: 0, b: 0)
        XCTAssertEqual(entry.0, 1)
        XCTAssertEqual(entry.1, 0)
        XCTAssertEqual(entry.2, 0)
    }

    func testTitleAndComments() throws {
        let text = """
        # A comment line
        TITLE "My Test LUT" # trailing comment
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try LUTParser.parse(text)
        XCTAssertEqual(lut.title, "My Test LUT")
        XCTAssertEqual(lut.dimension, 2)
    }

    func testParse17Identity() throws {
        let lut = try LUTParser.parse(identityCubeText(size: 17))
        XCTAssertEqual(lut.dimension, 17)
        XCTAssertEqual(lut.rgb.count, 17 * 17 * 17 * 3)
        let mid = lut.entry(r: 8, g: 8, b: 8)
        XCTAssertEqual(mid.0, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid.1, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid.2, 0.5, accuracy: 0.001)
    }

    func testParse1DOnlyBakesToCube() throws {
        // 1D LUT that inverts each channel: 0->1, 1->0.
        let text = """
        LUT_1D_SIZE 2
        1 1 1
        0 0 0
        """
        let lut = try LUTParser.parse(text)
        XCTAssertEqual(lut.dimension, 64)
        // Lattice r=0 must invert to (nearly) 1 on the red channel.
        let atZero = lut.entry(r: 0, g: 63, b: 63)
        XCTAssertEqual(atZero.0, 1, accuracy: 0.001)
        XCTAssertEqual(atZero.1, 0, accuracy: 0.001)
        XCTAssertEqual(atZero.2, 0, accuracy: 0.001)
    }

    func testParseCombined1DAnd3D() throws {
        // Identity 1D followed by identity 3D = identity overall.
        var lines = ["LUT_1D_SIZE 2", "0 0 0", "1 1 1", "LUT_3D_SIZE 2"]
        let denom: Float = 1
        for b in 0..<2 {
            for g in 0..<2 {
                for r in 0..<2 {
                    lines.append("\(Float(r) / denom) \(Float(g) / denom) \(Float(b) / denom)")
                }
            }
        }
        let lut = try LUTParser.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(lut.dimension, 2)
        let entry = lut.entry(r: 1, g: 0, b: 1)
        XCTAssertEqual(entry.0, 1, accuracy: 0.001)
        XCTAssertEqual(entry.1, 0, accuracy: 0.001)
        XCTAssertEqual(entry.2, 1, accuracy: 0.001)
    }

    func testDomainMaxHonored() throws {
        // With DOMAIN_MAX 2, a normalized input of 1.0 lands halfway
        // through an identity table, so entry(1,0,0).r must be ~0.5.
        let text = "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n" + identityCubeText(size: 2)
        let lut = try LUTParser.parse(text)
        let entry = lut.entry(r: 1, g: 0, b: 0)
        XCTAssertEqual(entry.0, 0.5, accuracy: 0.001)
    }

    func testMissingSizeThrows() {
        XCTAssertThrowsError(try LUTParser.parse("0 0 0\n1 1 1")) { error in
            guard case LUTParseError.missingSize = error else {
                return XCTFail("Expected missingSize, got \(error)")
            }
        }
    }

    func testTruncatedDataThrows() {
        let text = "LUT_3D_SIZE 3\n0 0 0\n1 1 1\n"
        XCTAssertThrowsError(try LUTParser.parse(text)) { error in
            guard case LUTParseError.notEnoughData = error else {
                return XCTFail("Expected notEnoughData, got \(error)")
            }
        }
    }

    func testInvalidNumberThrows() {
        let text = "LUT_3D_SIZE 2\n0 0 nope\n"
        XCTAssertThrowsError(try LUTParser.parse(text)) { error in
            guard case LUTParseError.invalidNumber = error else {
                return XCTFail("Expected invalidNumber, got \(error)")
            }
        }
    }

    func testEmptyFileThrows() {
        XCTAssertThrowsError(try LUTParser.parse("   \n # only a comment\n")) { error in
            guard case LUTParseError.emptyFile = error else {
                return XCTFail("Expected emptyFile, got \(error)")
            }
        }
    }
}
