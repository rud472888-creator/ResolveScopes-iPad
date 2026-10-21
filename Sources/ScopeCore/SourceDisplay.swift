import Foundation

public enum SourceDisplayChannel:String,Codable,CaseIterable,Sendable {
    case rgb="RGB",red="Red",green="Green",blue="Blue",luma="Luma"
}
public enum SourceZebraMode:String,Codable,CaseIterable,Sendable {
    case off="Off",luma="Y′ IRE",saturation="HSV saturation %"
}
public struct SourceDisplaySettings:Codable,Equatable,Sendable {
    public var channel:SourceDisplayChannel = .rgb
    /// Display-only multiplier, bounded to .25...4. Measurement input is unchanged.
    public var brightnessGain:Double=1
    /// Preview-only near-neutral chroma amplification. Source/scopes/QC are unchanged.
    public var chromaBoostEnabled=false
    public var chromaBoostAmount:Double=4
    public var zebraMode:SourceZebraMode = .off
    /// Inclusive Y′ IRE or HSV saturation percent, measured BEFORE display gain
    /// and channel selection. Extended IRE intervals (e.g.100...110) are allowed.
    public var zebraLower:Double=90
    public var zebraUpper:Double=100
    /// Width of each diagonal band in preview pixels; one period has two bands.
    public var zebraStripeWidth:Int=4
    public var zebraOpacity:Double=0.75
    public var focusOpacity:Double=0.85
    public init() {}
    public var isIdentity:Bool { channel == .rgb && brightnessGain == 1 && !chromaBoostEnabled && zebraMode == .off }
    private enum CodingKeys:String,CodingKey {
        case channel,brightnessGain,chromaBoostEnabled,chromaBoostAmount,zebraMode,zebraLower,zebraUpper,zebraStripeWidth,zebraOpacity,focusOpacity
    }
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        channel=try c.decodeIfPresent(SourceDisplayChannel.self,forKey:.channel) ?? .rgb
        brightnessGain=try c.decodeIfPresent(Double.self,forKey:.brightnessGain) ?? 1
        chromaBoostEnabled=try c.decodeIfPresent(Bool.self,forKey:.chromaBoostEnabled) ?? false
        chromaBoostAmount=try c.decodeIfPresent(Double.self,forKey:.chromaBoostAmount) ?? 4
        zebraMode=try c.decodeIfPresent(SourceZebraMode.self,forKey:.zebraMode) ?? .off
        zebraLower=try c.decodeIfPresent(Double.self,forKey:.zebraLower) ?? 90
        zebraUpper=try c.decodeIfPresent(Double.self,forKey:.zebraUpper) ?? 100
        zebraStripeWidth=try c.decodeIfPresent(Int.self,forKey:.zebraStripeWidth) ?? 4
        zebraOpacity=try c.decodeIfPresent(Double.self,forKey:.zebraOpacity) ?? 0.75
        focusOpacity=try c.decodeIfPresent(Double.self,forKey:.focusOpacity) ?? 0.85
    }
}

/// Encoded-signal preview utility. RGB is clipped for an opaque 8-bit raster;
/// ICC/OCIO conversion is external and may supply displayRGBFrame. This core
/// renderer is not HDR display matching, alpha compositing or a measurement transform.
/// R/G/B channels each render as a grayscale intensity; Luma renders encoded Y′.
public enum SourceDisplay {
    /// Independent inspection algorithm: amplify the RGB residual around encoded
    /// Y′ by 1 + amount*(1-S)^2. S is HSV saturation of clipped RGB. Exact neutrals
    /// and fully saturated colors stay fixed; luma is preserved before display
    /// clipping. This is not a reconstruction of the vendor's private formula.
    public static func chromaBoostedRGB(_ rgb:SIMD3<Double>,space:ColorSpace,amount:Double)->SIMD3<Double> {
        guard rgb.x.isFinite,rgb.y.isFinite,rgb.z.isFinite else { return rgb }
        let a=finiteClamp(amount,low:0,high:16,fallback:4)
        guard a>0,!(rgb.x == rgb.y && rgb.y == rgb.z) else { return rgb }
        let clipped=SIMD3(unit(rgb.x),unit(rgb.y),unit(rgb.z))
        let saturation=ColorMath.hsv(clipped).y
        guard saturation<1 else { return rgb }
        let y=ColorMath.luma(rgb,space:space)
        return SIMD3(repeating:y)+(rgb-SIMD3(repeating:y))*(1+a*pow(1-saturation,2))
    }
    /// An optional same-size displayRGBFrame contains already normalized/converted
    /// preview RGB. Zebra/luma/selection remain measured from the original signal.
    /// Order: levels once -> optional float display conversion -> chroma boost -> channel/gain -> zebra -> focus.
    /// Zebra thresholds always use the original normalized signal.
    /// An explicit selection mask excludes pixels to black. ScopeSettings.roi is
    /// an analysis region and does not crop the source preview. Focus masks use
    /// nearest cell mapping in source-image coordinates and are applied last.
    public static func render(frame:VideoFrame,settings:ScopeSettings=ScopeSettings(),display:SourceDisplaySettings=SourceDisplaySettings(),selectionMask:ScopeSelectionMask?=nil,focusMask:ScopeSelectionMask?=nil,displayRGBFrame:VideoFrame?=nil,displayColorSpace:ColorSpace?=nil)->ScopeBitmap {
        guard frame.isValid else { return ScopeBitmap(width:1,height:1,rgba:[0,0,0,255]) }
        let alternate=displayRGBFrame.flatMap { $0.isValid && $0.width == frame.width && $0.height == frame.height ? $0:nil }
        let scale=min(1,min(960/Double(frame.width),540/Double(frame.height)))
        let width=max(1,Int(floor(Double(frame.width)*scale))),height=max(1,Int(floor(Double(frame.height)*scale)))
        var output=[UInt8](repeating:0,count:width*height*4)
        let gain=finiteClamp(display.brightnessGain,low:0.25,high:4,fallback:1)
        let zebraOpacity=finiteClamp(display.zebraOpacity,low:0,high:1,fallback:0.75)
        let focusOpacity=finiteClamp(display.focusOpacity,low:0,high:1,fallback:0.85)
        let a=display.zebraLower.isFinite ? display.zebraLower:90,b=display.zebraUpper.isFinite ? display.zebraUpper:100
        let lower=min(a,b),upper=max(a,b),stripeWidth=max(1,min(32,display.zebraStripeWidth))
        for y in 0..<height { for x in 0..<width {
            let sx=min(frame.width-1,Int((Double(x)+0.5)*Double(frame.width)/Double(width)))
            let sy=min(frame.height-1,Int((Double(y)+0.5)*Double(frame.height)/Double(height)))
            let i=(sy*frame.width+sx)*4,o=(y*width+x)*4
            output[o+3]=255
            guard selectionMask?.includes(x:sx,y:sy,frameWidth:frame.width,frameHeight:frame.height) ?? true else { continue }
            let raw=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
            guard raw.x.isFinite,raw.y.isFinite,raw.z.isFinite else {
                output[o]=255;output[o+2]=255;continue
            }
            let rgb=SIMD3(ColorMath.normalize(raw.x,levels:settings.levels),ColorMath.normalize(raw.y,levels:settings.levels),ColorMath.normalize(raw.z,levels:settings.levels))
            let yPrime=ColorMath.luma(rgb,space:settings.colorSpace)
            let displayRGB=alternate.map { SIMD3(Double($0.rgba[i]),Double($0.rgba[i+1]),Double($0.rgba[i+2])) } ?? rgb
            guard displayRGB.x.isFinite,displayRGB.y.isFinite,displayRGB.z.isFinite else { output[o]=255;output[o+2]=255;continue }
            let previewRGB=display.chromaBoostEnabled ? chromaBoostedRGB(displayRGB,space:displayColorSpace ?? settings.colorSpace,amount:display.chromaBoostAmount):displayRGB
            var color:SIMD3<Double>
            switch display.channel {
            case .rgb:color=previewRGB
            case .red:color=SIMD3(repeating:previewRGB.x)
            case .green:color=SIMD3(repeating:previewRGB.y)
            case .blue:color=SIMD3(repeating:previewRGB.z)
            case .luma:color=SIMD3(repeating:yPrime)
            }
            color=SIMD3(unit(color.x*gain),unit(color.y*gain),unit(color.z*gain))
            if display.zebraMode != .off {
                let metric=display.zebraMode == .luma ? yPrime*100:ColorMath.hsv(rgb).y*100
                // Display-only Float32 boundary roundoff: 1e-5 IRE / percentage
                // points. Input values and all scope measurements stay untouched.
                if metric>=lower-1e-5 && metric<=upper+1e-5 {
                    let stripe:SIMD3<Double>=((x+y)/stripeWidth)%2 == 0 ? SIMD3(1,0.85,0):.zero
                    color=color*(1-zebraOpacity)+stripe*zebraOpacity
                }
            }
            if focusMask?.includes(x:sx,y:sy,frameWidth:frame.width,frameHeight:frame.height) ?? false {
                color=color*(1-focusOpacity)+SIMD3<Double>(0.1,1,0.2)*focusOpacity
            }
            output[o]=byte(color.x);output[o+1]=byte(color.y);output[o+2]=byte(color.z)
        }}
        return ScopeBitmap(width:width,height:height,rgba:output)
    }
    private static func finiteClamp(_ value:Double,low:Double,high:Double,fallback:Double)->Double { value.isFinite ? min(high,max(low,value)):fallback }
    private static func unit(_ value:Double)->Double { finiteClamp(value,low:0,high:1,fallback:0) }
    private static func byte(_ value:Double)->UInt8 { UInt8((unit(value)*255).rounded()) }
}
