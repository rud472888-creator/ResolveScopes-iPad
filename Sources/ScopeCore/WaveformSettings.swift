import Foundation

public enum WaveformMode:String,Codable,CaseIterable,Sendable {
    case luma="Luma",rgbOverlay="RGB Overlay",yrgbOverlay="YRGB Overlay",rgbParade="RGB Parade",yrgbParade="YRGB Parade",yCbCrParade="YCbCr Parade"
    public var channels:[String] {
        switch self { case .luma:return ["Y′"];case .rgbOverlay,.rgbParade:return ["R","G","B"];case .yrgbParade,.yrgbOverlay:return ["Y′","R","G","B"];case .yCbCrParade:return ["Y′","Cb","Cr"] }
    }
    public var isParade:Bool { self == .rgbParade || self == .yrgbParade || self == .yCbCrParade }
}
public enum WaveformScale:String,Codable,CaseIterable,Sendable {
    case ire="IRE",percentage="%",code8="8-bit",code10="10-bit",pq="PQ · nits",hlg="HLG · nits",millivolts="mV"
    public var isHDR:Bool { self == .pq || self == .hlg }
}
public struct WaveformTick:Equatable,Sendable {
    public let signal:Double
    public let value:Double
    public let label:String
}
public struct WaveformPeak:Sendable {
    public let channel:String
    public let minimum:Double?
    public let maximum:Double?
}
/// Signal geometry is independent of label units. HDR scale overrides use the
/// inverse neutral-axis EOTF to locate a chosen mastering luminance in code space.
/// Cb/Cr lanes remain encoded, shifted by 0.5; their axis uses IRE, never nits.
public struct WaveformSettings:Codable,Equatable,Sendable {
    public var mode:WaveformMode = .luma
    public var scale:WaveformScale = .ire
    public var redEnabled=true,greenEnabled=true,blueEnabled=true
    public var colorize=true
    public var showPeaks=false
    public var showLegal=false
    public var minimumIRE:Double=0
    public var maximumIRE:Double=100
    public var masteringNits:Double=1000
    public var targetsIRE:[Double]=[]
    public var targetStyles:[WaveformTargetStyle]=[]
    /// EBU R103 v3 Annex 1 FIR, progressive received-raster RGB only.
    public var signalLowPass=false
    /// Horizontal plot-density box radius in raster pixels, bounded to 0...20.
    public var traceLowPassRadius:Double=0
    /// Spatial [1,2,1] density smoothing; no history/temporal filtering.
    public var smoothTrace=false
    public var enhanceEdges=false
    public var trueRGBColors=false
    /// Connect adjacent admitted samples of the SAME source row/channel only.
    public var enhancedRender=false
    /// Outline per-channel trace-density boundaries, not source-image edges.
    public var highlightEdges=false
    public var edgeThickness:Double=1
    public var edgeColor=FalseColorRGBA(red:1,green:0,blue:0)
    public init() {}
    public var effective:WaveformSettings {
        var s=self
        s.traceLowPassRadius=traceLowPassRadius.isFinite ? min(20,max(0,traceLowPassRadius)):0
        s.edgeThickness=edgeThickness.isFinite ? min(3,max(0.5,edgeThickness)):1
        s.edgeColor=edgeColor.isValid ? edgeColor:FalseColorRGBA(red:1,green:0,blue:0)
        return s
    }
    private enum CodingKeys:String,CodingKey {
        case mode,scale,redEnabled,greenEnabled,blueEnabled,colorize,showPeaks,showLegal
        case minimumIRE,maximumIRE,masteringNits,targetsIRE,targetStyles,signalLowPass
        case traceLowPassRadius,smoothTrace,enhanceEdges,trueRGBColors,enhancedRender
        case highlightEdges,edgeThickness,edgeColor
    }
    public init(from decoder:Decoder)throws {
        self.init()
        let c=try decoder.container(keyedBy:CodingKeys.self)
        mode=try c.decodeIfPresent(WaveformMode.self,forKey:.mode) ?? .luma
        scale=try c.decodeIfPresent(WaveformScale.self,forKey:.scale) ?? .ire
        redEnabled=try c.decodeIfPresent(Bool.self,forKey:.redEnabled) ?? true
        greenEnabled=try c.decodeIfPresent(Bool.self,forKey:.greenEnabled) ?? true
        blueEnabled=try c.decodeIfPresent(Bool.self,forKey:.blueEnabled) ?? true
        colorize=try c.decodeIfPresent(Bool.self,forKey:.colorize) ?? true
        showPeaks=try c.decodeIfPresent(Bool.self,forKey:.showPeaks) ?? false
        showLegal=try c.decodeIfPresent(Bool.self,forKey:.showLegal) ?? false
        minimumIRE=try c.decodeIfPresent(Double.self,forKey:.minimumIRE) ?? 0
        maximumIRE=try c.decodeIfPresent(Double.self,forKey:.maximumIRE) ?? 100
        masteringNits=try c.decodeIfPresent(Double.self,forKey:.masteringNits) ?? 1000
        targetsIRE=try c.decodeIfPresent([Double].self,forKey:.targetsIRE) ?? []
        targetStyles=try c.decodeIfPresent([WaveformTargetStyle].self,forKey:.targetStyles) ?? []
        signalLowPass=try c.decodeIfPresent(Bool.self,forKey:.signalLowPass) ?? false
        traceLowPassRadius=try c.decodeIfPresent(Double.self,forKey:.traceLowPassRadius) ?? 0
        smoothTrace=try c.decodeIfPresent(Bool.self,forKey:.smoothTrace) ?? false
        enhanceEdges=try c.decodeIfPresent(Bool.self,forKey:.enhanceEdges) ?? false
        trueRGBColors=try c.decodeIfPresent(Bool.self,forKey:.trueRGBColors) ?? false
        enhancedRender=try c.decodeIfPresent(Bool.self,forKey:.enhancedRender) ?? false
        highlightEdges=try c.decodeIfPresent(Bool.self,forKey:.highlightEdges) ?? false
        edgeThickness=try c.decodeIfPresent(Double.self,forKey:.edgeThickness) ?? 1
        edgeColor=try c.decodeIfPresent(FalseColorRGBA.self,forKey:.edgeColor) ?? FalseColorRGBA(red:1,green:0,blue:0)
    }
    public var effectiveScale:WaveformScale { mode == .yCbCrParade && scale.isHDR ? .ire:scale }
    public var signalBounds:ClosedRange<Double> {
        if effectiveScale.isHDR {
            let maximum=effectiveScale == .pq ? 10000.0:1000.0
            let nits=masteringNits.isFinite ? min(maximum,max(1,masteringNits)):maximum
            return 0...Self.signal(nits:nits,scale:effectiveScale)
        }
        let lo=minimumIRE.isFinite ? min(1000,max(-1000,minimumIRE))/100:0
        let hi=maximumIRE.isFinite ? min(1000,max(-1000,maximumIRE))/100:1
        return lo...max(lo+0.001,hi)
    }
    public func position(_ signal:Double)->Double { let b=signalBounds;return (signal-b.lowerBound)/(b.upperBound-b.lowerBound) }
    public func value(signal:Double,levels:SignalLevels)->Double {
        switch effectiveScale {
        case .ire,.percentage:return signal*100
        case .code8:return levels == .video ? 16+219*signal:255*signal
        case .code10:return levels == .video ? 64+876*signal:1023*signal
        case .pq:return ColorMath.linearize(signal,transfer:.pq)*10000
        case .hlg:return ColorMath.linearize(signal,transfer:.hlg)*1000
        case .millivolts:return signal*700
        }
    }
    public func label(signal:Double,levels:SignalLevels)->String {
        let v=value(signal:signal,levels:levels)
        guard v.isFinite else { return "—" }
        if effectiveScale.isHDR && v>0 && v<1 { return String(format:"%.1f",v) }
        return String(format:"%.0f",v)
    }
    public func ticks(levels:SignalLevels)->[WaveformTick] {
        if effectiveScale.isHDR {
            return [0,0.1,1,10,26,100,203,400,1000,2000,4000,10000].compactMap { value in
                let signal=Self.signal(nits:value,scale:effectiveScale)
                guard position(signal)<=1.00001 else { return nil }
                return WaveformTick(signal:signal,value:value,label:value>0 && value<1 ? "0.1":String(format:"%.0f",value))
            }
        }
        let b=signalBounds
        return (0...5).map { i in
            let signal=b.lowerBound+(b.upperBound-b.lowerBound)*Double(i)/5
            return WaveformTick(signal:signal,value:value(signal:signal,levels:levels),label:label(signal:signal,levels:levels))
        }
    }
    public static func signal(nits:Double,scale:WaveformScale)->Double {
        guard nits.isFinite else { return 0 }
        if scale == .pq {
            let l=min(1,max(0,nits/10000)),m1=2610.0/16384,m2=2523.0/32,c1=3424.0/4096,c2=2413.0/128,c3=2392.0/128
            let p=pow(l,m1);return pow((c1+c2*p)/(1+c3*p),m2)
        }
        if scale == .hlg {
            let scene=pow(min(1,max(0,nits/1000)),1/1.2),a=0.17883277,b=0.28466892,c=0.55991073
            return scene<=1/12.0 ? sqrt(3*scene):a*log(12*scene-b)+c
        }
        return nits/100
    }
    /// Values are in the same order as `mode.channels`, before plotting/clipping.
    public func components(rgb:SIMD3<Double>,space:ColorSpace)->[Double] {
        let values=sampleValues(rgb:rgb,space:space)
        return (0..<mode.channels.count).map { values[$0] }
    }
    public func sampleValues(rgb:SIMD3<Double>,space:ColorSpace)->SIMD4<Double> {
        switch mode {
        case .luma:return SIMD4(ColorMath.luma(rgb,space:space),0,0,0)
        case .rgbOverlay,.rgbParade:return SIMD4(rgb.x,rgb.y,rgb.z,0)
        case .yrgbParade,.yrgbOverlay:return SIMD4(ColorMath.luma(rgb,space:space),rgb.x,rgb.y,rgb.z)
        case .yCbCrParade:let c=ColorMath.chroma(rgb,space:space);return SIMD4(ColorMath.luma(rgb,space:space),c.x+0.5,c.y+0.5,0)
        }
    }
}
