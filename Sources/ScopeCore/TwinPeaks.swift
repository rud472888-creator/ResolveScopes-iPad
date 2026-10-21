import Foundation

public enum TwinPeaksMode: String, Codable, CaseIterable, Sendable {
    case rgb = "RGB"
    case yCbCr = "YCbCr component"
    public var leftLabel: String { self == .rgb ? "R / G" : "Cb+0.5 / Y′" }
    public var rightLabel: String { self == .rgb ? "B / G" : "Cr+0.5 / Y′" }
}

/// Separate settings preserve legacy AdvancedScopeSettings decoding unchanged.
public struct TwinPeaksSettings: Codable, Equatable, Sendable {
    public var mode: TwinPeaksMode = .rgb
    public init(mode: TwinPeaksMode = .rgb) { self.mode = mode }
    private enum CodingKeys: String, CodingKey { case mode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(TwinPeaksMode.self, forKey: .mode) ?? .rgb
    }
}

public struct TwinPeaksCoordinates: Equatable, Sendable {
    /// Plot normalized x right, y UP. Excursions remain unclamped.
    public let left: SIMD2<Double>
    public let right: SIMD2<Double>
    public var outsidePlot: Bool {
        [left.x,left.y,right.x,right.y].contains { $0 < 0 || $0 > 1 }
    }
}

/// Original explicitly defined component diamonds, not undisclosed vendor math.
/// RGB retains historical R/G and B/G projection exactly. YCbCr rotates the
/// reference unit boxes (Cb+.5,Y′) and (Cr+.5,Y′) by the same sum/difference map.
/// Its diamond tests COMPONENT limits Y′=0...1 and Cb/Cr=−.5....5 together;
/// these are not equivalent to RGB-gamut legality or broadcast certification.
public enum TwinPeaks {
    public static let boundaries: [[SIMD2<Double>]] = [
        [SIMD2(0.25,0.1),SIMD2(0.05,0.5),SIMD2(0.25,0.9),SIMD2(0.45,0.5)],
        [SIMD2(0.75,0.1),SIMD2(0.55,0.5),SIMD2(0.75,0.9),SIMD2(0.95,0.5)]
    ]
    /// Already levels-expanded encoded RGB. No transfer/EOTF is applied.
    public static func coordinates(normalizedRGB rgb: SIMD3<Double>, space: ColorSpace = .rec709, mode: TwinPeaksMode = .rgb) -> TwinPeaksCoordinates? {
        guard finite(rgb) else { return nil }
        let first: Double, second: Double, shared: Double
        switch mode {
        case .rgb: first = rgb.x; second = rgb.z; shared = rgb.y
        case .yCbCr:
            let chroma = ColorMath.chroma(rgb, space: space)
            first = chroma.x + 0.5; second = chroma.y + 0.5
            shared = ColorMath.luma(rgb, space: space)
        }
        let result = TwinPeaksCoordinates(left: pair(first, shared, center: 0.25), right: pair(second, shared, center: 0.75))
        guard finite(result.left), finite(result.right) else { return nil }
        return result
    }
    /// Raw encoded RGB; video levels are expanded exactly once.
    public static func project(encodedRGB rgb: SIMD3<Double>, settings: ScopeSettings = ScopeSettings(), twinPeaks: TwinPeaksSettings = TwinPeaksSettings()) -> TwinPeaksCoordinates? {
        guard finite(rgb) else { return nil }
        let expanded = SIMD3(ColorMath.normalize(rgb.x, levels: settings.levels),ColorMath.normalize(rgb.y, levels: settings.levels),ColorMath.normalize(rgb.z, levels: settings.levels))
        return coordinates(normalizedRGB: expanded, space: settings.colorSpace, mode: twinPeaks.mode)
    }
    /// Inverse of the diamond map. First is R/B or Cb+.5/Cr+.5; second is
    /// G or Y′. This makes reference-corner interpretation explicit to clients.
    public static func components(at position: SIMD2<Double>, right: Bool = false) -> SIMD2<Double>? {
        guard finite(position) else { return nil }
        let difference = (position.x - (right ? 0.75 : 0.25))/0.2
        let sum = (position.y - 0.1)/0.4
        let result = SIMD2((sum+difference)/2, (sum-difference)/2)
        return finite(result) ? result : nil
    }
    /// Reference-box membership, not a full RGB gamut/compliance verdict.
    public static func isWithinReference(_ position: SIMD2<Double>, right: Bool = false, tolerance: Double = 1e-12) -> Bool {
        guard let pair = components(at: position, right: right) else { return false }
        let t = tolerance.isFinite ? min(1,max(0,tolerance)) : 0
        return pair.x >= -t && pair.x <= 1+t && pair.y >= -t && pair.y <= 1+t
    }
    private static func pair(_ first: Double, _ second: Double, center: Double) -> SIMD2<Double> {
        SIMD2(center+0.2*(first-second), 0.1+0.4*(first+second))
    }
    private static func finite(_ value: SIMD3<Double>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
    private static func finite(_ value: SIMD2<Double>) -> Bool { value.x.isFinite && value.y.isFinite }
}
