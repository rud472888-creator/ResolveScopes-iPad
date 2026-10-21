import Foundation

public enum VectorScopeMode:String,Codable,CaseIterable,Sendable {
    case cbCr="Cb / Cr",hsl="HSL"
}
public enum VectorScopeBand:String,Codable,CaseIterable,Sendable {
    case low="Low",mid="Mid",high="High"
}
public enum VectorTargetScale:String,Codable,CaseIterable,Sendable {
    case percent75="75%",percent100="100%"
    public var fraction:Double { self == .percent75 ? 0.75:1 }
}
/// Original encoded-signal analysis settings. Trace gains and centerBoost only
/// change brightness, never coordinates, band membership or alarm statistics.
/// targetScale only changes the reference targets, never measured saturation.
public struct VectorScopeSettings:Codable,Equatable,Sendable {
    public var mode:VectorScopeMode = .cbCr
    public var splitHML=false
    public var lowThreshold=0.33
    public var highThreshold=0.66
    public var lowGain=1.0
    public var midGain=1.0
    public var highGain=1.0
    /// Zero disables the extra center brightness; otherwise bounded to 0...8.
    public var centerBoost=0.0
    public var saturationAlarmEnabled=false
    public var saturationAlarmPercent=100.0
    public var targetScale:VectorTargetScale = .percent75
    public var showSkinLine=true
    public var colorize=true
    public init() {}
    /// Imported numeric preferences are sanitized at every public entry point.
    public var effective:VectorScopeSettings {
        var s=self
        func bound(_ value:Double,_ low:Double,_ high:Double,_ fallback:Double)->Double {
            value.isFinite ? min(high,max(low,value)):fallback
        }
        let a=bound(lowThreshold,0,1,0.33),b=bound(highThreshold,0,1,0.66)
        s.lowThreshold=min(a,b);s.highThreshold=max(a,b)
        s.lowGain=bound(lowGain,0,20,1);s.midGain=bound(midGain,0,20,1);s.highGain=bound(highGain,0,20,1)
        s.centerBoost=bound(centerBoost,0,8,0)
        s.saturationAlarmPercent=bound(saturationAlarmPercent,0,10_000,100)
        return s
    }
    private enum CodingKeys:String,CodingKey {
        case mode,splitHML,lowThreshold,highThreshold,lowGain,midGain,highGain,centerBoost
        case saturationAlarmEnabled,saturationAlarmPercent,targetScale,showSkinLine,colorize
    }
    public init(from decoder:Decoder)throws {
        self.init()
        let c=try decoder.container(keyedBy:CodingKeys.self)
        mode=try c.decodeIfPresent(VectorScopeMode.self,forKey:.mode) ?? .cbCr
        splitHML=try c.decodeIfPresent(Bool.self,forKey:.splitHML) ?? false
        lowThreshold=try c.decodeIfPresent(Double.self,forKey:.lowThreshold) ?? 0.33
        highThreshold=try c.decodeIfPresent(Double.self,forKey:.highThreshold) ?? 0.66
        lowGain=try c.decodeIfPresent(Double.self,forKey:.lowGain) ?? 1
        midGain=try c.decodeIfPresent(Double.self,forKey:.midGain) ?? 1
        highGain=try c.decodeIfPresent(Double.self,forKey:.highGain) ?? 1
        centerBoost=try c.decodeIfPresent(Double.self,forKey:.centerBoost) ?? 0
        saturationAlarmEnabled=try c.decodeIfPresent(Bool.self,forKey:.saturationAlarmEnabled) ?? false
        saturationAlarmPercent=try c.decodeIfPresent(Double.self,forKey:.saturationAlarmPercent) ?? 100
        targetScale=try c.decodeIfPresent(VectorTargetScale.self,forKey:.targetScale) ?? .percent75
        showSkinLine=try c.decodeIfPresent(Bool.self,forKey:.showSkinLine) ?? true
        colorize=try c.decodeIfPresent(Bool.self,forKey:.colorize) ?? true
    }
}
public struct VectorScopeTarget:Sendable {
    public let name:String
    public let rgb:SIMD3<Double>
    /// Display-normalized coordinates: x right, y DOWN. May be outside 0...1.
    public let position:SIMD2<Double>
}
public struct VectorScopeResult:Sendable {
    /// Always available. Band brightness controls apply only in splitHML mode.
    public let combined:ScopeBitmap
    /// Three independently accumulated images only when splitHML is enabled.
    public let low:ScopeBitmap?
    public let mid:ScopeBitmap?
    public let high:ScopeBitmap?
    public let sampleCount:Int
    public let invalidCount:Int
    public let lowCount:Int
    public let midCount:Int
    public let highCount:Int
    /// CbCr: 100% means chroma radius 0.5. This is radial percentage, not HSV S
    /// or a broadcast-compliance limit. HSL: 100% means HSL saturation 1.
    public let maximumSaturationPercent:Double
    /// Strictly greater than the configured limit; zero when alarm is disabled.
    public let alarmCount:Int
    public let lowAlarmCount:Int
    public let midAlarmCount:Int
    public let highAlarmCount:Int
    public var alarmPercent:Double { sampleCount>0 ? Double(alarmCount)*100/Double(sampleCount):0 }
    /// Finite samples whose displayed position falls outside the bitmap.
    /// They are retained in statistics but omitted from the trace, so zoomed or
    /// extended-range signals do not form artificial rails at the plot boundary.
    public let outsidePlotCount:Int
    /// HSL samples clipped to 0...1 before H/S/L calculation (video endpoints
    /// allow 1e-7 Float32 normalization roundoff in this diagnostic count).
    public let hslClampedCount:Int
    public let sampled:Bool
    public let transportDownsampled:Bool
    public let sequence:UInt64
    public let processingMS:Double
}

/// Original vectorscope math based on the feature families in the official
/// Nobe documentation, not a reproduction of its undisclosed pixel algorithms.
/// All transforms operate on encoded R′G′B′; transfer functions are not decoded.
public enum VectorScope {
    private static let side=640
    /// Low: Y′ < lowThreshold; Mid: lowThreshold <= Y′ < highThreshold;
    /// High: Y′ >= highThreshold. Thresholds are sorted/clamped to 0...1.
    /// Equal thresholds deliberately make the Mid interval empty. Unclamped
    /// negative and HDR Y′ still classify into Low and High respectively.
    public static func classify(luma:Double,vector:VectorScopeSettings=VectorScopeSettings())->VectorScopeBand? {
        guard luma.isFinite else { return nil }
        return band(luma,vector.effective)
    }
    /// Standard HSL of channel-clamped encoded RGB. Hue is turns in [0,1), S/L
    /// are [0,1]; achromatic hue is defined as zero. Negative/HDR channels clamp
    /// only for this HSL transform, not for the independent Y′ band classifier.
    public static func hsl(rgb:SIMD3<Double>)->SIMD3<Double>? {
        guard finite(rgb) else { return nil }
        let r=unit(rgb.x),g=unit(rgb.y),b=unit(rgb.z)
        let maximum=max(r,max(g,b)),minimum=min(r,min(g,b)),delta=maximum-minimum
        let lightness=(maximum+minimum)/2
        guard delta>1e-12 else { return SIMD3(0,0,lightness) }
        let denominator=1-abs(2*lightness-1)
        var hue:Double
        if maximum == r { hue=(g-b)/delta; if hue<0 { hue+=6 } }
        else if maximum == g { hue=(b-r)/delta+2 }
        else { hue=(r-g)/delta+4 }
        return SIMD3(hue/6,unit(denominator>0 ? delta/denominator:0),lightness)
    }
    /// Already levels-normalized encoded RGB goes here; do not expand Video
    /// levels again. Coordinates share the bitmap convention (x right, y DOWN).
    /// zoom affects display only. No plot clamp is applied, so callers can clip
    /// overlays consistently. An optional band filters pins by unclamped Y′.
    public static func normalizedPosition(rgb:SIMD3<Double>,space:ColorSpace,vector:VectorScopeSettings=VectorScopeSettings(),zoom:Double=1,band requestedBand:VectorScopeBand?=nil)->SIMD2<Double>? {
        let v=vector.effective
        guard finite(rgb) else { return nil }
        let y=ColorMath.luma(rgb,space:space)
        guard y.isFinite else { return nil }
        if let requestedBand,band(y,v) != requestedBand { return nil }
        guard let point=project(rgb:rgb,space:space,mode:v.mode) else { return nil }
        return displayPosition(point,zoom:zoom)
    }
    /// Reference colors R/Y/G/C/B/M. CbCr 75% means encoded RGB bars scaled by
    /// 0.75. HSL 75% means radius S=0.75 at those six hues; scaling RGB bars
    /// would leave their HSL saturation equal to 1 and is intentionally avoided.
    public static func targetPositions(space:ColorSpace,vector:VectorScopeSettings=VectorScopeSettings(),zoom:Double=1)->[VectorScopeTarget] {
        let v=vector.effective,scale=v.targetScale.fraction
        let colors:[(String,SIMD3<Double>)]=[("R",SIMD3(1,0,0)),("Y",SIMD3(1,1,0)),("G",SIMD3(0,1,0)),("C",SIMD3(0,1,1)),("B",SIMD3(0,0,1)),("M",SIMD3(1,0,1))]
        return colors.compactMap { name,rgb in
            guard let point=project(rgb:v.mode == .cbCr ? rgb*scale:rgb,space:space,mode:v.mode),
                  let position=displayPosition(v.mode == .hsl ? point*scale:point,zoom:zoom) else { return nil }
            return VectorScopeTarget(name:name,rgb:rgb,position:position)
        }
    }
    public static func analyze(frame:VideoFrame,settings:ScopeSettings=ScopeSettings(),vector:VectorScopeSettings=VectorScopeSettings(),selectionMask:ScopeSelectionMask?=nil)->VectorScopeResult {
        let start=ProcessInfo.processInfo.systemUptime,v=vector.effective
        let zoom=safeZoom(settings.vectorZoom)
        var plots=(0..<(v.splitHML ? 4:1)).map { _ in Density() }
        var samples=0,invalid=0,outside=0,clamped=0
        var counts=[Int](repeating:0,count:3),alarms=[Int](repeating:0,count:3)
        var maximum=0.0,sampled=false
        if frame.isValid {
            let raster=settings.roiGeometry.raster(width:frame.width,height:frame.height),roi=raster.bounds
            let quality=max(16,min(960,settings.sampleWidth)),qh=max(9,quality*9/16)
            let xs=max(1,Int(ceil(Double(roi.width)/Double(quality)))),ys=max(1,Int(ceil(Double(roi.height)/Double(qh))))
            sampled=xs>1 || ys>1
            if roi.width>0 && roi.height>0 {
                for y in stride(from:roi.y0,to:roi.y1,by:ys) { for x in stride(from:roi.x0,to:roi.x1,by:xs) {
                    guard raster.contains(x:x,y:y),selectionMask?.includes(x:x,y:y,frameWidth:frame.width,frameHeight:frame.height) ?? true else { continue }
                    let i=(y*frame.width+x)*4
                    let raw=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
                    guard finite(raw) else { invalid+=1;continue }
                    let rgb=SIMD3(ColorMath.normalize(raw.x,levels:settings.levels),ColorMath.normalize(raw.y,levels:settings.levels),ColorMath.normalize(raw.z,levels:settings.levels))
                    let luma=ColorMath.luma(rgb,space:settings.colorSpace)
                    guard luma.isFinite,let point=project(rgb:rgb,space:settings.colorSpace,mode:v.mode),let position=displayPosition(point,zoom:zoom) else { invalid+=1;continue }
                    let b=band(luma,v),index=bandIndex(b)
                    // HSL alarm S comes directly from the transform; recovering
                    // it with hypot(cos(h),sin(h)) could exceed 100% by an ulp.
                    let radius=v.mode == .hsl ? (hsl(rgb:rgb)?.y ?? 0):hypot(point.x,point.y)*2
                    let saturation=radius*100
                    samples+=1;counts[index]+=1;maximum=max(maximum,saturation)
                    if v.saturationAlarmEnabled,saturation>v.saturationAlarmPercent { alarms[index]+=1 }
                    if position.x<0 || position.x>1 || position.y<0 || position.y>1 { outside+=1 }
                    let tolerance=settings.levels == .video ? 1e-7:0
                    if v.mode == .hsl,(rgb.x < -tolerance || rgb.x>1+tolerance || rgb.y < -tolerance || rgb.y>1+tolerance || rgb.z < -tolerance || rgb.z>1+tolerance) { clamped+=1 }
                    let color:SIMD3<Float>=v.colorize ? SIMD3(Float(unit(rgb.x)*0.8+0.2),Float(unit(rgb.y)*0.8+0.2),Float(unit(rgb.z)*0.8+0.2)):SIMD3(0.8,1,0.9)
                    let gain=v.splitHML ? bandGain(b,v):1
                    // Smooth local boost: 1+boost at neutral; approaches 1
                    // outside the central 25% radius. No coordinate distortion.
                    let boost=v.centerBoost>0 ? 1+v.centerBoost*exp(-pow(min(radius,1e6)/0.25,2)):1
                    plots[0].add(position:position,color:color*Float(gain*boost))
                    if v.splitHML { plots[index+1].add(position:position,color:color*Float(gain*boost)) }
                }}
            }
        }
        let gain=settings.gain.isFinite ? min(20,max(0.05,settings.gain)):1.8
        return VectorScopeResult(combined:plots[0].bitmap(gain:gain),low:v.splitHML ? plots[1].bitmap(gain:gain):nil,mid:v.splitHML ? plots[2].bitmap(gain:gain):nil,high:v.splitHML ? plots[3].bitmap(gain:gain):nil,sampleCount:samples,invalidCount:invalid,lowCount:counts[0],midCount:counts[1],highCount:counts[2],maximumSaturationPercent:maximum,alarmCount:alarms.reduce(0,+),lowAlarmCount:alarms[0],midAlarmCount:alarms[1],highAlarmCount:alarms[2],outsidePlotCount:outside,hslClampedCount:clamped,sampled:sampled,transportDownsampled:frame.width != frame.sourceWidth || frame.height != frame.sourceHeight,sequence:frame.sequence,processingMS:(ProcessInfo.processInfo.systemUptime-start)*1000)
    }
    private static func project(rgb:SIMD3<Double>,space:ColorSpace,mode:VectorScopeMode)->SIMD2<Double>? {
        guard finite(rgb) else { return nil }
        if mode == .cbCr {
            let uv=ColorMath.chroma(rgb,space:space)
            return uv.x.isFinite && uv.y.isFinite ? uv:nil
        }
        guard let hsl=hsl(rgb:rgb) else { return nil }
        // Red is at 103°; hue advances counterclockwise in Cb/Cr coordinates.
        // This orientation puts orange near the conventional 123° skin guide.
        let angle=(103+hsl.x*360)*Double.pi/180
        return SIMD2(cos(angle),sin(angle))*(hsl.y*0.5)
    }
    private static func displayPosition(_ point:SIMD2<Double>,zoom:Double)->SIMD2<Double>? {
        let p=SIMD2(0.5+point.x*0.88*safeZoom(zoom),0.5-point.y*0.88*safeZoom(zoom))
        return p.x.isFinite && p.y.isFinite ? p:nil
    }
    private static func safeZoom(_ zoom:Double)->Double { zoom.isFinite ? min(8,max(0.1,zoom)):1 }
    private static func band(_ y:Double,_ v:VectorScopeSettings)->VectorScopeBand { y<v.lowThreshold ? .low:(y<v.highThreshold ? .mid:.high) }
    private static func bandIndex(_ band:VectorScopeBand)->Int { band == .low ? 0:(band == .mid ? 1:2) }
    private static func bandGain(_ band:VectorScopeBand,_ v:VectorScopeSettings)->Double { band == .low ? v.lowGain:(band == .mid ? v.midGain:v.highGain) }
    private static func finite(_ rgb:SIMD3<Double>)->Bool { rgb.x.isFinite && rgb.y.isFinite && rgb.z.isFinite }
    private static func unit(_ v:Double)->Double { min(1,max(0,v)) }
    /// Fractional coverage accumulates RGB radiance rather than averaging the
    /// colors sharing a cell. Four small taps keep subpixel motion continuous.
    /// A split plot uses four 640² float RGB grids (~25 MiB total); only occupied
    /// cells need the display curve. A GPU implementation can reduce CPU cost
    /// if sustained large-frame analysis becomes the limiting stage.
    private struct Density {
        var radiance=[SIMD3<Float>](repeating:.zero,count:side*side)
        var occupied=[Int]()
        mutating func add(position:SIMD2<Double>,color:SIMD3<Float>) {
            // Do not project offscreen samples onto an unrelated boundary.
            guard position.x>=0,position.x<=1,position.y>=0,position.y<=1,
                  color.x>0 || color.y>0 || color.z>0 else { return }
            let px=position.x*Double(side-1),py=position.y*Double(side-1)
            let x0=Int(px),y0=Int(py),x1=min(side-1,x0+1),y1=min(side-1,y0+1)
            let fx=Float(px-Double(x0)),fy=Float(py-Double(y0))
            accumulate(index:y0*side+x0,color:color,weight:(1-fx)*(1-fy))
            accumulate(index:y0*side+x1,color:color,weight:fx*(1-fy))
            accumulate(index:y1*side+x0,color:color,weight:(1-fx)*fy)
            accumulate(index:y1*side+x1,color:color,weight:fx*fy)
        }
        private mutating func accumulate(index:Int,color:SIMD3<Float>,weight:Float) {
            guard weight>0 else { return }
            if radiance[index] == .zero { occupied.append(index) }
            radiance[index]+=color*weight
        }
        func bitmap(gain:Double)->ScopeBitmap {
            var bytes=[UInt8](repeating:0,count:side*side*4)
            for i in stride(from:3,to:bytes.count,by:4) { bytes[i]=255 }
            // Accumulate RGB first, then use one shared bounded shoulder.
            // This preserves hue/saturation in dense clouds instead of turning
            // every independently saturated channel white. Gain precedes it.
            let exposure=0.4*gain
            for i in occupied {
                let color=radiance[i]
                let peak=Double(max(color.x,max(color.y,color.z))),factor=exposure/(1+peak*exposure)
                bytes[i*4]=encode(Double(color.x)*factor)
                bytes[i*4+1]=encode(Double(color.y)*factor)
                bytes[i*4+2]=encode(Double(color.z)*factor)
            }
            return ScopeBitmap(width:side,height:side,rgba:bytes)
        }
        private func encode(_ intensity:Double)->UInt8 {
            UInt8((min(1,max(0,intensity))*255).rounded())
        }
    }
}
