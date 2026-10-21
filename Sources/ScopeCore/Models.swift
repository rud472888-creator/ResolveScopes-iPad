import Foundation

public struct VideoFrame: Sendable {
    public var width: Int
    public var height: Int
    public var rgba: [Float]
    public var sequence: UInt64
    public var timestampNS: UInt64
    public var timelineTime: Double
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var timecode: FrameTimecode?
    public init(width: Int, height: Int, rgba: [Float], sequence: UInt64 = 0, timestampNS: UInt64 = 0, timelineTime: Double = 0, sourceWidth: Int = 0, sourceHeight: Int = 0, timecode: FrameTimecode? = nil) {
        self.timecode = timecode
        self.width = width; self.height = height; self.rgba = rgba
        self.sequence = sequence; self.timestampNS = timestampNS; self.timelineTime = timelineTime
        self.sourceWidth = sourceWidth == 0 ? width : sourceWidth
        self.sourceHeight = sourceHeight == 0 ? height : sourceHeight
    }
    public var isValid: Bool {
        width > 0 && height > 0 && width <= 16384 && height <= 16384 && rgba.count == width * height * 4
    }
}

public enum ColorSpace: String, Codable, CaseIterable, Sendable {
    case rec709 = "Rec.709", p3D65 = "P3-D65", rec2020 = "Rec.2020"
    case acesAP0 = "ACES AP0", acesAP1 = "ACES AP1", adobeRGB = "Adobe RGB (1998)", proPhoto = "ProPhoto RGB", p3DCI = "P3-DCI"
}
public enum TransferFunction: String, Codable, CaseIterable, Sendable {
    case gamma24 = "Gamma 2.4", sRGB = "sRGB", linear = "Linear", pq = "ST 2084 / PQ", hlg = "HLG"
    case gamma18 = "Gamma 1.8", gamma22 = "Gamma 2.2", gamma26 = "Gamma 2.6"
    case proPhoto = "ProPhoto / ROMM", acescc = "ACEScc", acescct = "ACEScct"
    case adobeRGB = "Adobe RGB (563/256)"
    /// The ordinary measurement EOTF clamps these negative inputs to zero.
    /// Gamut inspection deliberately retains its historical signed SDR extension.
    public var clampsNegativeInput: Bool {
        switch self {
        case .linear, .proPhoto, .acescc, .acescct: return false
        default: return true
        }
    }
    /// Linear may also be scene-referred: that depends on the selected source.
    public var isSceneReferred: Bool { self == .acescc || self == .acescct }
}
public enum SignalLevels: String, Codable, CaseIterable, Sendable { case full = "Full", video = "Video (64–940)" }
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public enum ROIShape:String,Codable,CaseIterable,Sendable {
    case rectangle="Rectangle",ellipse="Ellipse"
}
public struct ScopeROIPixelBounds:Equatable,Sendable {
    public let x0:Int;public let y0:Int;public let x1:Int;public let y1:Int
    public var width:Int { max(0,x1-x0) }
    public var height:Int { max(0,y1-y0) }
}
public struct ScopeROIRasterGeometry:Sendable {
    public let bounds:ScopeROIPixelBounds
    private let geometry:ScopeROIGeometry
    private let width:Int
    private let height:Int
    fileprivate init(geometry:ScopeROIGeometry,width:Int,height:Int) {
        self.geometry=geometry;self.width=width;self.height=height
        bounds=geometry.pixelBounds(width:width,height:height)
    }
    public func contains(x:Int,y:Int)->Bool {
        guard x>=bounds.x0,x<bounds.x1,y>=bounds.y0,y<bounds.y1 else { return false }
        return geometry.ellipseContainsPixel(x:x,y:y,width:width,height:height)
    }
}
/// Shared geometry for ROI measurement, qualifier masks, overlays and color pins.
/// Rectangle raster bounds retain the original floor-to-pixel convention.
/// Ellipse membership samples pixel centers against the ORIGINAL bounding box:
/// clipping at the image edge never recenters or reshapes a partial ellipse.
public struct ScopeROIGeometry:Sendable {
    public let shape:ROIShape
    private let region:NormalizedRect?
    public init(roi:NormalizedRect?,shape:ROIShape = .rectangle) {
        self.shape=shape
        if let r=roi,r.x.isFinite,r.y.isFinite,r.width.isFinite,r.height.isFinite,
           (r.x+max(0,r.width)).isFinite,(r.y+max(0,r.height)).isFinite { region=r }
        else { region=nil } // Historical behavior: malformed/nonfinite ROI means full frame.
    }
    public var clippedBounds:NormalizedRect {
        guard let r=region else { return NormalizedRect(x:0,y:0,width:1,height:1) }
        let x0=Self.unit(r.x),y0=Self.unit(r.y),x1=Self.unit(r.x+max(0,r.width)),y1=Self.unit(r.y+max(0,r.height))
        return NormalizedRect(x:x0,y:y0,width:max(0,x1-x0),height:max(0,y1-y0))
    }
    /// The unmodified box for drawing. Omit malformed, empty and impractically
    /// enormous imported coordinates instead of passing them to CoreGraphics.
    public var outlineBounds:NormalizedRect? {
        guard let r=region,r.width>0,r.height>0,[r.x,r.y,r.width,r.height].allSatisfy({abs($0)<=1e6}),clippedBounds.width>0,clippedBounds.height>0 else { return nil }
        return r
    }
    public func pixelBounds(width:Int,height:Int)->ScopeROIPixelBounds {
        guard width>0,height>0,width<=16384,height<=16384 else { return ScopeROIPixelBounds(x0:0,y0:0,x1:0,y1:0) }
        guard let r=region else { return ScopeROIPixelBounds(x0:0,y0:0,x1:width,y1:height) }
        if shape == .ellipse {
            guard r.width>0,r.height>0 else { return ScopeROIPixelBounds(x0:0,y0:0,x1:0,y1:0) }
            // Candidate centers, including the mathematical ellipse boundary.
            // Unlike legacy rectangle floor bounds, a subpixel ellipse can
            // select a pixel when that pixel's center actually lies inside it.
            let x0=max(0,min(width,Int(ceil(Self.unit(r.x)*Double(width)-0.5))))
            let y0=max(0,min(height,Int(ceil(Self.unit(r.y)*Double(height)-0.5))))
            let x1=max(0,min(width,Int(floor(Self.unit(r.x+r.width)*Double(width)-0.5)+1)))
            let y1=max(0,min(height,Int(floor(Self.unit(r.y+r.height)*Double(height)-0.5)+1)))
            return ScopeROIPixelBounds(x0:x0,y0:y0,x1:max(x0,x1),y1:max(y0,y1))
        }
        let x0=Int(Self.unit(r.x)*Double(width)),y0=Int(Self.unit(r.y)*Double(height))
        let x1=Int(Self.unit(r.x+max(0,r.width))*Double(width)),y1=Int(Self.unit(r.y+max(0,r.height))*Double(height))
        return ScopeROIPixelBounds(x0:x0,y0:y0,x1:max(x0,x1),y1:max(y0,y1))
    }
    public func containsPixel(x:Int,y:Int,width:Int,height:Int)->Bool {
        raster(width:width,height:height).contains(x:x,y:y)
    }
    public func raster(width:Int,height:Int)->ScopeROIRasterGeometry { ScopeROIRasterGeometry(geometry:self,width:width,height:height) }
    fileprivate func ellipseContainsPixel(x:Int,y:Int,width:Int,height:Int)->Bool {
        guard let r=region,shape == .ellipse else { return true }
        return ellipseContains(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height),region:r)
    }
    /// Continuous geometry for overlays and a fallback pin projection. Pixel
    /// measurement/projection should use containsPixel/projectedHorizontal.
    public func contains(normalizedX x:Double,y:Double)->Bool {
        guard x.isFinite,y.isFinite,x>=0,x<=1,y>=0,y<=1 else { return false }
        guard let r=region else { return true }
        guard r.width>0,r.height>0,x>=r.x,x<=r.x+r.width,y>=r.y,y<=r.y+r.height else { return false }
        return shape == .rectangle || ellipseContains(x:x,y:y,region:r)
    }
    /// The same raster x projection used by waveform traces, with the pin read
    /// from its actual source pixel. Outside-ellipse/cropped pins return nil.
    public func projectedHorizontal(normalizedX x:Double,y:Double,width:Int,height:Int)->Double? {
        guard x.isFinite,y.isFinite,x>=0,x<=1,y>=0,y<=1,width>0,height>0,width<=16384,height<=16384 else { return nil }
        let px=min(width-1,Int(x*Double(width))),py=min(height-1,Int(y*Double(height)))
        guard containsPixel(x:px,y:py,width:width,height:height) else { return nil }
        let b=pixelBounds(width:width,height:height)
        return Double(px-b.x0)/Double(max(1,b.width-1))
    }
    private func ellipseContains(x:Double,y:Double,region r:NormalizedRect)->Bool {
        let rx=r.width/2,ry=r.height/2
        guard rx>0,ry>0 else { return false }
        let dx=(x-(r.x+rx))/rx,dy=(y-(r.y+ry))/ry
        guard dx.isFinite,dy.isFinite,abs(dx)<=1,abs(dy)<=1 else { return false }
        return dx*dx+dy*dy<=1+1e-12
    }
    private static func unit(_ v:Double)->Double { min(1,max(0,v)) }
}
public struct ScopeSettings: Codable, Equatable, Sendable {
    public var colorSpace: ColorSpace = .rec709
    public var transfer: TransferFunction = .gamma24
    public var levels: SignalLevels = .full
    public var sampleWidth: Int = 640
    public var gain: Double = 1.8
    public var vectorZoom: Double = 1
    public var roi: NormalizedRect? = nil
    public var roiShape:ROIShape = .rectangle
    public var ciePlotMode:CIEPlotMode = .xy1931
    public var cubeColorModel:CubeColorModel = .encodedRGB
    public init() {}
    public var roiGeometry:ScopeROIGeometry { ScopeROIGeometry(roi:roi,shape:roiShape) }
    private enum CodingKeys:String,CodingKey { case colorSpace,transfer,levels,sampleWidth,gain,vectorZoom,roi,roiShape,ciePlotMode,cubeColorModel }
    public init(from decoder:Decoder) throws {
        self.init()
        let c=try decoder.container(keyedBy:CodingKeys.self)
        colorSpace=try c.decodeIfPresent(ColorSpace.self,forKey:.colorSpace) ?? .rec709
        transfer=try c.decodeIfPresent(TransferFunction.self,forKey:.transfer) ?? .gamma24
        levels=try c.decodeIfPresent(SignalLevels.self,forKey:.levels) ?? .full
        sampleWidth=try c.decodeIfPresent(Int.self,forKey:.sampleWidth) ?? 640
        gain=try c.decodeIfPresent(Double.self,forKey:.gain) ?? 1.8
        vectorZoom=try c.decodeIfPresent(Double.self,forKey:.vectorZoom) ?? 1
        roi=try c.decodeIfPresent(NormalizedRect.self,forKey:.roi)
        roiShape=try c.decodeIfPresent(ROIShape.self,forKey:.roiShape) ?? .rectangle
        ciePlotMode=try c.decodeIfPresent(CIEPlotMode.self,forKey:.ciePlotMode) ?? .xy1931
        cubeColorModel=try c.decodeIfPresent(CubeColorModel.self,forKey:.cubeColorModel) ?? .encodedRGB
    }
}
public struct ScopeBitmap: Sendable {
    public let width: Int; public let height: Int; public let rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) { self.width = width; self.height = height; self.rgba = rgba }
}
public struct ScopeStatistics: Sendable {
    public var sampleCount: Int = 0
    public var invalidPixels: Int = 0
    public var minRGB: SIMD3<Float> = .zero
    public var maxRGB: SIMD3<Float> = .zero
    public var meanRGB: SIMD3<Float> = .zero
    public var minLuma: Float = 0
    public var maxLuma: Float = 0
    public var meanLuma: Float = 0
    public var minNits: Double = 0
    public var maxNits: Double = 0
    public var meanNits: Double = 0
    public var belowBlackPercent: Double = 0
    public var aboveWhitePercent: Double = 0
    public var outOfGamutPercent: Double = 0
    public var maxCLL: Double { maxNits }
    public var frameAverageLight: Double { meanNits }
    public init() {}
}
public struct ScopeResult: Sendable {
    public let source: ScopeBitmap
    public let waveform: ScopeBitmap
    public let waveformPeaks:[WaveformPeak]
    public let parade: ScopeBitmap
    public let vectorscope: ScopeBitmap
    public let histogram: ScopeBitmap
    public let chromaticity: ScopeBitmap
    public let cieTrace:CIETrace?
    public let falseColor: ScopeBitmap
    public let histogramR: [UInt32]
    public let histogramG: [UInt32]
    public let histogramB: [UInt32]
    public let histogramY: [UInt32]
    public let hueHistogram: [UInt32]
    public let saturationHistogram: [UInt32]
    public let cubePoints: [SIMD3<Float>]
    public let stats: ScopeStatistics
    public let sequence: UInt64
    public let processingMS: Double
    /// Replace display rasters while retaining exactly the same sampled numeric
    /// statistics, distributions and peak measurements.
    public func replacingTraceBitmaps(waveform:ScopeBitmap?,parade:ScopeBitmap?,vectorscope:ScopeBitmap?=nil,falseColor:ScopeBitmap?=nil)->ScopeResult {
        ScopeResult(source:source,waveform:waveform ?? self.waveform,waveformPeaks:waveformPeaks,parade:parade ?? self.parade,
                    vectorscope:vectorscope ?? self.vectorscope,histogram:histogram,chromaticity:chromaticity,cieTrace:cieTrace,falseColor:falseColor ?? self.falseColor,
                    histogramR:histogramR,histogramG:histogramG,histogramB:histogramB,histogramY:histogramY,hueHistogram:hueHistogram,
                    saturationHistogram:saturationHistogram,cubePoints:cubePoints,stats:stats,sequence:sequence,processingMS:processingMS)
    }
}

/// Measurement qualifier at an explicit raster size. Zero pixels are excluded,
/// rather than counted as black, from every scope statistic and distribution.
public struct ScopeSelectionMask: Sendable {
    public let width: Int
    public let height: Int
    public let values: [UInt8]
    public init(width:Int,height:Int,values:[UInt8]) { self.width=width;self.height=height;self.values=values }
    public var isValid: Bool { width>0 && height>0 && width<=16384 && height<=16384 && values.count==width*height }
    public func includes(x:Int,y:Int,frameWidth:Int,frameHeight:Int)->Bool {
        guard isValid,frameWidth>0,frameHeight>0 else { return false }
        let mx=min(width-1,max(0,x*width/frameWidth)),my=min(height-1,max(0,y*height/frameHeight))
        return values[my*width+mx]>0
    }
}
