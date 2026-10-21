import Foundation

/// Exactly the six channel combinations listed in the official Channel Plot
/// documentation. This implementation explicitly maps first channel to X,
/// second to Y. No undocumented channel transforms or vendor filters are inferred.
public enum ChannelPair: String, Codable, CaseIterable, Sendable {
    case rg="R / G",rb="R / B",gb="G / B",yCb="Y / Cb",yCr="Y / Cr",cbCr="Cb / Cr"
    public var xAxis:ChannelPlotAxis {
        switch self {
        case .rg,.rb:return ChannelPlotAxis(label:"R′",minimum:0,maximum:1)
        case .gb:return ChannelPlotAxis(label:"G′",minimum:0,maximum:1)
        case .yCb,.yCr:return ChannelPlotAxis(label:"Y′",minimum:0,maximum:1)
        case .cbCr:return ChannelPlotAxis(label:"Cb",minimum:-0.5,maximum:0.5)
        }
    }
    public var yAxis:ChannelPlotAxis {
        switch self {
        case .rg:return ChannelPlotAxis(label:"G′",minimum:0,maximum:1)
        case .rb,.gb:return ChannelPlotAxis(label:"B′",minimum:0,maximum:1)
        case .yCb:return ChannelPlotAxis(label:"Cb",minimum:-0.5,maximum:0.5)
        case .yCr,.cbCr:return ChannelPlotAxis(label:"Cr",minimum:-0.5,maximum:0.5)
        }
    }
}
public struct ChannelPlotAxis: Codable, Equatable, Sendable {
    public let label:String
    public let minimum:Double
    public let maximum:Double
    public init(label:String,minimum:Double,maximum:Double) { self.label=label;self.minimum=minimum;self.maximum=maximum }
}
public struct ChannelPlotSettings: Codable, Equatable, Sendable {
    public var pair:ChannelPair = .rg
    public var colorize:Bool=true
    public init() {}
}
public struct ChannelPlotResult: Sendable {
    public let bitmap:ScopeBitmap
    public let xAxis:ChannelPlotAxis
    public let yAxis:ChannelPlotAxis
    public let sampleCount:Int
    public let invalidCount:Int
    /// Samples outside the axis interval are counted and drawn on the nearest
    /// image boundary; numerical min/max stay unclamped. Manual video levels
    /// allow 1e-7 normalization roundoff for Float32 64/940 endpoints.
    public let outsidePlotCount:Int
    public let minimum:SIMD2<Double>
    public let maximum:SIMD2<Double>
    public let sampled:Bool
    public let transportDownsampled:Bool
    public let sequence:UInt64
    public let processingMS:Double
}

/// Original pairwise encoded-signal scatter plots, based only on the projection
/// families documented at docs.timeinpixels.com/nobe-omniscope/scopes/channel-plot.
public enum ChannelPlot {
    /// Input is unexpanded encoded RGB; levels are expanded exactly once here.
    /// Returned components retain excursions. Y′/Cb/Cr use selected primaries'
    /// matrix coefficients; the transfer function does not decode channel plots.
    public static func project(encodedRGB:SIMD3<Double>,settings:ScopeSettings=ScopeSettings(),pair:ChannelPair = .rg)->SIMD2<Double>? {
        guard encodedRGB.x.isFinite,encodedRGB.y.isFinite,encodedRGB.z.isFinite else { return nil }
        let rgb=SIMD3(ColorMath.normalize(encodedRGB.x,levels:settings.levels),ColorMath.normalize(encodedRGB.y,levels:settings.levels),ColorMath.normalize(encodedRGB.z,levels:settings.levels))
        switch pair {
        case .rg:return SIMD2(rgb.x,rgb.y)
        case .rb:return SIMD2(rgb.x,rgb.z)
        case .gb:return SIMD2(rgb.y,rgb.z)
        case .yCb:return SIMD2(ColorMath.luma(rgb,space:settings.colorSpace),ColorMath.chroma(rgb,space:settings.colorSpace).x)
        case .yCr:return SIMD2(ColorMath.luma(rgb,space:settings.colorSpace),ColorMath.chroma(rgb,space:settings.colorSpace).y)
        case .cbCr:return ColorMath.chroma(rgb,space:settings.colorSpace)
        }
    }
    public static func analyze(frame:VideoFrame,settings:ScopeSettings=ScopeSettings(),plot:ChannelPlotSettings=ChannelPlotSettings(),selectionMask:ScopeSelectionMask?=nil)->ChannelPlotResult {
        let started=ProcessInfo.processInfo.systemUptime,w=512,h=512
        let xa=plot.pair.xAxis,ya=plot.pair.yAxis
        var counts=[UInt32](repeating:0,count:w*h),colors=[SIMD3<Float>](repeating:.zero,count:w*h)
        var bytes=[UInt8](repeating:0,count:w*h*4)
        for i in stride(from:3,to:bytes.count,by:4) { bytes[i]=255 }
        var samples=0,invalid=0,outside=0
        var minimum=SIMD2<Double>(repeating:.infinity),maximum=SIMD2<Double>(repeating: -.infinity)
        var sampled=false
        if frame.isValid {
            let roiRaster=settings.roiGeometry.raster(width:frame.width,height:frame.height)
            let roi=roiRaster.bounds
            let quality=max(16,min(960,settings.sampleWidth)),qualityHeight=max(9,Int(Double(quality)*9/16))
            let xs=max(1,Int(ceil(Double(roi.x1-roi.x0)/Double(quality)))),ys=max(1,Int(ceil(Double(roi.y1-roi.y0)/Double(qualityHeight))))
            sampled=xs>1 || ys>1
            if roi.x1>roi.x0 && roi.y1>roi.y0 {
                for y in stride(from:roi.y0,to:roi.y1,by:ys) { for x in stride(from:roi.x0,to:roi.x1,by:xs) {
                    guard roiRaster.contains(x:x,y:y) else { continue }
                    guard selectionMask?.includes(x:x,y:y,frameWidth:frame.width,frameHeight:frame.height) ?? true else { continue }
                    let i=(y*frame.width+x)*4,rgb=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
                    guard let p=project(encodedRGB:rgb,settings:settings,pair:plot.pair) else { invalid+=1;continue }
                    samples+=1;minimum=SIMD2(min(minimum.x,p.x),min(minimum.y,p.y));maximum=SIMD2(max(maximum.x,p.x),max(maximum.y,p.y))
                    let tolerance=settings.levels == .video ? 1e-7:0
                    if p.x<xa.minimum-tolerance || p.x>xa.maximum+tolerance || p.y<ya.minimum-tolerance || p.y>ya.maximum+tolerance { outside+=1 }
                    let nx=clamp((p.x-xa.minimum)/(xa.maximum-xa.minimum)),ny=clamp((p.y-ya.minimum)/(ya.maximum-ya.minimum))
                    let index=Int((1-ny)*Double(h-1))*w+Int(nx*Double(w-1))
                    counts[index]+=1
                    if plot.colorize {
                        let normalized=SIMD3(ColorMath.normalize(rgb.x,levels:settings.levels),ColorMath.normalize(rgb.y,levels:settings.levels),ColorMath.normalize(rgb.z,levels:settings.levels))
                        colors[index]+=SIMD3(Float(clamp(normalized.x)*0.8+0.2),Float(clamp(normalized.y)*0.8+0.2),Float(clamp(normalized.z)*0.8+0.2))
                    } else { colors[index]+=SIMD3(0.8,1,0.9) }
                }}
            }
        }
        let gain=settings.gain.isFinite ? max(0.05,min(20,settings.gain)):1.8
        for i in counts.indices where counts[i]>0 {
            let color=colors[i]/Float(counts[i]),intensity=min(1,log1p(Double(counts[i]))*0.24*gain)
            bytes[i*4]=UInt8((clamp(Double(color.x)*intensity)*255).rounded())
            bytes[i*4+1]=UInt8((clamp(Double(color.y)*intensity)*255).rounded())
            bytes[i*4+2]=UInt8((clamp(Double(color.z)*intensity)*255).rounded())
        }
        if samples==0 { minimum = .zero;maximum = .zero }
        return ChannelPlotResult(bitmap:ScopeBitmap(width:w,height:h,rgba:bytes),xAxis:xa,yAxis:ya,sampleCount:samples,invalidCount:invalid,outsidePlotCount:outside,minimum:minimum,maximum:maximum,sampled:sampled,transportDownsampled:frame.width != frame.sourceWidth || frame.height != frame.sourceHeight,sequence:frame.sequence,processingMS:(ProcessInfo.processInfo.systemUptime-started)*1000)
    }
    private static func clamp(_ v:Double)->Double { v.isFinite ? max(0,min(1,v)):0 }
}
