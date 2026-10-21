import Foundation

/// Density is separate from measurement. Plane boundaries isolate channels and
/// parade lanes throughout every optional spatial operation.
struct WaveformDensityPlane {
    let width:Int,height:Int,minX:Int,maxX:Int
    var counts:[Double]
    var colors:[SIMD3<Float>]
    var occupied:[Int]=[]
    init(width:Int,height:Int,minX:Int=0,maxX:Int?=nil) {
        self.width=width;self.height=height;self.minX=minX;self.maxX=maxX ?? width-1
        counts=[Double](repeating:0,count:width*height)
        colors=[SIMD3<Float>](repeating:.zero,count:width*height)
    }
    mutating func add(_ point:SIMD2<Double>,color:SIMD3<Float>,laneBounds:ClosedRange<Int>?=nil) {
        guard point.x.isFinite,point.y.isFinite,point.x>=0,point.x<=1,point.y>=0,point.y<=1 else { return }
        let lo=laneBounds?.lowerBound ?? minX,hi=laneBounds?.upperBound ?? maxX
        let px=min(Double(hi),max(Double(lo),point.x*Double(width-1)))
        let py=(1-point.y)*Double(height-1),x0=Int(px),y0=Int(py)
        let x1=min(hi,x0+1),y1=min(height-1,y0+1),fx=px-Double(x0),fy=py-Double(y0)
        // Bilinear area coverage preserves fractional code values and unit mass.
        // Bounds belong to the channel lane, so coverage cannot bleed into its neighbour.
        accumulate(y0*width+x0,color,(1-fx)*(1-fy))
        accumulate(y0*width+x1,color,fx*(1-fy))
        accumulate(y1*width+x0,color,(1-fx)*fy)
        accumulate(y1*width+x1,color,fx*fy)
    }
    private mutating func accumulate(_ i:Int,_ color:SIMD3<Float>,_ weight:Double) {
        guard weight>0 else {return}
        if counts[i] == 0 {occupied.append(i)}
        counts[i]+=weight;colors[i]+=color*Float(weight)
    }
}

/// Original trace rendering, not an emulation of a vendor's private shaders.
/// Fractional, energy-conserving coverage and per-channel optical density.
struct WaveformRenderer {
    let options:WaveformSettings
    let width:Int,height:Int
    private let channels:[String]
    private let separated:Bool
    private let tolerance:Double
    private struct Lane {
        let enabled:Bool,color:SIMD3<Float>,bounds:ClosedRange<Int>,origin:Double,extent:Double
    }
    private let lanes:[Lane]
    private let signalMinimum:Double,signalSpan:Double
    private let rasterize:Bool
    private var previous:[SIMD2<Double>?]
    private var minimum=SIMD4<Double>(repeating:.infinity),maximum=SIMD4<Double>(repeating:-.infinity)
    private(set) var planes:[WaveformDensityPlane]
    init(settings:WaveformSettings,levels:SignalLevels = .full,width:Int=1024,height:Int=512,rasterize:Bool=true) {
        let options=settings.effective,w=max(8,min(2048,width)),h=max(8,min(1024,height))
        let channels=options.mode.channels
        self.rasterize=rasterize
        let separated=options.traceLowPassRadius>0 || options.smoothTrace || options.enhanceEdges || options.enhancedRender || options.highlightEdges
        self.options=options;self.width=w;self.height=h;self.channels=channels;self.separated=separated
        previous=[SIMD2<Double>?](repeating:nil,count:channels.count)
        let bounds=options.signalBounds
        signalMinimum=bounds.lowerBound;signalSpan=bounds.upperBound-bounds.lowerBound
        lanes=channels.enumerated().map { lane,name in
            let enabled = !((name == "R" && !options.redEnabled) || (name == "G" && !options.greenEnabled) || (name == "B" && !options.blueEnabled))
            let lo=options.mode.isParade ? lane*w/channels.count:0
            let hi=options.mode.isParade ? (lane+1)*w/channels.count-1:w-1
            return Lane(enabled:enabled,color:Self.tint(name:name,options:options),bounds:lo...hi,
                        origin:Double(lo)/Double(w-1),extent:Double(hi-lo)/Double(w-1))
        }
        tolerance=(levels == .video ? 1e-7:1e-12)/(bounds.upperBound-bounds.lowerBound)
        planes=rasterize ? (0..<(separated ? channels.count:1)).map { lane in
            if separated && options.mode.isParade {
                return WaveformDensityPlane(width:w,height:h,minX:lane*w/channels.count,maxX:(lane+1)*w/channels.count-1)
            }
            return WaveformDensityPlane(width:w,height:h)
        } : []
    }
    mutating func beginRow() { breakContinuity() }
    mutating func breakContinuity() { for lane in previous.indices { previous[lane]=nil } }
    mutating func add(rgb:SIMD3<Double>,space:ColorSpace,horizontal:Double) {
        guard rgb.x.isFinite,rgb.y.isFinite,rgb.z.isFinite,horizontal.isFinite else { breakContinuity();return }
        let values=options.sampleValues(rgb:rgb,space:space)
        for lane in channels.indices {
            let geometry=lanes[lane]
            guard geometry.enabled else { previous[lane]=nil;continue }
            let value=values[lane]
            guard value.isFinite else { previous[lane]=nil;continue }
            minimum[lane]=min(minimum[lane],value);maximum[lane]=max(maximum[lane],value)
            if !rasterize {continue}
            let laneBounds=geometry.bounds,x=geometry.origin+horizontal*geometry.extent
            var y=(value-signalMinimum)/signalSpan
            // Display-only normalization tolerance for exact legal Float32
            // anchors; genuine out-of-window excursions are NOT clamped rails.
            if y<0,y >= -tolerance { y=0 };if y>1,y<=1+tolerance { y=1 }
            let point=SIMD2(x,y),color=geometry.color,plane=separated ? lane:0
            planes[plane].add(point,color:color,laneBounds:laneBounds)
            if options.enhancedRender,let prior=previous[lane] {
                let left=options.mode.isParade ? Double(lane)/Double(channels.count):0
                let right=options.mode.isParade ? Double(lane+1)/Double(channels.count):1
                if let segment=Self.clipSegment(prior,point,left:left,right:right) {
                    let dx=(segment.1.x-segment.0.x)*Double(width-1),dy=(segment.1.y-segment.0.y)*Double(height-1)
                    let steps=max(1,Int(ceil(max(abs(dx),abs(dy)))))
                    for step in 0...steps {
                        if (step == 0 && inside(prior,left:left,right:right)) || (step == steps && inside(point,left:left,right:right)) { continue }
                        planes[plane].add(segment.0+(segment.1-segment.0)*(Double(step)/Double(steps)),color:color,laneBounds:laneBounds)
                    }
                }
            }
            previous[lane]=point
        }
    }
    var peaks:[WaveformPeak] { channels.indices.map { WaveformPeak(channel:channels[$0],minimum:minimum[$0].isFinite ? minimum[$0]:nil,maximum:maximum[$0].isFinite ? maximum[$0]:nil) } }
    func bitmap(gain requestedGain:Double)->ScopeBitmap {
        guard rasterize else {return ScopeBitmap(width:1,height:1,rgba:[0,0,0,255])}
        var processed=planes
        for index in processed.indices {
            if options.traceLowPassRadius>0 { processed[index]=WaveformTraceProcessing.horizontalBlur(processed[index],radius:options.traceLowPassRadius) }
            if options.smoothTrace { processed[index]=WaveformTraceProcessing.smooth(processed[index]) }
            if options.enhanceEdges { processed[index]=WaveformTraceProcessing.enhance(processed[index]) }
        }
        // Avoid copying a full extra accumulator for the common single-plane path.
        var combined=processed[0]
        var edges=options.highlightEdges ? [Float](repeating:0,count:width*height):[]
        for (index,plane) in processed.enumerated() {
            if index>0 { for i in combined.counts.indices { combined.counts[i]+=plane.counts[i];combined.colors[i]+=plane.colors[i] } }
            if options.highlightEdges {
                let outline=WaveformTraceProcessing.outline(plane,thickness:options.edgeThickness)
                for i in edges.indices { edges[i]=max(edges[i],outline[i]) }
            }
        }
        let gain=requestedGain.isFinite ? min(20,max(0.05,requestedGain)):1
        let highlight=SIMD3(Double(options.edgeColor.red),Double(options.edgeColor.green),Double(options.edgeColor.blue))
        var bytes=[UInt8](repeating:0,count:width*height*4)
        for i in stride(from:3,to:bytes.count,by:4) { bytes[i]=255 }
        let requiresScan=options.traceLowPassRadius>0 || options.smoothTrace || options.enhanceEdges || options.highlightEdges || processed.count>1
        let indices=requiresScan ? Array(combined.counts.indices):combined.occupied
        for i in indices {
            let count=combined.counts[i]
            var color=SIMD3<Double>.zero
            if count>1e-12 {
                let radiance=combined.colors[i]
                // One shared shoulder preserves RGB ratios in dense regions;
                // independently clipping each channel would wash them white.
                let peak=Double(max(radiance.x,max(radiance.y,radiance.z)))
                let exposure=0.4*gain,factor=exposure/(1+peak*exposure)
                color=SIMD3(Double(radiance.x),Double(radiance.y),Double(radiance.z))*factor
            }
            if options.highlightEdges {
                let alpha=Double(edges[i])*Double(options.edgeColor.alpha)
                color=color*(1-alpha)+highlight*alpha
            }
            bytes[i*4]=Self.byte(color.x);bytes[i*4+1]=Self.byte(color.y);bytes[i*4+2]=Self.byte(color.z)
        }
        return ScopeBitmap(width:width,height:height,rgba:bytes)
    }
    private static func tint(name:String,options:WaveformSettings)->SIMD3<Float> {
        if !options.colorize { return SIMD3(repeating:1) }
        if options.mode == .yrgbOverlay,name == "Y′" {return SIMD3(repeating:1)}
        if options.trueRGBColors {
            if name == "R" { return SIMD3(1,0,0) };if name == "G" { return SIMD3(0,1,0) };if name == "B" { return SIMD3(0,0,1) }
        }
        if name == "R" || name == "Cr" { return SIMD3(1,0.19,0.24) }
        if name == "G" { return SIMD3(0.15,1,0.39) }
        if name == "B" || name == "Cb" { return SIMD3(0.22,0.48,1) }
        if options.mode == .luma { return SIMD3(0.82,1,0.9) }
        return SIMD3(0.65,1,0.82)
    }
    /// Liang–Barsky clipping against one lane's mathematical viewport. Outside
    /// endpoints can cross the view; they are never individually clamped to it.
    static func clipSegment(_ a:SIMD2<Double>,_ b:SIMD2<Double>,left:Double=0,right:Double=1)->(SIMD2<Double>,SIMD2<Double>)? {
        guard a.x.isFinite,a.y.isFinite,b.x.isFinite,b.y.isFinite else { return nil }
        let d=b-a;guard d.x.isFinite,d.y.isFinite else { return nil }
        var lo=0.0,hi=1.0
        for (p,q) in [(-d.x,a.x-left),(d.x,right-a.x),(-d.y,a.y),(d.y,1-a.y)] {
            if abs(p)<1e-15 { if q<0 { return nil };continue }
            let t=q/p
            if p<0 { lo=max(lo,t) } else { hi=min(hi,t) }
            if lo>hi { return nil }
        }
        var start=a+d*lo,end=a+d*hi
        // Arithmetic roundoff only, after geometric clipping.
        start=SIMD2(min(right,max(left,start.x)),Self.unit(start.y));end=SIMD2(min(right,max(left,end.x)),Self.unit(end.y))
        return (start,end)
    }
    private func inside(_ p:SIMD2<Double>,left:Double,right:Double)->Bool { p.x>=left && p.x<=right && p.y>=0 && p.y<=1 }
    private static func unit(_ v:Double)->Double { v.isFinite ? min(1,max(0,v)):0 }
    private static func byte(_ v:Double)->UInt8 { UInt8((unit(v)*255).rounded()) }
}

enum WaveformTraceProcessing {
    /// Fractional-radius blend of integer box kernels. At boundaries each
    /// source's truncated kernel is normalized, conserving total density mass.
    /// Difference rows keep cost O(plot pixels), even at radius 20.
    static func horizontalBlur(_ input:WaveformDensityPlane,radius:Double)->WaveformDensityPlane {
        let radius=radius.isFinite ? min(20,max(0,radius)):0
        guard radius>0 else { return input }
        let base=Int(floor(radius)),fraction=radius-Double(base)
        var output=empty(input)
        for y in 0..<input.height {
            var counts=[Double](repeating:0,count:input.width+1),colors=[SIMD3<Float>](repeating:.zero,count:input.width+1)
            for x in input.minX...input.maxX {
                let i=y*input.width+x;guard input.counts[i]>0 else { continue }
                for (r,weight) in [(base,1-fraction),(base+1,fraction)] where weight>0 {
                    let low=max(input.minX,x-r),high=min(input.maxX,x+r),factor=weight/Double(high-low+1)
                    let count=input.counts[i]*factor,color=input.colors[i]*Float(factor)
                    counts[low]+=count;counts[high+1]-=count;colors[low]+=color;colors[high+1]-=color
                }
            }
            var count=0.0,color=SIMD3<Float>.zero
            for x in input.minX...input.maxX {
                count+=counts[x];color+=colors[x]
                let i=y*input.width+x
                if count>1e-12 { output.counts[i]=count;output.colors[i]=SIMD3(max(0,color.x),max(0,color.y),max(0,color.z)) }
            }
        }
        return output
    }
    static func smooth(_ input:WaveformDensityPlane)->WaveformDensityPlane { binomial(binomial(input,horizontal:true),horizontal:false) }
    static func enhance(_ input:WaveformDensityPlane)->WaveformDensityPlane {
        let low=smooth(input)
        var output=input
        for i in input.counts.indices where input.counts[i]>1e-12 {
            let count=input.counts[i],boost=0.8*max(0,count-low.counts[i]),factor=1+boost/count
            output.counts[i]=count+boost;output.colors[i]=input.colors[i]*Float(factor)
        }
        return output
    }
    static func outline(_ input:WaveformDensityPlane,thickness:Double)->[Float] {
        let t=thickness.isFinite ? min(3,max(0.5,thickness)):1,radius=max(0,Int(ceil(t))-1)
        var result=[Float](repeating:0,count:input.counts.count)
        func occupied(_ x:Int,_ y:Int)->Bool { x>=input.minX && x<=input.maxX && y>=0 && y<input.height && input.counts[y*input.width+x]>1e-9 }
        for y in 0..<input.height { for x in input.minX...input.maxX {
            guard occupied(x,y),!occupied(x-1,y) || !occupied(x+1,y) || !occupied(x,y-1) || !occupied(x,y+1) else { continue }
            for dy in -radius...radius { for dx in -radius...radius {
                let px=x+dx,py=y+dy
                guard px>=input.minX,px<=input.maxX,py>=0,py<input.height else { continue }
                let coverage=Float(min(1,max(0,t-Double(max(abs(dx),abs(dy))))))
                result[py*input.width+px]=max(result[py*input.width+px],coverage)
            }}
        }}
        return result
    }
    private static func binomial(_ input:WaveformDensityPlane,horizontal:Bool)->WaveformDensityPlane {
        var output=empty(input)
        for y in 0..<input.height { for x in input.minX...input.maxX {
            let i=y*input.width+x;guard input.counts[i]>0 else { continue }
            var normalization=0.0
            for d in -1...1 {
                let px=horizontal ? x+d:x,py=horizontal ? y:y+d
                if px>=input.minX,px<=input.maxX,py>=0,py<input.height { normalization+=d == 0 ? 0.5:0.25 }
            }
            for d in -1...1 {
                let px=horizontal ? x+d:x,py=horizontal ? y:y+d
                guard px>=input.minX,px<=input.maxX,py>=0,py<input.height else { continue }
                let weight=(d == 0 ? 0.5:0.25)/normalization,j=py*input.width+px
                output.counts[j]+=input.counts[i]*weight;output.colors[j]+=input.colors[i]*Float(weight)
            }
        }}
        return output
    }
    private static func empty(_ p:WaveformDensityPlane)->WaveformDensityPlane { WaveformDensityPlane(width:p.width,height:p.height,minX:p.minX,maxX:p.maxX) }
}
