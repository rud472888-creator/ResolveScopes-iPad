import Foundation

public enum ColorQualifierMode: String, Codable, CaseIterable, Sendable {
    case rgb = "RGB", hsv = "HSV", hsl = "HSL"
}

/// Inclusive endpoints. Reversed endpoints are invalid except for hue, where
/// lower > upper crosses red/0 degrees. Equal hue endpoints select one hue;
/// 0...360 explicitly selects the whole circle, excluding undefined hues.
public struct ColorQualifierRange: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var lower: Double
    public var upper: Double
    public init(enabled: Bool = true, lower: Double = 0, upper: Double = 1) {
        self.enabled = enabled; self.lower = lower; self.upper = upper
    }
    fileprivate func valid(hue: Bool = false) -> Bool {
        !enabled || (lower.isFinite && upper.isFinite && (hue
            ? (0...360).contains(lower) && (0...360).contains(upper)
            : lower <= upper))
    }
    fileprivate func contains(_ value: Double, hue: Bool = false, epsilon: Double = 0) -> Bool {
        guard enabled else { return true }
        guard valid(hue:hue),value.isFinite else { return false }
        if !hue { return value >= lower-epsilon && value <= upper+epsilon }
        if lower == 0 && upper == 360 { return true }
        // 360 and 0 are the same endpoint, but preserve the interval direction.
        if lower <= upper {
            return (value >= lower && value <= upper) || (value == 0 && upper == 360)
        }
        return value >= lower || value <= upper || (value == 0 && lower == 360)
    }
}

/// Keying uses encoded, post-input-LUT RGB followed by exactly one levels
/// normalization. It does not apply EOTF, display brightness or another LUT.
/// RGB ranges retain negative and HDR values. HSV/HSL are standard SDR-cylinder
/// definitions on normalized RGB clipped to 0...1: H degrees, S/V/L 0...1.
/// Achromatic pixels have no hue; even a full hue interval does not admit them
/// unless hue is disabled or includeAchromatic is explicitly enabled.
/// Video-level RGB/Y′ range comparisons allow ±1e-7 normalized units for Float
/// code-value rounding. Full-level comparisons are strict. Signal values are
/// never rounded/clamped by this allowance, and hue/S/V/L policies are unchanged.
public struct ColorQualifierSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var invert = false
    public var mode: ColorQualifierMode = .rgb
    public var red = ColorQualifierRange()
    public var green = ColorQualifierRange()
    public var blue = ColorQualifierRange()
    public var hue = ColorQualifierRange(lower:0,upper:360)
    public var saturation = ColorQualifierRange()
    public var value = ColorQualifierRange()
    public var lightness = ColorQualifierRange()
    /// Independent histogram Y' range, ANDed with mode components before
    /// invert. Uses active color-space weights on unclamped encoded RGB.
    public var luma = ColorQualifierRange(enabled:false)
    public var includeAchromatic = false
    public init() {}

    /// Only components used by the selected mode participate in validation.
    /// Disabled components are ignored. Malformed active ranges fail closed,
    /// including under invert; they never turn an invalid key into select-all.
    public var isValid: Bool {
        guard luma.valid() else { return false }
        switch mode {
        case .rgb: return red.valid() && green.valid() && blue.valid()
        case .hsv: return hue.valid(hue:true) && saturation.valid() && value.valid()
        case .hsl: return hue.valid(hue:true) && saturation.valid() && lightness.valid()
        }
    }
}

public struct ColorQualifierResult: Sendable {
    /// Nil means no qualifier or existing mask was requested. An enabled key
    /// always returns a full-frame binary raster. Zero means exclusion, never a
    /// replacement black sample; pass this mask to scope measurement APIs.
    public let mask: ScopeSelectionMask?
    /// Exact full-resolution counts, not the later scope's sampled-grid count.
    /// Nil while disabled: no pixels were evaluated and the input mask passes
    /// through unchanged, so toggling the key off adds no ROI blackout.
    public let eligiblePixelCount: Int?
    public let selectedPixelCount: Int?
    /// Nonfinite RGB within ROI and the intersecting mask; alpha is not signal.
    public let invalidPixelCount: Int
    public let configurationValid: Bool
}

public enum ColorQualifier {
    /// Pass the encoded frame AFTER input LUT application. Existing skin or
    /// other masks are intersected before qualification. Invert affects only
    /// the color predicate, never ROI, the input mask, invalid values, or the
    /// explicit undefined-hue policy. Raw whole-frame QC must not use this mask.
    /// Work and storage are O(frame pixels); one byte per pixel is allocated.
    public static func makeMask(frame: VideoFrame, settings: ScopeSettings = .init(),
                                qualifier: ColorQualifierSettings,
                                intersecting: ScopeSelectionMask? = nil) -> ColorQualifierResult {
        guard qualifier.enabled else {
            return ColorQualifierResult(mask:intersecting,eligiblePixelCount:nil,selectedPixelCount:nil,
                                        invalidPixelCount:0,configurationValid:true)
        }
        let valid = qualifier.isValid
        let signalEpsilon = settings.levels == .video ? 1e-7 : 0
        guard frame.isValid else {
            return ColorQualifierResult(mask:ScopeSelectionMask(width:1,height:1,values:[0]),
                eligiblePixelCount:0,selectedPixelCount:0,invalidPixelCount:0,configurationValid:valid)
        }
        let roi = settings.roiGeometry.raster(width:frame.width,height:frame.height)
        var values = [UInt8](repeating:0,count:frame.width*frame.height)
        var eligible = 0, selected = 0, invalid = 0
        let bounds = roi.bounds
        if bounds.width > 0 && bounds.height > 0 {
            for y in bounds.y0..<bounds.y1 { for x in bounds.x0..<bounds.x1 {
                guard roi.contains(x:x,y:y),intersecting?.includes(x:x,y:y,frameWidth:frame.width,frameHeight:frame.height) ?? true else { continue }
                let offset = (y*frame.width+x)*4
                let rgb = SIMD3(ColorMath.normalize(Double(frame.rgba[offset]),levels:settings.levels),
                                ColorMath.normalize(Double(frame.rgba[offset+1]),levels:settings.levels),
                                ColorMath.normalize(Double(frame.rgba[offset+2]),levels:settings.levels))
                guard rgb.x.isFinite,rgb.y.isFinite,rgb.z.isFinite else { invalid += 1; continue }
                eligible += 1
                guard valid else { continue }
                let accepted: Bool
                switch qualifier.mode {
                case .rgb:
                    accepted = qualifier.red.contains(rgb.x,epsilon:signalEpsilon)
                        && qualifier.green.contains(rgb.y,epsilon:signalEpsilon)
                        && qualifier.blue.contains(rgb.z,epsilon:signalEpsilon)
                case .hsv, .hsl:
                    let c = components(normalizedRGB:rgb,mode:qualifier.mode)
                    guard !qualifier.hue.enabled || c.x.isFinite || qualifier.includeAchromatic else { continue }
                    let hueMatch = !c.x.isFinite ? qualifier.includeAchromatic || !qualifier.hue.enabled : qualifier.hue.contains(c.x,hue:true)
                    let third = qualifier.mode == .hsv ? qualifier.value : qualifier.lightness
                    accepted = hueMatch && qualifier.saturation.contains(c.y) && third.contains(c.z)
                }
                let matched = accepted && qualifier.luma.contains(ColorMath.luma(rgb,space:settings.colorSpace),epsilon:signalEpsilon)
                if qualifier.invert ? !matched : matched {
                    values[y*frame.width+x] = 255; selected += 1
                }
            }}
        }
        return ColorQualifierResult(mask:ScopeSelectionMask(width:frame.width,height:frame.height,values:values),
            eligiblePixelCount:eligible,selectedPixelCount:selected,invalidPixelCount:invalid,configurationValid:valid)
    }

    /// RGB passes through unchanged. HSV/HSL clip RGB to 0...1 and return
    /// H(degrees)/S/V or H/S/L. Hue is NaN for chroma <= 1e-12, explicitly
    /// separating undefined gray hues from red at zero degrees. Nonfinite input
    /// returns all NaNs and is always rejected by makeMask, including invert.
    public static func components(normalizedRGB rgb: SIMD3<Double>, mode: ColorQualifierMode) -> SIMD3<Double> {
        guard rgb.x.isFinite,rgb.y.isFinite,rgb.z.isFinite else { return SIMD3(repeating:.nan) }
        if mode == .rgb { return rgb }
        let r = min(1,max(0,rgb.x)), g = min(1,max(0,rgb.y)), b = min(1,max(0,rgb.z))
        let maximum = max(r,max(g,b)), minimum = min(r,min(g,b)), chroma = maximum-minimum
        let lightness = (maximum+minimum)/2
        guard chroma > 1e-12 else { return SIMD3(.nan,0,mode == .hsv ? maximum:lightness) }
        var hue: Double
        if maximum == r { hue = (g-b)/chroma; if hue < 0 { hue += 6 } }
        else if maximum == g { hue = (b-r)/chroma+2 }
        else { hue = (r-g)/chroma+4 }
        let saturation = mode == .hsv ? chroma/maximum : chroma/(1-abs(2*lightness-1))
        return SIMD3(hue*60,saturation,mode == .hsv ? maximum:lightness)
    }
}
