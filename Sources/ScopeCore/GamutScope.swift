import Foundation

public enum GamutCheckMode: String, Codable, CaseIterable, Sendable {
    case chromaticity = "Chromaticity", colorVolume = "RGB color volume"
}
public struct GamutScopeSettings: Codable, Equatable, Sendable {
    public var targetColorSpace: ColorSpace = .p3D65
    /// Chromaticity checks the nonnegative RGB cone, with no brightness ceiling.
    /// Color volume additionally checks each target RGB component against peak nits.
    public var mode: GamutCheckMode = .chromaticity
    public var targetPeakNits: Double = 1000
    /// Optional independent CIE Y luminance ceiling; distinct from RGB volume.
    public var maxLuminanceNits: Double? = nil
    /// Minimum target RGB barycentric fraction near the chromaticity boundary.
    public var nearEdgeMargin: Double = 0.02
    /// Relative matrix-roundoff tolerance; never changes reported numeric levels.
    public var tolerance: Double = 1e-7
    public init() {}
}
public struct GamutPixelFlags: OptionSet, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue=rawValue }
    public static let invalid = GamutPixelFlags(rawValue:1)
    public static let outsideGamut = GamutPixelFlags(rawValue:2)
    public static let nearEdge = GamutPixelFlags(rawValue:4)
    public static let luminanceExceeded = GamutPixelFlags(rawValue:8)
    public static let signalRangeViolation = GamutPixelFlags(rawValue:16)
}
public struct GamutPixelResult: Sendable {
    /// Linear target RGB relative to the source transfer's reference white:
    /// SDR/linear=100 reference units, PQ=10000 nits, HLG=1000 nits.
    /// ACES scene-linear units are conventional, not absolute scene luminance.
    public let linearTargetRGB: SIMD3<Double>
    /// Nil for nonfinite pixels or undecodable PQ/HLG code-range violations.
    public let luminanceNits: Double?
    public let flags: GamutPixelFlags
}
public struct GamutScopeStatistics: Codable, Sendable {
    public var inspectedPixelCount:Int=0
    public var evaluatedPixelCount:Int=0
    public var invalidPixelCount:Int=0
    public var signalRangeViolationCount:Int=0
    public var outOfGamutCount:Int=0
    public var nearEdgeCount:Int=0
    public var luminanceExceededCount:Int=0
    public var minLuminanceNits:Double=0
    public var maxLuminanceNits:Double=0
    public var meanLuminanceNits:Double=0
    public var minTargetRGB=SIMD3<Double>.zero
    public var maxTargetRGB=SIMD3<Double>.zero
    public var transportDownsampled:Bool=false
    public var inspectedAllReceivedPixels:Bool=false
    public var outOfGamutPercent:Double { Double(outOfGamutCount)/Double(max(1,evaluatedPixelCount))*100 }
    public var nearEdgePercent:Double { Double(nearEdgeCount)/Double(max(1,evaluatedPixelCount))*100 }
    public var luminanceExceededPercent:Double { Double(luminanceExceededCount)/Double(max(1,evaluatedPixelCount))*100 }
    public var invalidPercent:Double { Double(invalidPixelCount)/Double(max(1,inspectedPixelCount))*100 }
    public init() {}
}
public struct GamutScopeResult: Sendable {
    public let bitmap:ScopeBitmap
    /// Raw GamutPixelFlags per overlay pixel. Zero also represents unselected pixels.
    public let flags:[UInt8]
    public let maskWidth:Int
    public let maskHeight:Int
    public let statistics:GamutScopeStatistics
    public let sequence:UInt64
    public let processingMS:Double
    /// Selection of gamut/range/brightness errors; near-edge warnings stay excluded.
    public var violationMask:ScopeSelectionMask {
        let errors:GamutPixelFlags=[.invalid,.outsideGamut,.luminanceExceeded,.signalRangeViolation]
        return ScopeSelectionMask(width:maskWidth,height:maskHeight,values:flags.map { ($0 & errors.rawValue)>0 ? 255:0 })
    }
}

private func gamutClamp(_ value:Double,_ lo:Double=0,_ hi:Double=1,fallback:Double=0)->Double { value.isFinite ? max(lo,min(hi,value)):fallback }
private func gamutByte(_ value:Double)->UInt8 { UInt8((gamutClamp(value)*255).rounded()) }
private struct GamutEvaluator {
    let settings:ScopeSettings
    let options:GamutScopeSettings
    let source:RGBMatrix
    let transform:RGBMatrix
    let referenceNits:Double
    init(settings:ScopeSettings,options:GamutScopeSettings) {
        self.settings=settings;self.options=options
        source=settings.colorSpace.primaries.matrix
        transform=RGBMatrix.conversion(from:settings.colorSpace,to:options.targetColorSpace)
        referenceNits=settings.transfer == .pq ? 10000:(settings.transfer == .hlg ? 1000:100)
    }
    func evaluate(_ encoded:SIMD3<Double>)->GamutPixelResult {
        guard encoded.x.isFinite,encoded.y.isFinite,encoded.z.isFinite else { return GamutPixelResult(linearTargetRGB:.zero,luminanceNits:nil,flags:.invalid) }
        var flags:GamutPixelFlags=[]
        let rgb=SIMD3(ColorMath.normalize(encoded.x,levels:settings.levels),ColorMath.normalize(encoded.y,levels:settings.levels),ColorMath.normalize(encoded.z,levels:settings.levels))
        // A small encoded epsilon admits Float32 representations of legal 64/940.
        let encodedTolerance=settings.levels == .video ? 1e-7:0
        // ACES floating scene encodings have meaningful negative and >1 codes.
        // Nominal SDR range warnings are not encoding-domain errors for them.
        let sceneDomain=settings.usesSceneReference
        let rangeViolation = !sceneDomain && (min(rgb.x,min(rgb.y,rgb.z)) < -encodedTolerance || max(rgb.x,max(rgb.y,rgb.z))>1+encodedTolerance)
        if rangeViolation { flags.insert(.signalRangeViolation) }
        if rangeViolation && (settings.transfer == .pq || settings.transfer == .hlg) {
            // These EOTFs have a defined [0,1] code domain. Never silently clamp
            // illegal HDR codes into plausible target-gamut or nit statistics.
            return GamutPixelResult(linearTargetRGB:.zero,luminanceNits:nil,flags:flags)
        }
        let linear:SIMD3<Double>
        if settings.transfer == .pq || settings.transfer == .hlg {
            linear=ColorMath.displayLinearRGB(SIMD3(gamutClamp(rgb.x),gamutClamp(rgb.y),gamutClamp(rgb.z)),space:settings.colorSpace,transfer:settings.transfer)
        } else {
            func decode(_ v:Double)->Double {
                ColorMath.linearize(v,transfer:settings.transfer,signedSDRExtension:true)
            }
            linear=SIMD3(decode(rgb.x),decode(rgb.y),decode(rgb.z))
        }
        let target=transform.applying(linear),xyz=source.applying(linear),nits=xyz.y*referenceNits
        guard target.x.isFinite,target.y.isFinite,target.z.isFinite,nits.isFinite else { return GamutPixelResult(linearTargetRGB:.zero,luminanceNits:nil,flags:[flags,.invalid]) }
        let tolerance=gamutClamp(options.tolerance,0,0.01,fallback:1e-7)
        let magnitude=max(1e-15,max(abs(target.x),max(abs(target.y),abs(target.z))))
        let lower=min(target.x,min(target.y,target.z)),upper=max(target.x,max(target.y,target.z))
        var outside=lower < -tolerance*magnitude
        let peak=gamutClamp(options.targetPeakNits,0.001,1e9,fallback:1000)
        if options.mode == .colorVolume && upper*referenceNits>peak*(1+tolerance) { outside=true }
        if outside { flags.insert(.outsideGamut) }
        else {
            let sum=target.x+target.y+target.z
            let margin=gamutClamp(options.nearEdgeMargin,0,1.0/3,fallback:0.02)
            if sum>1e-15 && lower/sum<=margin { flags.insert(.nearEdge) }
            if options.mode == .colorVolume && upper*referenceNits>=peak*(1-margin) { flags.insert(.nearEdge) }
        }
        if let ceiling=options.maxLuminanceNits,ceiling.isFinite,ceiling>=0,nits>ceiling+max(1,ceiling)*tolerance { flags.insert(.luminanceExceeded) }
        return GamutPixelResult(linearTargetRGB:target,luminanceNits:nits,flags:flags)
    }
}

/// Native-primary matrix gamut inspection with Bradford source-to-target white
/// adaptation. Luminance statistics retain native source Y (not adapted Y). Reference: docs.timeinpixels.com/nobe-omniscope/scopes/gamut-scope.
/// Orange edge metric and RGB-volume option are explicit original design choices.
public enum GamutScope {
    public static func convertLinearRGB(_ rgb:SIMD3<Double>,from:ColorSpace,to:ColorSpace)->SIMD3<Double> {
        ColorMath.convertLinearRGB(rgb,from:from,to:to)
    }
    /// RGB is the incoming encoded signal, before manual levels expansion.
    public static func evaluate(encodedRGB:SIMD3<Double>,settings:ScopeSettings=ScopeSettings(),gamut:GamutScopeSettings=GamutScopeSettings())->GamutPixelResult {
        GamutEvaluator(settings:settings,options:gamut).evaluate(encodedRGB)
    }
    /// Checks all selected pixels at received resolution when <=960×540. Larger
    /// frames use center-nearest sampling capped at960×540 and report that fact.
    /// If used for QC, pass the unmodified frame explicitly before applying a LUT.
    public static func analyze(frame:VideoFrame,settings:ScopeSettings=ScopeSettings(),gamut:GamutScopeSettings=GamutScopeSettings(),selectionMask:ScopeSelectionMask?=nil)->GamutScopeResult {
        let started=ProcessInfo.processInfo.systemUptime
        var stats=GamutScopeStatistics()
        guard frame.isValid else { return GamutScopeResult(bitmap:ScopeBitmap(width:1,height:1,rgba:[0,0,0,255]),flags:[0],maskWidth:1,maskHeight:1,statistics:stats,sequence:frame.sequence,processingMS:0) }
        let scale=min(1,min(960/Double(frame.width),540/Double(frame.height))),w=max(1,Int(floor(Double(frame.width)*scale))),h=max(1,Int(floor(Double(frame.height)*scale)))
        stats.transportDownsampled=w != frame.sourceWidth || h != frame.sourceHeight
        var bytes=[UInt8](repeating:0,count:w*h*4),flags=[UInt8](repeating:0,count:w*h)
        let evaluator=GamutEvaluator(settings:settings,options:gamut)
        var minNits=Double.infinity,maxNits = -Double.infinity,sumNits=0.0
        var minimum=SIMD3<Double>(repeating:.infinity),maximum=SIMD3<Double>(repeating: -.infinity)
        let roiRaster=settings.roiGeometry.raster(width:frame.width,height:frame.height)
        for y in 0..<h { for x in 0..<w {
            let sx=min(frame.width-1,Int((Double(x)+0.5)*Double(frame.width)/Double(w))),sy=min(frame.height-1,Int((Double(y)+0.5)*Double(frame.height)/Double(h))),i=(sy*frame.width+sx)*4,o=(y*w+x)*4
            let rgb=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
            let normalized=SIMD3(ColorMath.normalize(rgb.x,levels:settings.levels),ColorMath.normalize(rgb.y,levels:settings.levels),ColorMath.normalize(rgb.z,levels:settings.levels))
            let gray=gamutByte(ColorMath.luma(normalized,space:settings.colorSpace))
            bytes[o]=gray;bytes[o+1]=gray;bytes[o+2]=gray;bytes[o+3]=255
            guard roiRaster.contains(x:sx,y:sy),selectionMask?.includes(x:sx,y:sy,frameWidth:frame.width,frameHeight:frame.height) ?? true else { continue }
            stats.inspectedPixelCount+=1
            let p=evaluator.evaluate(rgb);flags[y*w+x]=p.flags.rawValue
            if p.flags.contains(.invalid) { stats.invalidPixelCount+=1 }
            if p.flags.contains(.signalRangeViolation) { stats.signalRangeViolationCount+=1 }
            if p.flags.contains(.outsideGamut) { stats.outOfGamutCount+=1 }
            if p.flags.contains(.nearEdge) { stats.nearEdgeCount+=1 }
            if p.flags.contains(.luminanceExceeded) { stats.luminanceExceededCount+=1 }
            if let nits=p.luminanceNits {
                stats.evaluatedPixelCount+=1;minNits=min(minNits,nits);maxNits=max(maxNits,nits);sumNits+=nits
                for c in 0..<3 { minimum[c]=min(minimum[c],p.linearTargetRGB[c]);maximum[c]=max(maximum[c],p.linearTargetRGB[c]) }
            }
            if p.flags.contains(.invalid) || (p.flags.contains(.signalRangeViolation) && p.luminanceNits == nil) { bytes[o]=255;bytes[o+1]=0;bytes[o+2]=255 }
            else if p.flags.contains(.outsideGamut) || p.flags.contains(.luminanceExceeded) { bytes[o]=255;bytes[o+1]=32;bytes[o+2]=24 }
            else if p.flags.contains(.nearEdge) { bytes[o]=255;bytes[o+1]=153;bytes[o+2]=24 }
        }}
        if stats.evaluatedPixelCount>0 { stats.minLuminanceNits=minNits;stats.maxLuminanceNits=maxNits;stats.meanLuminanceNits=sumNits/Double(stats.evaluatedPixelCount);stats.minTargetRGB=minimum;stats.maxTargetRGB=maximum }
        stats.inspectedAllReceivedPixels=w==frame.width && h==frame.height && stats.inspectedPixelCount==frame.width*frame.height
        return GamutScopeResult(bitmap:ScopeBitmap(width:w,height:h,rgba:bytes),flags:flags,maskWidth:w,maskHeight:h,statistics:stats,sequence:frame.sequence,processingMS:(ProcessInfo.processInfo.systemUptime-started)*1000)
    }
}
