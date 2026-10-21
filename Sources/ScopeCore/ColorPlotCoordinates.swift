import Foundation

/// A labelled plotting range, not a color or gamut constraint.
public struct ColorPlotAxis: Equatable, Sendable {
    public let label: String
    public let minimum: Double
    public let maximum: Double
    public init(label: String, minimum: Double, maximum: Double) {
        self.label = label; self.minimum = minimum; self.maximum = maximum
    }
    /// Intentionally unclamped: out-of-range samples stay outside the box.
    public func normalized(_ value: Double) -> Double? {
        guard value.isFinite, minimum.isFinite, maximum.isFinite, maximum > minimum else { return nil }
        let result = (value - minimum) / (maximum - minimum)
        return result.isFinite ? result : nil
    }
}

public enum CIEPlotMode: String, Codable, CaseIterable, Sendable {
    case xy1931 = "CIE 1931 xy"
    case uv1976 = "CIE 1976 u′v′"

    public var xAxis: ColorPlotAxis {
        self == .xy1931 ? ColorPlotAxis(label: "x", minimum: 0, maximum: 0.8)
                        : ColorPlotAxis(label: "u′", minimum: 0, maximum: 0.7)
    }
    public var yAxis: ColorPlotAxis {
        self == .xy1931 ? ColorPlotAxis(label: "y", minimum: 0, maximum: 0.9)
                        : ColorPlotAxis(label: "v′", minimum: 0, maximum: 0.7)
    }
    /// Transforms both trace samples and xy-authored gamut/white/locus overlays.
    /// xy=(0,0) is a valid chromaticity transform; it does NOT denote black.
    public func coordinates(fromXY xy: SIMD2<Double>) -> SIMD2<Double>? {
        guard colorPlotFinite(xy) else { return nil }
        return self == .xy1931 ? xy : ColorPlotCoordinates.uv1976(fromXY: xy)
    }
    public func coordinates(fromXYZ xyz: SIMD3<Double>) -> SIMD2<Double>? {
        self == .xy1931 ? ColorPlotCoordinates.xy(fromXYZ: xyz) : ColorPlotCoordinates.uv1976(fromXYZ: xyz)
    }
    /// RGB must already have signal levels expanded, as for ColorMath.xyz.
    public func coordinates(encodedRGB rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD2<Double>? {
        guard let xyz = ColorPlotCoordinates.xyz(encodedRGB: rgb, space: space, transfer: transfer) else { return nil }
        return coordinates(fromXYZ: xyz)
    }
    /// Normalized axes increase right/up; raster Y inversion belongs to the UI.
    public func normalizedCoordinates(fromXY xy: SIMD2<Double>) -> SIMD2<Double>? {
        guard let p = coordinates(fromXY: xy) else { return nil }; return normalizedCoordinates(p)
    }
    public func normalizedCoordinates(_ coordinates: SIMD2<Double>) -> SIMD2<Double>? {
        guard let x = xAxis.normalized(coordinates.x), let y = yAxis.normalized(coordinates.y) else { return nil }
        return SIMD2(x, y)
    }
}

public enum CubeColorModel: String, Codable, CaseIterable, Sendable {
    case encodedRGB = "Encoded RGB"
    case xyz = "CIE XYZ (D65)"
    case lab = "CIELAB (D65)"
    case chl = "CHL (D65)"
    case hsv = "HSV"

    /// Physical component order: RGB, XYZ, L*a*b*, C*h°L*, or H°SV.
    /// Cylindrical models are converted to Cartesian display coordinates by
    /// displayCoordinates; their hue component is NOT a linear display axis.
    public var physicalComponentLabels: [String] {
        switch self {
        case .encodedRGB: return ["R", "G", "B"]
        case .xyz: return ["X", "Y", "Z"]
        case .lab: return ["L*", "a*", "b*"]
        case .chl: return ["C*", "h°", "L*"]
        case .hsv: return ["H°", "S", "V"]
        }
    }
    public var isCylindrical: Bool { self == .chl || self == .hsv }
    /// Cartesian DISPLAY axes, not the cylindrical physical component order.
    /// XYZ is relative to Y=1 white (PQ's Y=1 is 10000 nits; HLG's is 1000).
    /// Lab ranges are view limits, not universal CIELAB extrema or a gamut.
    public var axes: [ColorPlotAxis] {
        switch self {
        case .encodedRGB:
            return ["R", "G", "B"].map { ColorPlotAxis(label: $0, minimum: 0, maximum: 1) }
        case .xyz:
            return [ColorPlotAxis(label: "X", minimum: 0, maximum: 1),
                    ColorPlotAxis(label: "Y", minimum: 0, maximum: 1),
                    ColorPlotAxis(label: "Z", minimum: 0, maximum: 1.2)]
        case .lab:
            return [ColorPlotAxis(label: "L*", minimum: 0, maximum: 100),
                    ColorPlotAxis(label: "a*", minimum: -200, maximum: 200),
                    ColorPlotAxis(label: "b*", minimum: -200, maximum: 200)]
        case .chl:
            return [ColorPlotAxis(label: "C* cos h", minimum: -200, maximum: 200),
                    ColorPlotAxis(label: "L*", minimum: 0, maximum: 100),
                    ColorPlotAxis(label: "C* sin h", minimum: -200, maximum: 200)]
        case .hsv:
            return [ColorPlotAxis(label: "S cos H", minimum: -1, maximum: 1),
                    ColorPlotAxis(label: "V", minimum: 0, maximum: 1),
                    ColorPlotAxis(label: "S sin H", minimum: -1, maximum: 1)]
        }
    }
    /// Levels must already be expanded. XYZ/Lab/CHL explicitly use Bradford
    /// adaptation from the selected native white to D65; RGB/HSV stay encoded.
    public func physicalCoordinates(encodedRGB rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD3<Double>? {
        guard colorPlotFinite(rgb) else { return nil }
        if self == .encodedRGB { return rgb }
        if self == .hsv {
            // Preserve the existing HSV policy: negative encoded components
            // clamp to zero, HDR V remains above one, hue is zero for neutrals.
            let hsv = ColorMath.hsv(rgb)
            let result = SIMD3(hsv.x*360, hsv.y, hsv.z)
            return colorPlotFinite(result) ? result : nil
        }
        let xyz = ColorMath.xyzD65(rgb, space: space, transfer: transfer)
        guard colorPlotFinite(xyz) else { return nil }
        if self == .xyz { return xyz }
        guard let lab = ColorPlotCoordinates.labD65(xyz: xyz) else { return nil }
        return self == .lab ? lab : ColorPlotCoordinates.chl(lab: lab)
    }
    public func normalizedCoordinates(encodedRGB rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD3<Double>? {
        guard let physical = physicalCoordinates(encodedRGB: rgb, space: space, transfer: transfer) else { return nil }
        return normalizedCoordinates(physical)
    }
    /// Only a plotting transform. Values outside 0...1 are retained, never clipped.
    public func normalizedCoordinates(_ physical: SIMD3<Double>) -> SIMD3<Double>? {
        guard let cartesian = displayCoordinates(physical) else { return nil }
        let a = axes
        guard let x = a[0].normalized(cartesian.x), let y = a[1].normalized(cartesian.y), let z = a[2].normalized(cartesian.z) else { return nil }
        return SIMD3(x, y, z)
    }
    /// CHL -> (C*cos h,L*,C*sin h), HSV -> (S*cos H,V,S*sin H).
    /// Hue zero points along +X and increasing hue rotates toward +Z.
    /// Other models retain their original Cartesian order. No clipping occurs.
    public func displayCoordinates(_ physical: SIMD3<Double>) -> SIMD3<Double>? {
        guard colorPlotFinite(physical) else { return nil }
        if !isCylindrical { return physical }
        let radius = self == .chl ? physical.x : physical.y
        let degrees = self == .chl ? physical.y : physical.x
        let angle = degrees.truncatingRemainder(dividingBy: 360) * .pi/180
        let result = SIMD3(radius*cos(angle), physical.z, radius*sin(angle))
        return colorPlotFinite(result) ? result : nil
    }
}

/// Original coordinate transforms using published CIE definitions, not a claim
/// of numerical equivalence with a third-party scope implementation.
public enum ColorPlotCoordinates {
    /// CIELAB polar coordinates in C*, h° (0...360), L* order, with h=0 on
    /// the achromatic axis. D65/D50 choice belongs to the supplied Lab values.
    public static func chl(lab: SIMD3<Double>) -> SIMD3<Double>? {
        guard colorPlotFinite(lab) else { return nil }
        let chroma = hypot(lab.y, lab.z)
        var hue = chroma == 0 ? 0 : atan2(lab.z, lab.y)*180 / .pi
        if hue < 0 { hue += 360 }
        let result = SIMD3(chroma, hue, lab.x)
        return colorPlotFinite(result) ? result : nil
    }
    /// D65/2° white chromaticity x=.3127,y=.3290, scaled to Yn=1. Matches the
    /// existing D65 RGB matrices within their rounded coefficient precision.
    /// This is not ICC PCS D50; no Bradford or other adaptation is performed.
    public static let whiteD65 = SIMD3<Double>(0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)

    /// Existing ColorMath.xyz input semantics are deliberately unchanged:
    /// ordinary gamma/sRGB negatives clamp; linear/ROMM/ACES retain their
    /// defined negative branches; SDR/linear can exceed one;
    /// PQ/HLG clamp codes at one; HLG uses the shared luminance OOTF gain.
    /// Nonfinite input/output is rejected rather than repaired into a color.
    /// Callers expand video levels before calling. PQ XYZ is relative to
    /// 10000 nits, HLG to 1000 nits, SDR/linear to the existing reference scale.
    /// ACES scene units use that scale conventionally; no RRT/ODT is applied.
    /// XYZ here retains the source native white for CIE plotting.
    public static func xyz(encodedRGB rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD3<Double>? {
        guard colorPlotFinite(rgb) else { return nil }
        let xyz = ColorMath.xyz(rgb, space: space, transfer: transfer)
        return colorPlotFinite(xyz) ? xyz : nil
    }

    public static func xy(fromXYZ xyz: SIMD3<Double>) -> SIMD2<Double>? {
        guard let s = scaledXYZ(xyz) else { return nil }
        let denominator = s.x + s.y + s.z
        guard denominator != 0 else { return nil }
        let result = SIMD2(s.x / denominator, s.y / denominator)
        return colorPlotFinite(result) ? result : nil
    }

    /// CIE 1976 u′=4X/(X+15Y+3Z), v′=9Y/(X+15Y+3Z). Scaling the
    /// homogeneous XYZ first avoids overflow and preserves dim chromaticity.
    /// Black and undefined denominators return nil, never an invented white.
    public static func uv1976(fromXYZ xyz: SIMD3<Double>) -> SIMD2<Double>? {
        guard let s = scaledXYZ(xyz) else { return nil }
        let denominator = s.x + 15*s.y + 3*s.z
        guard denominator != 0 else { return nil }
        let result = SIMD2(4*s.x / denominator, 9*s.y / denominator)
        return colorPlotFinite(result) ? result : nil
    }

    public static func uv1976(fromXY xy: SIMD2<Double>) -> SIMD2<Double>? {
        guard colorPlotFinite(xy) else { return nil }
        // Homogeneous scale includes the constant 3, avoiding 12*y overflow.
        let scale = max(1, max(abs(xy.x), abs(xy.y)))
        let x = xy.x / scale, y = xy.y / scale
        let denominator = -2*x + 12*y + 3/scale
        guard denominator != 0 else { return nil }
        let result = SIMD2(4*x / denominator, 9*y / denominator)
        return colorPlotFinite(result) ? result : nil
    }

    /// Raw XYZ -> CIELAB with D65 Yn=1. Negative/HDR finite XYZ is not clipped:
    /// the CIE linear branch extends below zero, and L* may exceed 100.
    /// https://cie.co.at/eilvterm/17-23-076
    public static func labD65(xyz: SIMD3<Double>) -> SIMD3<Double>? {
        guard colorPlotFinite(xyz) else { return nil }
        let ratios = xyz / whiteD65
        guard colorPlotFinite(ratios) else { return nil }
        func f(_ t: Double) -> Double {
            t > 216.0/24389 ? cbrt(t) : (841.0/108)*t + 4.0/29
        }
        let fx = f(ratios.x), fy = f(ratios.y), fz = f(ratios.z)
        let result = SIMD3(116*fy - 16, 500*(fx - fy), 200*(fy - fz))
        return colorPlotFinite(result) ? result : nil
    }

    private static func scaledXYZ(_ xyz: SIMD3<Double>) -> SIMD3<Double>? {
        guard colorPlotFinite(xyz) else { return nil }
        let scale = max(abs(xyz.x), max(abs(xyz.y), abs(xyz.z)))
        guard scale > 0 else { return nil }
        return xyz / scale
    }
}

private func colorPlotFinite(_ value: SIMD2<Double>) -> Bool { value.x.isFinite && value.y.isFinite }
private func colorPlotFinite(_ value: SIMD3<Double>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
