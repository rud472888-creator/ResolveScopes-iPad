import Foundation

public enum ColorMath {
    /// Expand code values only when the input contains unexpanded 10-bit legal range.
    /// Resolve normally supplies full-range normalized floats; leave levels at Full in that case.
    public static func normalize(_ value: Double, levels: SignalLevels) -> Double {
        levels == .full ? value : (value * 1023 - 64) / 876
    }
    public static func lumaWeights(_ space: ColorSpace) -> SIMD3<Double> {
        switch space {
        case .rec709: return SIMD3(0.2126, 0.7152, 0.0722)
        case .p3D65: return SIMD3(0.2289746, 0.6917385, 0.0792869)
        case .rec2020: return SIMD3(0.2627, 0.6780, 0.0593)
        default: return space.primaries.matrix.r1
        }
    }
    public static func luma(_ rgb: SIMD3<Double>, space: ColorSpace) -> Double {
        let w = lumaWeights(space); return rgb.x*w.x + rgb.y*w.y + rgb.z*w.z
    }
    /// Relative linear value; ACES inverses return scene-linear AP1 components.
    /// ACES uses the specified 65504 upper cap. Linear/ROMM/ACES preserve their
    /// defined negative branches; existing gamma/sRGB measurements clamp negatives.
    /// signedSDRExtension is for gamut inspection only. PQ returns nits / 10000.
    /// Scalar HLG is a neutral-axis convenience only; colored HLG must use
    /// displayLinearRGB so the OOTF gain is shared across all three channels.
    public static func linearize(_ value: Double, transfer: TransferFunction, signedSDRExtension: Bool = false) -> Double {
        guard value.isFinite else { return 0 }
        let v = max(value, 0)
        switch transfer {
        case .linear: return value
        case .gamma18, .gamma22, .gamma24, .gamma26, .adobeRGB:
            let gamma = transfer == .adobeRGB ? 563.0/256 : (transfer == .gamma18 ? 1.8 : (transfer == .gamma22 ? 2.2 : (transfer == .gamma26 ? 2.6 : 2.4)))
            return signedSDRExtension ? (value < 0 ? -1 : 1)*pow(abs(value),gamma) : pow(v,gamma)
        case .sRGB:
            let a = signedSDRExtension ? abs(value) : v
            let result = a <= 0.04045 ? a/12.92 : pow((a+0.055)/1.055,2.4)
            return signedSDRExtension && value < 0 ? -result : result
        case .proPhoto:
            // CSS Color 4 extended ROMM TRC, including the signed linear toe.
            return abs(value) <= 16.0/512 ? value/16 : (value < 0 ? -1 : 1)*pow(abs(value),1.8)
        case .acescc:
            if value >= (log2(65504.0)+9.72)/17.52 { return 65504 }
            let linear = exp2(value*17.52-9.72)
            return value <= (9.72-15)/17.52 ? (linear-exp2(-16))*2 : linear
        case .acescct:
            if value <= 0.155251141552511 { return (value-0.0729055341958355)/10.5402377416545 }
            if value >= (log2(65504.0)+9.72)/17.52 { return 65504 }
            return exp2(value*17.52-9.72)
        case .pq:
            let m1 = 2610.0/16384, m2 = 2523.0/32, c1 = 3424.0/4096, c2 = 2413.0/128, c3 = 2392.0/128
            let p = pow(min(v, 1), 1/m2)
            return pow(max(p-c1, 0) / max(c2-c3*p, 1e-12), 1/m1)
        case .hlg:
            return pow(hlgSceneLinear(v), 1.2)
        }
    }
    private static func hlgSceneLinear(_ value: Double) -> Double {
        let v = min(max(value,0),1)
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        return v <= 0.5 ? v*v/3 : (exp((v-c)/a)+b)/12
    }
    /// BT.2100 HLG: apply the OOTF's luminance-dependent gain identically to
    /// R, G and B. Applying display gamma independently would shift hue.
    public static func displayLinearRGB(_ rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD3<Double> {
        if transfer == .hlg {
            let scene = SIMD3(hlgSceneLinear(rgb.x),hlgSceneLinear(rgb.y),hlgSceneLinear(rgb.z))
            let gain = pow(max(luma(scene,space:space),0),0.2)
            return scene*gain
        }
        return SIMD3(linearize(rgb.x,transfer:transfer),linearize(rgb.y,transfer:transfer),linearize(rgb.z,transfer:transfer))
    }
    /// Explicit custom-luma variant for CIE custom primaries. Existing preset
    /// code above stays unchanged, including its historical rounded weights.
    /// HLG's gain is shared across channels using the supplied native Y row.
    public static func displayLinearRGB(_ rgb: SIMD3<Double>, lumaWeights: SIMD3<Double>, transfer: TransferFunction) -> SIMD3<Double>? {
        guard rgb.x.isFinite,rgb.y.isFinite,rgb.z.isFinite,lumaWeights.x.isFinite,lumaWeights.y.isFinite,lumaWeights.z.isFinite else { return nil }
        let result:SIMD3<Double>
        if transfer == .hlg {
            let scene=SIMD3(hlgSceneLinear(rgb.x),hlgSceneLinear(rgb.y),hlgSceneLinear(rgb.z))
            let y=scene.x*lumaWeights.x+scene.y*lumaWeights.y+scene.z*lumaWeights.z
            result=scene*pow(max(y,0),0.2)
        } else {
            result=SIMD3(linearize(rgb.x,transfer:transfer),linearize(rgb.y,transfer:transfer),linearize(rgb.z,transfer:transfer))
        }
        return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result:nil
    }
    /// SDR and scene-linear ACES use a conventional unit-white=100 scale here;
    /// scene exposure is not an absolute nit measurement or an ACES RRT/ODT.
    public static func luminanceNits(_ rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> Double {
        let linear = displayLinearRGB(rgb,space:space,transfer:transfer)
        let scale = transfer == .pq ? 10000.0 : (transfer == .hlg ? 1000.0 : 100.0)
        return luma(linear, space: space) * scale
    }
    public static func xyz(_ rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD3<Double> {
        let linear = displayLinearRGB(rgb,space:space,transfer:transfer)
        let r = linear.x, g = linear.y, b = linear.z
        switch space {
        case .rec709:
            return SIMD3(0.4123908*r+0.3575843*g+0.1804808*b, 0.2126390*r+0.7151687*g+0.0721923*b, 0.0193308*r+0.1191948*g+0.9505322*b)
        case .p3D65:
            return SIMD3(0.4865709*r+0.2656677*g+0.1982173*b, 0.2289746*r+0.6917385*g+0.0792869*b, 0.0451134*g+1.0439444*b)
        case .rec2020:
            return SIMD3(0.6369580*r+0.1446169*g+0.1688810*b, 0.2627002*r+0.6779981*g+0.0593017*b, 0.0280727*g+1.0609851*b)
        default: return space.primaries.matrix.applying(linear)
        }
    }
    /// Native XYZ is intentional for CIE chromaticity. D65 comparison models
    /// must explicitly request xyzD65 instead. Old D65 matrices retain their
    /// rounded coefficients to preserve existing trace geometry.
    public static func xyzD65(_ rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD3<Double> {
        RGBMatrix.d65Adaptations[space]!.applying(xyz(rgb,space:space,transfer:transfer))
    }
    /// Bradford reference-white adaptation, without gamut clipping. Invalid
    /// chromaticities return NaN, allowing callers to reject an undefined color.
    public static func adaptXYZ(_ xyz: SIMD3<Double>, fromWhite: SIMD2<Double>, toWhite: SIMD2<Double>) -> SIMD3<Double> {
        guard [fromWhite.x,fromWhite.y,toWhite.x,toWhite.y].allSatisfy({ $0.isFinite }), fromWhite.y > 0, toWhite.y > 0 else { return SIMD3(repeating:.nan) }
        return RGBMatrix.adaptation(from:fromWhite,to:toWhite).applying(xyz)
    }
    /// Native linear RGB -> Bradford-adapted target linear RGB. No EOTF,
    /// tone map, rendering transform, or level expansion is applied here.
    public static func convertLinearRGB(_ rgb: SIMD3<Double>, from: ColorSpace, to: ColorSpace) -> SIMD3<Double> {
        RGBMatrix.conversion(from:from,to:to).applying(rgb)
    }
    public static func xy(_ rgb: SIMD3<Double>, space: ColorSpace, transfer: TransferFunction) -> SIMD2<Double>? {
        let v = xyz(rgb, space: space, transfer: transfer), total = v.x+v.y+v.z
        guard total > 1e-12 && total.isFinite else { return nil }
        return SIMD2(v.x/total, v.y/total)
    }
    /// Normalized Cb/Cr, centered on zero and bounded by ±0.5 for legal RGB.
    public static func chroma(_ rgb: SIMD3<Double>, space: ColorSpace) -> SIMD2<Double> {
        let y = luma(rgb, space: space), w = lumaWeights(space)
        return SIMD2((rgb.z-y)/(2*(1-w.z)), (rgb.x-y)/(2*(1-w.x)))
    }
    public static func hsv(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let r = max(rgb.x, 0), g = max(rgb.y, 0), b = max(rgb.z, 0)
        let mx = max(r,max(g,b)), mn = min(r,min(g,b)), d = mx-mn
        guard d > 1e-12 else { return SIMD3(0,0,mx) }
        var h: Double
        if mx == r { h = (g-b)/d; if h < 0 { h += 6 } }
        else if mx == g { h = (b-r)/d+2 }
        else { h = (r-g)/d+4 }
        return SIMD3(h/6, mx > 0 ? d/mx : 0, mx)
    }
    public static func falseColor(_ ire: Double) -> SIMD3<UInt8> {
        // Original, published IRE bands; these are not vendor camera exposure presets.
        switch ire {
        case ..<0: return SIMD3(150,0,220)
        case 0..<3: return SIMD3(28,32,105)
        case 3..<10: return SIMD3(35,86,235)
        case 10..<38: return SIMD3(75,81,90)
        case 38..<42: return SIMD3(40,210,100)
        case 42..<52: return SIMD3(130,137,143)
        case 52..<56: return SIMD3(235,135,180)
        case 56..<95: return SIMD3(190,195,201)
        case 95..<100: return SIMD3(255,215,40)
        default: return SIMD3(255,48,40)
        }
    }
}
