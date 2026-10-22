import Foundation

public enum SkinSelectionModel: String, Codable, CaseIterable, Sendable {
    case yCbCr = "YCbCr", hsv = "HSV"
}

/// User-adjustable signal qualifiers. These are color selections, not camera
/// exposure presets or a person/face detector. Values use normalized encoded RGB.
public struct AdvancedScopeSettings: Codable, Equatable, Sendable {
    public var skinModel: SkinSelectionModel = .yCbCr
    public var skinLumaMin: Double = 0.05
    public var skinLumaMax: Double = 0.95
    public var skinSaturationMin: Double = 0.08
    public var skinSaturationMax: Double = 0.85
    public var skinHueCenterDegrees: Double = 25
    public var skinHueToleranceDegrees: Double = 25
    public var skinChromaMin: Double = 0.015
    public var skinChromaMax: Double = 0.35
    public var skinAngleCenterDegrees: Double = 123
    public var skinAngleToleranceDegrees: Double = 20
    public var skinOverlayOpacity: Double = 0.75
    /// Sat/Lum plots true CbCr radius on its vertical axis, not HSV saturation.
    public var satLumaMaxChroma: Double = 0.75
    public var qcChannelMin: Double = 0
    public var qcChannelMax: Double = 1
    public var qcLumaMin: Double = 0
    public var qcLumaMax: Double = 1
    /// Normalized-code epsilon for Float32 legal-range round trips. It changes
    /// QC threshold comparisons only; measured levels are never rounded/clamped.
    /// Set zero for strict comparisons.
    public var qcTolerance: Double = 1e-7
    public var blackThreshold: Double = 0.01
    public var blankingBlackFraction: Double = 0.995
    /// True: inspect every received pixel, independent of the display ROI.
    /// False: inspect the same sampled ROI grid as the plots.
    public var qcFullFrame: Bool = true
    /// Sobel gradient of encoded Y', divided by four (a unit step is 1).
    public var focusThreshold: Double = 0.10
    public var focusOpacity: Double = 0.85
    public init() {}
}

public struct SpatialWaveformPoint: Sendable {
    /// x,y are normalized image coordinates; y increases top to bottom.
    /// z is unclamped encoded Y' (0...1 corresponds to 0...100 IRE).
    public let position: SIMD3<Float>
    public let color: SIMD3<Float>
    public init(position: SIMD3<Float>, color: SIMD3<Float>) { self.position = position; self.color = color }
}

public struct BlackBorders: Codable, Equatable, Sendable {
    /// Consecutive near-black edge rows/columns in received-pixel units.
    /// All four are zero for a wholly black image; inspect isWholeFrameBlack.
    public var top: Int = 0
    public var bottom: Int = 0
    public var left: Int = 0
    public var right: Int = 0
    public var isWholeFrameBlack: Bool = false
    public init() {}
}

public struct FrameQCResult: Codable, Sendable {
    public var inspectedPixelCount: Int = 0
    public var validPixelCount: Int = 0
    public var invalidPixelCount: Int = 0
    public var channelUnderCounts = SIMD3<Int>.zero
    public var channelOverCounts = SIMD3<Int>.zero
    public var illegalChannelPixelCount: Int = 0
    public var lumaUnderCount: Int = 0
    public var lumaOverCount: Int = 0
    public var minLuma: Double = 0
    public var maxLuma: Double = 0
    public var meanLuma: Double = 0
    public var blackBorders = BlackBorders()
    public var activeImageRect: NormalizedRect?
    public var transportDownsampled: Bool = false
    public var isFullReceivedFrame: Bool = false
    public var receivedWidth: Int = 0
    public var receivedHeight: Int = 0
    public var sourceWidth: Int = 0
    public var sourceHeight: Int = 0
    /// True when a separately supplied, pre-LUT frame was inspected.
    public var usesSeparateQCFrame: Bool = false
    public var channelUnderPercent: SIMD3<Double> {
        let d = Double(max(1,validPixelCount))
        return SIMD3(Double(channelUnderCounts.x),Double(channelUnderCounts.y),Double(channelUnderCounts.z)) / d * 100
    }
    public var channelOverPercent: SIMD3<Double> {
        let d = Double(max(1,validPixelCount))
        return SIMD3(Double(channelOverCounts.x),Double(channelOverCounts.y),Double(channelOverCounts.z)) / d * 100
    }
    public var illegalChannelPercent: Double { Double(illegalChannelPixelCount)/Double(max(1,validPixelCount))*100 }
    public var lumaUnderPercent: Double { Double(lumaUnderCount)/Double(max(1,validPixelCount))*100 }
    public var lumaOverPercent: Double { Double(lumaOverCount)/Double(max(1,validPixelCount))*100 }
    public var hasViolations: Bool { invalidPixelCount > 0 || illegalChannelPixelCount > 0 || lumaUnderCount > 0 || lumaOverCount > 0 }
    public init() {}
}

public struct AdvancedScopeResult: Sendable {
    public let satLuma: ScopeBitmap
    public let skinTone: ScopeBitmap
    public let twinPeaks: ScopeBitmap
    public let twinPeaksMode: TwinPeaksMode
    /// Selected samples with either projected point outside the full canvas.
    /// Such points retain statistics but rasterize at its nearest edge.
    public let twinPeaksOutsidePlotCount: Int
    public let focusPeaking: ScopeBitmap
    public let skinMask: [UInt8]
    public let focusMask: [UInt8]
    public let maskWidth: Int
    public let maskHeight: Int
    public let spatialWaveformPoints: [SpatialWaveformPoint]
    public let sampledPixelCount: Int
    public let skinSelectedSampleCount: Int
    public let qc: FrameQCResult
    public let sequence: UInt64
    public let processingMS: Double
    /// Normalized plot coordinates with Y increasing upwards.
    public var twinPeaksBoundaries: [[SIMD2<Double>]] { AdvancedScopes.twinPeaksBoundaries }
}

private func advClamp(_ value: Double, _ low: Double = 0, _ high: Double = 1, fallback: Double = 0) -> Double {
    value.isFinite ? min(high,max(low,value)) : fallback
}
private func advByte(_ value: Double) -> UInt8 { UInt8((advClamp(value)*255).rounded()) }
private func advFloat(_ value: Double) -> Float { Float(min(Double(Float.greatestFiniteMagnitude),max(-Double(Float.greatestFiniteMagnitude),value))) }
private func advBounds(_ a: Double, _ b: Double, fallback: (Double,Double)) -> (Double,Double) {
    guard a.isFinite,b.isFinite else { return fallback };return (min(a,b),max(a,b))
}
private struct AdvancedDensity {
    let width: Int
    let height: Int
    var counts: [UInt32]
    var colors: [SIMD3<Float>]
    init(width: Int = 512, height: Int = 256) {
        self.width = width;self.height = height
        counts = .init(repeating:0,count:width*height);colors = .init(repeating:.zero,count:width*height)
    }
    mutating func add(_ position: SIMD2<Double>, color: SIMD3<Float>) {
        guard position.x.isFinite,position.y.isFinite else { return }
        let x = Int(advClamp(position.x)*Double(width-1)),y = Int((1-advClamp(position.y))*Double(height-1)),i = y*width+x
        counts[i] += 1;colors[i] += color
    }
    func bitmap(gain: Double) -> ScopeBitmap {
        var rgba = [UInt8](repeating:0,count:width*height*4)
        let gain = advClamp(gain,0.05,20,fallback:1.8)
        for i in counts.indices {
            rgba[i*4+3] = 255
            guard counts[i]>0 else { continue }
            let intensity = min(1,log1p(Double(counts[i]))*0.24*gain)
            let color = colors[i]/Float(counts[i])
            rgba[i*4] = advByte(Double(color.x)*intensity);rgba[i*4+1] = advByte(Double(color.y)*intensity);rgba[i*4+2] = advByte(Double(color.z)*intensity)
        }
        return ScopeBitmap(width:width,height:height,rgba:rgba)
    }
}

/// Independently implemented auxiliary scopes. The scope families are documented
/// at docs.timeinpixels.com/nobe-omniscope/scopes; no vendor code or presets are used.
public enum AdvancedScopes {
    /// RGB pair sums/differences rotate their legal unit squares into diamonds.
    /// The 10% vertical margin makes modest over/undershoots visible outside them.
    public static let twinPeaksBoundaries = TwinPeaks.boundaries
    public static func twinPeakCoordinates(_ rgb: SIMD3<Double>) -> (rg: SIMD2<Double>, bg: SIMD2<Double>) {
        (SIMD2(0.25+0.2*(rgb.x-rgb.y),0.1+0.4*(rgb.x+rgb.y)),
         SIMD2(0.75+0.2*(rgb.z-rgb.y),0.1+0.4*(rgb.z+rgb.y)))
    }

    /// Expects already level-normalized encoded RGB. Gray pixels are excluded in
    /// both models even if the user lowers saturation/chroma minima to zero.
    public static func isSkinTone(_ rgb: SIMD3<Double>, settings: ScopeSettings = ScopeSettings(), advanced: AdvancedScopeSettings = AdvancedScopeSettings()) -> Bool {
        skinQualification(rgb,settings:settings,advanced:advanced).selected
    }

    private static func skinQualification(_ rgb: SIMD3<Double>, settings: ScopeSettings, advanced a: AdvancedScopeSettings) -> (selected:Bool,deviation:Double) {
        guard rgb.x.isFinite,rgb.y.isFinite,rgb.z.isFinite else { return (false,0) }
        let y = ColorMath.luma(rgb,space:settings.colorSpace)
        let yr = advBounds(a.skinLumaMin,a.skinLumaMax,fallback:(0.05,0.95))
        guard y>=yr.0,y<=yr.1 else { return (false,0) }
        let hsv = ColorMath.hsv(rgb), sr = advBounds(a.skinSaturationMin,a.skinSaturationMax,fallback:(0.08,0.85))
        guard hsv.y>0.0001,hsv.y>=sr.0,hsv.y<=sr.1 else { return (false,0) }
        let angle: Double,center: Double,tolerance: Double
        if a.skinModel == .hsv {
            angle = hsv.x*360;center = a.skinHueCenterDegrees.isFinite ? a.skinHueCenterDegrees : 25
            tolerance = advClamp(a.skinHueToleranceDegrees,0,180,fallback:25)
        } else {
            let chroma = ColorMath.chroma(rgb,space:settings.colorSpace), radius = hypot(chroma.x,chroma.y)
            let cr = advBounds(a.skinChromaMin,a.skinChromaMax,fallback:(0.015,0.35))
            guard radius>0.0001,radius>=cr.0,radius<=cr.1 else { return (false,0) }
            angle = atan2(chroma.y,chroma.x)*180/Double.pi
            center = a.skinAngleCenterDegrees.isFinite ? a.skinAngleCenterDegrees : 123
            tolerance = advClamp(a.skinAngleToleranceDegrees,0,180,fallback:20)
        }
        // Reduce before subtracting so even finite, enormous user-entered angles
        // cannot overflow. remainder produces the shortest signed angular arc.
        let delta = (angle.remainder(dividingBy:360)-center.remainder(dividingBy:360)).remainder(dividingBy:360)
        return (abs(delta)<=tolerance,tolerance>0 ? advClamp(delta/tolerance,-1,1) : 0)
    }

    /// Hue deviation only: redward is negative, yellowward is positive in both
    /// the HSV and Cb/Cr skin qualifiers. This is not an exposure classification.
    public static func skinOverlayColor(deviation:Double)->SIMD3<Double> {
        if deviation < -1.0/3.0 {return SIMD3(1,0.08,0.04)}
        if deviation > 1.0/3.0 {return SIMD3(0.08,1,0.12)}
        return SIMD3(1,0.9,0)
    }

    /// Full received-raster key, evaluated before scope sampling. Used to
    /// intersect the optional skin key with a general Color Key exactly once.
    public static func skinSelectionMask(frame:VideoFrame,settings:ScopeSettings,advanced:AdvancedScopeSettings,intersecting:ScopeSelectionMask?=nil)->ScopeSelectionMask {
        guard frame.isValid else { return ScopeSelectionMask(width:1,height:1,values:[0]) }
        let roi=settings.roiGeometry.raster(width:frame.width,height:frame.height)
        var values=[UInt8](repeating:0,count:frame.width*frame.height)
        for y in 0..<frame.height { for x in 0..<frame.width {
            guard roi.contains(x:x,y:y),intersecting?.includes(x:x,y:y,frameWidth:frame.width,frameHeight:frame.height) ?? true else { continue }
            let i=(y*frame.width+x)*4,raw=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
            guard raw.x.isFinite,raw.y.isFinite,raw.z.isFinite else { continue }
            let rgb=SIMD3(ColorMath.normalize(raw.x,levels:settings.levels),ColorMath.normalize(raw.y,levels:settings.levels),ColorMath.normalize(raw.z,levels:settings.levels))
            if skinQualification(rgb,settings:settings,advanced:advanced).selected { values[y*frame.width+x]=255 }
        }}
        return ScopeSelectionMask(width:frame.width,height:frame.height,values:values)
    }

    /// qcFrame optionally supplies a pre-LUT frame for the QC report. It is
    /// inspected using the same levels and thresholds, independently of the
    /// processed frame used for visual scopes and selection overlays.
    public static func analyze(frame: VideoFrame, settings: ScopeSettings = ScopeSettings(), advanced a: AdvancedScopeSettings = AdvancedScopeSettings(), qcFrame: VideoFrame? = nil, selectionMask:ScopeSelectionMask? = nil, twinPeaks: TwinPeaksSettings = TwinPeaksSettings(), qcSettings:ScopeSettings?=nil) -> AdvancedScopeResult {
        let start = ProcessInfo.processInfo.systemUptime
        var sat = AdvancedDensity(),twin = AdvancedDensity()
        var twinOutside = 0
        var qc = FrameQCResult()
        qc.receivedWidth = frame.width;qc.receivedHeight = frame.height;qc.sourceWidth = frame.sourceWidth;qc.sourceHeight = frame.sourceHeight
        qc.transportDownsampled = frame.width != frame.sourceWidth || frame.height != frame.sourceHeight
        guard frame.isValid else {
            if let qcFrame { qc=inspectQC(frame:qcFrame,settings:qcSettings ?? settings,advanced:a);qc.usesSeparateQCFrame=true }
            let empty = ScopeBitmap(width:1,height:1,rgba:[0,0,0,255])
            return AdvancedScopeResult(satLuma:sat.bitmap(gain:settings.gain),skinTone:empty,twinPeaks:twin.bitmap(gain:settings.gain),twinPeaksMode:twinPeaks.mode,twinPeaksOutsidePlotCount:0,focusPeaking:empty,skinMask:[0],focusMask:[0],maskWidth:1,maskHeight:1,spatialWaveformPoints:[],sampledPixelCount:0,skinSelectedSampleCount:0,qc:qc,sequence:frame.sequence,processingMS:(ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        let roiRaster=settings.roiGeometry.raster(width:frame.width,height:frame.height)
        let bounds = roiRaster.bounds
        let sampleWidth = max(16,min(960,settings.sampleWidth)),sampleHeight = max(9,Int(Double(sampleWidth)*9/16))
        let xStep = max(1,Int(ceil(Double(bounds.x1-bounds.x0)/Double(sampleWidth))))
        let yStep = max(1,Int(ceil(Double(bounds.y1-bounds.y0)/Double(sampleHeight))))
        let scale = min(1,min(960/Double(frame.width),540/Double(frame.height)))
        let width = max(1,Int(floor(Double(frame.width)*scale))),height = max(1,Int(floor(Double(frame.height)*scale)))
        // Inverse center-nearest maps let the full-resolution QC pass also build
        // a bounded overlay without allocating a full-resolution RGB copy.
        var previewX = [Int](repeating:-1,count:frame.width),previewY = [Int](repeating:-1,count:frame.height)
        for x in 0..<width { previewX[min(frame.width-1,Int((Double(x)+0.5)*Double(frame.width)/Double(width)))] = x }
        for y in 0..<height { previewY[min(frame.height-1,Int((Double(y)+0.5)*Double(frame.height)/Double(height)))] = y }
        var sourceBytes = [UInt8](repeating:0,count:width*height*4),skinBytes = sourceBytes
        var skinMask = [UInt8](repeating:0,count:width*height),focusMask = skinMask
        var previewLuma = [Double](repeating:0,count:width*height)
        var previewValid = [Bool](repeating:false,count:width*height),previewROI = previewValid
        var rowBlack = [Int](repeating:0,count:frame.height),colBlack = [Int](repeating:0,count:frame.width)
        var blackPixelCount = 0,sampleCount = 0,skinSampleCount = 0
        var points = [SpatialWaveformPoint]();points.reserveCapacity(sampleWidth*sampleHeight)
        let channelRange = advBounds(a.qcChannelMin,a.qcChannelMax,fallback:(0,1)),lumaRange = advBounds(a.qcLumaMin,a.qcLumaMax,fallback:(0,1))
        let tolerance = advClamp(a.qcTolerance,0,1,fallback:1e-7)
        let blackThreshold = advClamp(a.blackThreshold,0,1,fallback:0.01)
        let maxChroma = advClamp(a.satLumaMaxChroma,0.01,10,fallback:0.75),skinOpacity = advClamp(a.skinOverlayOpacity,0,1,fallback:0.75)
        var minLuma = Double.infinity,maxLuma = -Double.infinity,sumLuma = 0.0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let i = (y*frame.width+x)*4
                let raw = SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
                let finite = raw.x.isFinite && raw.y.isFinite && raw.z.isFinite
                let insideROI = roiRaster.contains(x:x,y:y)
                let admitted=selectionMask?.includes(x:x,y:y,frameWidth:frame.width,frameHeight:frame.height) ?? true
                let sample = insideROI && admitted && (x-bounds.x0)%xStep == 0 && (y-bounds.y0)%yStep == 0
                let qcSample = insideROI && (x-bounds.x0)%xStep == 0 && (y-bounds.y0)%yStep == 0
                let inspect = qcFrame == nil && (a.qcFullFrame || qcSample)
                if inspect { qc.inspectedPixelCount += 1 }
                let px = previewX[x],py = previewY[y],preview = px>=0 && py>=0
                if !finite {
                    if inspect { qc.invalidPixelCount += 1 }
                    if preview { let p = (py*width+px)*4;sourceBytes[p+3]=255;skinBytes[p+3]=255;if admitted { sourceBytes[p]=255;sourceBytes[p+2]=255;skinBytes[p]=255;skinBytes[p+2]=255 } }
                    continue
                }
                let rgb = SIMD3(ColorMath.normalize(raw.x,levels:settings.levels),ColorMath.normalize(raw.y,levels:settings.levels),ColorMath.normalize(raw.z,levels:settings.levels))
                let luma = ColorMath.luma(rgb,space:settings.colorSpace)
                if qcFrame == nil && max(abs(rgb.x),max(abs(rgb.y),abs(rgb.z)))<=blackThreshold { rowBlack[y]+=1;colBlack[x]+=1;blackPixelCount+=1 }
                if inspect {
                    qc.validPixelCount += 1;minLuma = min(minLuma,luma);maxLuma = max(maxLuma,luma);sumLuma += luma
                    var illegal = false
                    for c in 0..<3 {
                        if rgb[c]<channelRange.0-tolerance { qc.channelUnderCounts[c]+=1;illegal = true }
                        if rgb[c]>channelRange.1+tolerance { qc.channelOverCounts[c]+=1;illegal = true }
                    }
                    if illegal { qc.illegalChannelPixelCount += 1 }
                    if luma<lumaRange.0-tolerance { qc.lumaUnderCount += 1 }
                    if luma>lumaRange.1+tolerance { qc.lumaOverCount += 1 }
                }
                if sample {
                    sampleCount += 1
                    let chroma = ColorMath.chroma(rgb,space:settings.colorSpace)
                    let color = SIMD3(Float(advClamp(rgb.x)*0.8+0.2),Float(advClamp(rgb.y)*0.8+0.2),Float(advClamp(rgb.z)*0.8+0.2))
                    sat.add(SIMD2(luma,hypot(chroma.x,chroma.y)/maxChroma),color:color)
                    if let pair = TwinPeaks.coordinates(normalizedRGB:rgb,space:settings.colorSpace,mode:twinPeaks.mode) {
                        if pair.outsidePlot { twinOutside += 1 }
                        twin.add(pair.left,color:SIMD3(1,0.6,0.3));twin.add(pair.right,color:SIMD3(0.3,0.7,1))
                    }
                    if skinQualification(rgb,settings:settings,advanced:a).selected { skinSampleCount += 1 }
                    points.append(SpatialWaveformPoint(position:SIMD3(Float(Double(x)/Double(max(1,frame.width-1))),Float(Double(y)/Double(max(1,frame.height-1))),advFloat(luma)),color:SIMD3(advFloat(rgb.x),advFloat(rgb.y),advFloat(rgb.z))))
                }
                if preview {
                    let p = py*width+px,o = p*4
                    previewLuma[p] = luma;previewValid[p] = true;previewROI[p] = insideROI && admitted
                    if admitted { sourceBytes[o]=advByte(rgb.x);sourceBytes[o+1]=advByte(rgb.y);sourceBytes[o+2]=advByte(rgb.z) };sourceBytes[o+3]=255
                    let selection = skinQualification(rgb,settings:settings,advanced:a)
                    let selected = insideROI && admitted && selection.selected
                    let gray = advClamp(luma)*0.35
                    if selected {
                        skinMask[p]=255
                        let overlay: SIMD3<Double> = skinOverlayColor(deviation:selection.deviation)
                        skinBytes[o]=advByte(advClamp(rgb.x)*(1-skinOpacity)+overlay.x*skinOpacity)
                        skinBytes[o+1]=advByte(advClamp(rgb.y)*(1-skinOpacity)+overlay.y*skinOpacity)
                        skinBytes[o+2]=advByte(advClamp(rgb.z)*(1-skinOpacity)+overlay.z*skinOpacity)
                    } else if admitted { let v=advByte(gray);skinBytes[o]=v;skinBytes[o+1]=v;skinBytes[o+2]=v }
                    skinBytes[o+3]=255
                }
            }
        }
        if let qcFrame {
            qc = inspectQC(frame:qcFrame,settings:qcSettings ?? settings,advanced:a)
            qc.usesSeparateQCFrame = true
        } else {
            if qc.validPixelCount>0 { qc.minLuma=minLuma;qc.maxLuma=maxLuma;qc.meanLuma=sumLuma/Double(qc.validPixelCount) }
            qc.isFullReceivedFrame = a.qcFullFrame && qc.inspectedPixelCount == frame.width*frame.height
            attachBorders(to:&qc,frame:frame,rows:rowBlack,cols:colBlack,blackPixelCount:blackPixelCount,advanced:a)
        }
        var focusBytes = sourceBytes
        let threshold = advClamp(a.focusThreshold,0,4,fallback:0.1),focusOpacity = advClamp(a.focusOpacity,0,1,fallback:0.85)
        if width>=3 && height>=3 {
            for y in 1..<(height-1) { for x in 1..<(width-1) {
                let p = y*width+x
                guard previewROI[p] else { continue }
                let tl=p-width-1,t=p-width,tr=p-width+1,l=p-1,r=p+1,bl=p+width-1,b=p+width,br=p+width+1
                guard previewValid[tl],previewValid[t],previewValid[tr],previewValid[l],previewValid[p],previewValid[r],previewValid[bl],previewValid[b],previewValid[br] else { continue }
                let gx = -previewLuma[tl]+previewLuma[tr]-2*previewLuma[l]+2*previewLuma[r]-previewLuma[bl]+previewLuma[br]
                let gy = -previewLuma[tl]-2*previewLuma[t]-previewLuma[tr]+previewLuma[bl]+2*previewLuma[b]+previewLuma[br]
                guard hypot(gx,gy)/4>threshold else { continue }
                focusMask[p]=255
                let o=p*4
                focusBytes[o]=advByte(Double(sourceBytes[o])/255*(1-focusOpacity)+0.1*focusOpacity)
                focusBytes[o+1]=advByte(Double(sourceBytes[o+1])/255*(1-focusOpacity)+focusOpacity)
                focusBytes[o+2]=advByte(Double(sourceBytes[o+2])/255*(1-focusOpacity)+0.2*focusOpacity)
            }}
        }
        return AdvancedScopeResult(satLuma:sat.bitmap(gain:settings.gain),skinTone:ScopeBitmap(width:width,height:height,rgba:skinBytes),twinPeaks:twin.bitmap(gain:settings.gain),twinPeaksMode:twinPeaks.mode,twinPeaksOutsidePlotCount:twinOutside,focusPeaking:ScopeBitmap(width:width,height:height,rgba:focusBytes),skinMask:skinMask,focusMask:focusMask,maskWidth:width,maskHeight:height,spatialWaveformPoints:points,sampledPixelCount:sampleCount,skinSelectedSampleCount:skinSampleCount,qc:qc,sequence:frame.sequence,processingMS:(ProcessInfo.processInfo.systemUptime-start)*1000)
    }

    public static func inspectQC(frame:VideoFrame,settings:ScopeSettings,advanced a:AdvancedScopeSettings) -> FrameQCResult {
        var qc=FrameQCResult()
        qc.receivedWidth=frame.width;qc.receivedHeight=frame.height;qc.sourceWidth=frame.sourceWidth;qc.sourceHeight=frame.sourceHeight
        qc.transportDownsampled=frame.width != frame.sourceWidth || frame.height != frame.sourceHeight
        guard frame.isValid else { return qc }
        let roiRaster=settings.roiGeometry.raster(width:frame.width,height:frame.height)
        let bounds=roiRaster.bounds,sampleWidth=max(16,min(960,settings.sampleWidth)),sampleHeight=max(9,Int(Double(sampleWidth)*9/16))
        let xStep=max(1,Int(ceil(Double(bounds.x1-bounds.x0)/Double(sampleWidth)))),yStep=max(1,Int(ceil(Double(bounds.y1-bounds.y0)/Double(sampleHeight))))
        let channelRange=advBounds(a.qcChannelMin,a.qcChannelMax,fallback:(0,1)),lumaRange=advBounds(a.qcLumaMin,a.qcLumaMax,fallback:(0,1))
        let tolerance=advClamp(a.qcTolerance,0,1,fallback:1e-7)
        let blackThreshold=advClamp(a.blackThreshold,0,1,fallback:0.01)
        var rows=[Int](repeating:0,count:frame.height),cols=[Int](repeating:0,count:frame.width),blackPixelCount=0
        var minY=Double.infinity,maxY = -Double.infinity,sumY=0.0
        for y in 0..<frame.height { for x in 0..<frame.width {
            let inspect=a.qcFullFrame || (roiRaster.contains(x:x,y:y) && (x-bounds.x0)%xStep == 0 && (y-bounds.y0)%yStep == 0)
            if inspect { qc.inspectedPixelCount+=1 }
            let i=(y*frame.width+x)*4,raw=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
            guard raw.x.isFinite,raw.y.isFinite,raw.z.isFinite else { if inspect { qc.invalidPixelCount+=1 };continue }
            let rgb=SIMD3(ColorMath.normalize(raw.x,levels:settings.levels),ColorMath.normalize(raw.y,levels:settings.levels),ColorMath.normalize(raw.z,levels:settings.levels))
            if max(abs(rgb.x),max(abs(rgb.y),abs(rgb.z)))<=blackThreshold { rows[y]+=1;cols[x]+=1;blackPixelCount+=1 }
            guard inspect else { continue }
            qc.validPixelCount+=1
            let yValue=ColorMath.luma(rgb,space:settings.colorSpace)
            minY=min(minY,yValue);maxY=max(maxY,yValue);sumY+=yValue
            var illegal=false
            for c in 0..<3 {
                if rgb[c]<channelRange.0-tolerance { qc.channelUnderCounts[c]+=1;illegal=true }
                if rgb[c]>channelRange.1+tolerance { qc.channelOverCounts[c]+=1;illegal=true }
            }
            if illegal { qc.illegalChannelPixelCount+=1 }
            if yValue<lumaRange.0-tolerance { qc.lumaUnderCount+=1 }
            if yValue>lumaRange.1+tolerance { qc.lumaOverCount+=1 }
        }}
        if qc.validPixelCount>0 { qc.minLuma=minY;qc.maxLuma=maxY;qc.meanLuma=sumY/Double(qc.validPixelCount) }
        qc.isFullReceivedFrame=a.qcFullFrame && qc.inspectedPixelCount == frame.width*frame.height
        attachBorders(to:&qc,frame:frame,rows:rows,cols:cols,blackPixelCount:blackPixelCount,advanced:a)
        return qc
    }
    private static func attachBorders(to qc:inout FrameQCResult,frame:VideoFrame,rows:[Int],cols:[Int],blackPixelCount:Int,advanced a:AdvancedScopeSettings) {
        let borders=detectBorders(width:frame.width,height:frame.height,rows:rows,cols:cols,blackPixelCount:blackPixelCount,fraction:advClamp(a.blankingBlackFraction,0.5,1,fallback:0.995))
        qc.blackBorders=borders
        if !borders.isWholeFrameBlack {
            qc.activeImageRect=NormalizedRect(x:Double(borders.left)/Double(frame.width),y:Double(borders.top)/Double(frame.height),width:Double(max(0,frame.width-borders.left-borders.right))/Double(frame.width),height:Double(max(0,frame.height-borders.top-borders.bottom))/Double(frame.height))
        }
    }
    private static func detectBorders(width:Int,height:Int,rows:[Int],cols:[Int],blackPixelCount:Int,fraction:Double) -> BlackBorders {
        var result=BlackBorders()
        // A nearly all-black picture is a black frame, not four overlapping bars.
        if Double(blackPixelCount)/Double(width*height)>=fraction { result.isWholeFrameBlack=true;return result }
        func row(_ i:Int)->Bool { Double(rows[i])/Double(width)>=fraction }
        func col(_ i:Int)->Bool { Double(cols[i])/Double(height)>=fraction }
        while result.top<height && row(result.top) { result.top+=1 }
        while result.bottom<height-result.top && row(height-1-result.bottom) { result.bottom+=1 }
        while result.left<width && col(result.left) { result.left+=1 }
        while result.right<width-result.left && col(width-1-result.right) { result.right+=1 }
        return result
    }
}
