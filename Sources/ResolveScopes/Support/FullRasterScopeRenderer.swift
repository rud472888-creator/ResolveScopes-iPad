import Foundation
import Metal
#if canImport(ScopeCore)
import ScopeCore
#endif

enum FullRasterScopeKind:String,Hashable,Sendable {case waveform,parade,vectorscope,falseColor}

struct FullRasterScopeRequest:Equatable,Sendable {
    var width:Int=1536,height:Int=768
    var viewport=WaveformViewport()
    init(width:Int=1536,height:Int=768,viewport:WaveformViewport = .init()) {
        self.width=max(256,min(3072,((width+31)/64)*64))
        self.height=max(256,min(2048,((height+31)/64)*64))
        self.viewport=viewport.effective
    }
}
/// One registration per visible view, including detached windows. Linked
/// panels share statistics but must never overwrite another view's camera.
struct FullRasterScopeRegistration:Equatable {
    let kind:FullRasterScopeKind
    let request:FullRasterScopeRequest
}
struct FullRasterScopeBatch {
    var requests:[FullRasterScopeKind:FullRasterScopeRequest]=[:]
    var owners:[FullRasterScopeKind:[UUID]]=[:]
    static func make(registrations:[UUID:FullRasterScopeRegistration],active:Set<FullRasterScopeKind>)->[Self] {
        var batches=[Self]()
        for (id,item) in registrations.sorted(by:{$0.key.uuidString<$1.key.uuidString}) where active.contains(item.kind) {
            let index=batches.firstIndex{$0.requests[item.kind] == item.request}
                ?? batches.firstIndex{$0.requests[item.kind] == nil}
                ?? batches.count
            if index == batches.count {batches.append(Self())}
            batches[index].requests[item.kind]=item.request
            batches[index].owners[item.kind,default:[]].append(id)
        }
        for kind in [FullRasterScopeKind.waveform,.parade,.vectorscope,.falseColor] where active.contains(kind) && !batches.contains(where:{$0.requests[kind] != nil}) {
            if batches.isEmpty {batches.append(Self())}
            batches[0].requests[kind] = kind == .vectorscope ? .init(width:1024,height:1024):.init()
        }
        return batches
    }
}
struct FullRasterScopeRender {
    var falseColor:ScopeBitmap?=nil
    var wave:ScopeBitmap?,parade:ScopeBitmap?,vectors:[String:ScopeBitmap]=[:]
    let receivedPixels:Int
    let elapsedMS:Double
    let densityFormat:String
}

/// Shared desktop/iPad full received Float raster. Fractional bilinear coverage, 32-bit
/// atomic density and a separate display pass. No analysis-grid decimation.
/// Queue work and readback happen on the store's worker, never the main thread.
final class FullRasterScopeRenderer:@unchecked Sendable {
    private static let availability:Result<FullRasterScopeRenderer,Error> = Result{try FullRasterScopeRenderer()}
    static var shared:FullRasterScopeRenderer? {try? availability.get()}
    static var failureReason:String? {if case .failure(let error)=availability {return String(describing:error)};return nil}
    let device:MTLDevice
    private let queue:MTLCommandQueue,accumulate:MTLComputePipelineState,display:MTLComputePipelineState,falseColorPipeline:MTLComputePipelineState
    private let lock=NSLock()
    private struct Surfaces {let density:MTLBuffer,output:MTLTexture}
    private var surfaces:[String:Surfaces]=[:]
    private var inputCache:MTLBuffer?
    private var falseColorTexture:MTLTexture?
    private struct FalseColorUniforms {var geometry:SIMD4<UInt32>,weights:SIMD4<Float>,options:SIMD4<Float>,fallback:SIMD4<Float>}
    private struct FalseColorBand {var bounds:SIMD4<Float>,color:SIMD4<Float>}
    // All fields are float4 to make Swift/MSL ABI alignment explicit.
    private struct Uniforms {
        var raster:SIMD4<Float>,roi:SIMD4<Float>,mask:SIMD4<Float>,weights:SIMD4<Float>
        var signal:SIMD4<Float>,viewport:SIMD4<Float>,style:SIMD4<Float>,vector:SIMD4<Float>,bands:SIMD4<Float>,gains:SIMD4<Float>
    }
    enum Failure:Error {case unavailable,allocation,invalidMask,command(String)}
    init() throws {
        guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else {throw Failure.unavailable}
        device=d;queue=q
        let library=try d.makeLibrary(source:Self.source,options:nil)
        accumulate=try d.makeComputePipelineState(function:library.makeFunction(name:"scopeAccumulate")!)
        display=try d.makeComputePipelineState(function:library.makeFunction(name:"scopeDisplay")!)
        falseColorPipeline=try d.makeComputePipelineState(function:library.makeFunction(name:"falseColorDisplay")!)
    }
    static func supports(_ waveform:WaveformSettings)->Bool {
        let w=waveform.effective
        return !w.signalLowPass && w.traceLowPassRadius == 0 && !w.smoothTrace && !w.enhanceEdges && !w.enhancedRender && !w.highlightEdges
    }
    func render(frame:VideoFrame,settings:ScopeSettings,waveform:WaveformSettings,vector:VectorScopeSettings,
                selection:ScopeSelectionMask?,requests:[FullRasterScopeKind:FullRasterScopeRequest],falseColor:FalseColorMapping = .defaultIRE,falseColorZone:Double?=nil,smoothFalseColor:Bool=false,presentation:FalseColorPresentation?=nil) throws -> FullRasterScopeRender {
        guard frame.isValid,frame.width*frame.height<=64_000_000 else {throw Failure.allocation}
        if let selection,!selection.isValid {throw Failure.invalidMask}
        lock.lock();defer{lock.unlock()}
        let byteCount=frame.rgba.count*MemoryLayout<Float>.stride
        guard let input=(inputCache.flatMap{$0.length>=byteCount ? $0:nil} ?? device.makeBuffer(length:byteCount,options:.storageModeShared)) else {throw Failure.allocation}
        frame.rgba.withUnsafeBytes {input.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count)}
        if byteCount<=160*1024*1024 {inputCache=input}
        return try renderLocked(input:input,width:frame.width,height:frame.height,settings:settings,waveform:waveform,vector:vector,selection:selection,requests:requests,falseColor:falseColor,falseColorZone:falseColorZone,smoothFalseColor:smoothFalseColor,presentation:presentation)
    }
    /// Input is GPU-produced encoded Float32 RGBA; no CPU full-frame conversion.
    func render(input:MTLBuffer,width:Int,height:Int,settings:ScopeSettings,waveform:WaveformSettings,vector:VectorScopeSettings,
                selection:ScopeSelectionMask?=nil,requests:[FullRasterScopeKind:FullRasterScopeRequest],falseColor:FalseColorMapping = .defaultIRE,falseColorZone:Double?=nil,smoothFalseColor:Bool=false,presentation:FalseColorPresentation?=nil) throws -> FullRasterScopeRender {
        guard width>0,height>0,width<=16384,height<=16384,width*height<=64_000_000,input.length>=width*height*16 else {throw Failure.allocation}
        if let selection,!selection.isValid {throw Failure.invalidMask}
        lock.lock();defer{lock.unlock()}
        return try renderLocked(input:input,width:width,height:height,settings:settings,waveform:waveform,vector:vector,selection:selection,requests:requests,falseColor:falseColor,falseColorZone:falseColorZone,smoothFalseColor:smoothFalseColor,presentation:presentation)
    }
    private func renderLocked(input:MTLBuffer,width:Int,height:Int,settings:ScopeSettings,waveform:WaveformSettings,vector:VectorScopeSettings,
                              selection:ScopeSelectionMask?,requests:[FullRasterScopeKind:FullRasterScopeRequest],falseColor:FalseColorMapping = .defaultIRE,falseColorZone:Double?=nil,smoothFalseColor:Bool=false,presentation:FalseColorPresentation?=nil) throws -> FullRasterScopeRender {
        let started=ProcessInfo.processInfo.systemUptime
        guard let command=queue.makeCommandBuffer() else {throw Failure.allocation}
        let validMask=selection?.isValid == true ? selection:nil
        let maskData=validMask?.values ?? [255]
        guard let maskBuffer=maskData.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw Failure.allocation}
        let bounds=settings.roiGeometry.raster(width:width,height:height).bounds
        var original=settings.roi ?? NormalizedRect(x:0,y:0,width:1,height:1)
        if ![original.x,original.y,original.width,original.height].allSatisfy(\.isFinite) {original=NormalizedRect(x:0,y:0,width:1,height:1)}
        let weights=ColorMath.lumaWeights(settings.colorSpace),v=vector.effective
        var jobs=[(String,FullRasterScopeKind,FullRasterScopeRequest,WaveformSettings,Int)]()
        if let request=requests[.waveform],Self.supports(waveform) {jobs.append(("wave",.waveform,request,waveform.effective,0))}
        if let request=requests[.parade] {var p=WaveformSettings();p.mode = .rgbParade;p.trueRGBColors=true;jobs.append(("parade",.parade,request,p,0))}
        if let request=requests[.vectorscope] {
            jobs.append(("combined",.vectorscope,request,waveform,0))
            if v.splitHML {for (i,name) in ["Low","Mid","High"].enumerated() {jobs.append((name,.vectorscope,request,waveform,i+1))}}
        }
        var outputs=[String:Surfaces]()
        for (name,kind,size,w,band) in jobs {
            let key="\(name)-\(size.width)x\(size.height)"
            let target:Surfaces
            if let cached=surfaces[key] {target=cached}
            else {
                let output=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:size.width,height:size.height,mipmapped:false)
                output.storageMode = .shared;output.usage=[.shaderWrite]
                guard let a=device.makeBuffer(length:size.width*size.height*16,options:.storageModePrivate),let b=device.makeTexture(descriptor:output) else {throw Failure.allocation}
                target=Surfaces(density:a,output:b)
                // Bound scratch memory by bytes as well as key count. A large
                // detached window must not leave many old Retina targets alive.
                let cachedBytes=surfaces.values.reduce(0){$0+$1.density.length+$1.output.width*$1.output.height*4}
                if surfaces.count>=10 || cachedBytes+a.length+size.width*size.height*4>192*1024*1024 {surfaces.removeAll()}
                surfaces[key]=target
            }
            let mode:Float
            switch w.mode {case .luma:mode=0;case .rgbOverlay:mode=1;case .rgbParade:mode=2;case .yrgbParade:mode=3;case .yCbCrParade:mode=4;case .yrgbOverlay:mode=5}
            let range=w.signalBounds,view=size.viewport.effective
            var flags:Float=0
            if w.colorize {flags+=1};if w.trueRGBColors {flags+=2}
            var enabled:Float=0;if w.redEnabled {enabled+=1};if w.greenEnabled {enabled+=2};if w.blueEnabled {enabled+=4}
            var u=Uniforms(raster:SIMD4(Float(width),Float(height),Float(size.width),Float(size.height)),
                roi:SIMD4(Float(bounds.x0),Float(bounds.y0),Float(bounds.x1),Float(bounds.y1)),
                mask:SIMD4(Float(validMask?.width ?? 0),Float(validMask?.height ?? 0),settings.roiShape == .ellipse ? 1:0,settings.levels == .video ? 1:0),
                weights:SIMD4(Float(weights.x),Float(weights.y),Float(weights.z),Float(settings.vectorZoom.isFinite ? min(8,max(0.1,settings.vectorZoom)):1)),
                signal:SIMD4(Float(range.lowerBound),Float(range.upperBound-range.lowerBound),mode,Float(flags)),
                viewport:SIMD4(Float(view.centerX),Float(view.centerY),Float(view.zoomX),Float(view.zoomY)),
                style:SIMD4(kind == .vectorscope ? 1:0,Float(settings.gain.isFinite ? min(20,max(0.05,settings.gain)):1.8),enabled,Float(band)),
                vector:SIMD4(v.mode == .hsl ? 1:0,v.colorize ? 1:0,Float(v.centerBoost),v.splitHML ? 1:0),
                bands:SIMD4(Float(v.lowThreshold),Float(v.highThreshold),Float(original.x),Float(original.y)),
                gains:SIMD4(Float(v.lowGain),Float(v.midGain),Float(v.highGain),0))
            // Fixed-point density precision adapts to an exact overflow bound.
            // This quantizes contribution weight, not input signal coordinates.
            var fixed:Float=1024
            while Double(fixed)*Double(width*height)>Double(UInt32.max) {fixed/=2}
            let vectorMaximum=max(1,(1+Float(v.centerBoost))*(v.splitHML ? Float(max(v.lowGain,max(v.midGain,v.highGain))):1))
            u.gains.w=fixed
            // Ellipse dimensions are separate from its clipped raster bounds.
            var ellipse=SIMD4(Float(original.x),Float(original.y),Float(original.width),Float(original.height))
            guard let clear=command.makeBlitCommandEncoder() else {throw Failure.allocation}
            clear.fill(buffer:target.density,range:0..<target.density.length,value:0);clear.endEncoding()
            guard let encoder=command.makeComputeCommandEncoder() else {throw Failure.allocation}
            encoder.setComputePipelineState(accumulate);encoder.setBuffer(input,offset:0,index:0);encoder.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1)
            encoder.setBuffer(maskBuffer,offset:0,index:2);encoder.setBytes(&ellipse,length:16,index:3)
            encoder.setBuffer(target.density,offset:0,index:4)
            var maxContribution=vectorMaximum;encoder.setBytes(&maxContribution,length:4,index:5)
            encoder.dispatchThreads(MTLSize(width:width*height,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1))
            encoder.endEncoding()
            guard let compute=command.makeComputeCommandEncoder() else {throw Failure.allocation}
            compute.setComputePipelineState(display);compute.setBuffer(target.density,offset:0,index:1);compute.setTexture(target.output,index:1)
            // Normalize density by evaluated ROI area and display area, so
            // full-raster input does not simply blow the whole trace to white.
            let selectedArea=max(1,bounds.width*bounds.height)
            let gain=Float(settings.gain.isFinite ? min(20,max(0.05,settings.gain)):1.8)
            let normalization=min(Float(1),Float(640*360)/Float(selectedArea))
            let area=Float(size.width*size.height)/Float(1024*512)
            var exposure=SIMD4<Float>(gain*0.4*normalization*area,0,0,0)
            exposure.x *= kind == .vectorscope ? u.weights.w*u.weights.w*Float(view.zoomX*view.zoomY):Float(view.zoomX*view.zoomY)
            exposure.y=fixed;exposure.z=kind == .vectorscope ? vectorMaximum:1
            compute.setBytes(&exposure,length:16,index:0);compute.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:2)
            compute.dispatchThreads(MTLSize(width:size.width,height:size.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));compute.endEncoding()
            outputs[name]=target
        }
        // One output pixel per received pixel: false color never uses the numeric sample grid.
        var fc:MTLTexture?
        if requests[.falseColor] != nil {
            try falseColor.validate()
            let style=presentation ?? .init(mode:falseColorZone == nil ? .original:.tvLogic,target:falseColorZone ?? 55,span:25)
            let displayZones=style.mode != .original
            let colorBands=displayZones ? style.bands:falseColor.ranges
            let t:MTLTexture
            if let cached=falseColorTexture,cached.width==width,cached.height==height {t=cached}
            else {
                let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
                desc.storageMode = .shared;desc.usage=[.shaderWrite]
                guard let made=device.makeTexture(descriptor:desc) else {throw Failure.allocation}
                t=made;falseColorTexture=made
            }
            let measurement:UInt32
            switch (displayZones ? FalseColorMeasurement.encodedIRE:falseColor.measurement) {case .encodedIRE:measurement=0;case .nits:measurement=1;case .hue:measurement=2;case .saturation:measurement=3}
            let transfer=TransferFunction.allCases.firstIndex(of:settings.transfer)!
            var u=FalseColorUniforms(geometry:SIMD4(UInt32(width),UInt32(height),UInt32(colorBands.count),measurement),
                weights:SIMD4(Float(weights.x),Float(weights.y),Float(weights.z),settings.levels == .video ? 1:0),
                options:SIMD4(Float(transfer),displayZones ? 1:-1,smoothFalseColor ? 1:0,0),
                fallback:SIMD4(falseColor.fallback.red,falseColor.fallback.green,falseColor.fallback.blue,falseColor.fallback.alpha))
            let bands=colorBands.map {FalseColorBand(bounds:SIMD4(Float($0.lowerBound ?? -.infinity),Float($0.upperBound ?? .infinity),0,0),color:SIMD4($0.color.red,$0.color.green,$0.color.blue,$0.color.alpha))}
            guard let encoder=command.makeComputeCommandEncoder() else {throw Failure.allocation}
            encoder.setComputePipelineState(falseColorPipeline);encoder.setBuffer(input,offset:0,index:0)
            encoder.setBytes(&u,length:MemoryLayout<FalseColorUniforms>.stride,index:1)
            let safeBands=bands.isEmpty ? [FalseColorBand(bounds:.zero,color:.zero)]:bands
            guard let bandBuffer=safeBands.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw Failure.allocation}
            encoder.setBuffer(bandBuffer,offset:0,index:2)
            encoder.setBuffer(maskBuffer,offset:0,index:3)
            var maskSize=SIMD2<UInt32>(UInt32(validMask?.width ?? 0),UInt32(validMask?.height ?? 0))
            encoder.setBytes(&maskSize,length:8,index:4);encoder.setTexture(t,index:0)
            encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));encoder.endEncoding();fc=t
        }
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else {throw Failure.command(command.error?.localizedDescription ?? "GPU command failed")}
        var plots=[String:ScopeBitmap]()
        for (name,target) in outputs {
            let t=target.output;var bytes=[UInt8](repeating:0,count:t.width*t.height*4)
            bytes.withUnsafeMutableBytes {t.getBytes($0.baseAddress!,bytesPerRow:t.width*4,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)}
            plots[name]=ScopeBitmap(width:t.width,height:t.height,rgba:bytes)
        }
        let wave=plots.removeValue(forKey:"wave"),parade=plots.removeValue(forKey:"parade")
        var fcBitmap:ScopeBitmap?
        if let t=fc {
            var bytes=[UInt8](repeating:0,count:width*height*4)
            bytes.withUnsafeMutableBytes {t.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)}
            fcBitmap=ScopeBitmap(width:width,height:height,rgba:bytes)
        }
        return FullRasterScopeRender(falseColor:fcBitmap,wave:wave,parade:parade,vectors:plots,receivedPixels:width*height,elapsedMS:(ProcessInfo.processInfo.systemUptime-started)*1000,densityFormat:"UInt32 density · Float32 signal")
    }
    private static let source = [("LINEAR",TransferFunction.linear),("GAMMA18",TransferFunction.gamma18),("GAMMA22",TransferFunction.gamma22),("GAMMA24",TransferFunction.gamma24),("GAMMA26",TransferFunction.gamma26),("ADOBE",TransferFunction.adobeRGB),("SRGB",TransferFunction.sRGB),("PROPHOTO",TransferFunction.proPhoto),("ACESCC",TransferFunction.acescc),("ACESCCT",TransferFunction.acescct),("PQ",TransferFunction.pq),("HLG",TransferFunction.hlg)].map {"#define T_\($0.0) \(TransferFunction.allCases.firstIndex(of:$0.1)!)"}.joined(separator:"\n") + "\n" + #"""
    #include <metal_stdlib>
    using namespace metal;

    struct FCU {uint4 geometry;float4 weights,options,fallback;};
    struct FCBand {float4 bounds,color;};
    float fcLinear(float value,uint transfer) {
        float v=max(0.f,value);
        switch(transfer) {
        case T_LINEAR:return value;
        case T_GAMMA18:return pow(v,1.8f);case T_GAMMA22:return pow(v,2.2f);case T_GAMMA24:return pow(v,2.4f);case T_GAMMA26:return pow(v,2.6f);
        case T_ADOBE:return pow(v,563.f/256);
        case T_SRGB:return v<=.04045f?v/12.92f:pow((v+.055f)/1.055f,2.4f);
        case T_PROPHOTO:return abs(value)<=16.f/512?value/16:copysign(pow(abs(value),1.8f),value);
        case T_ACESCC:return value>=(log2(65504.f)+9.72f)/17.52f?65504.f:(value<=(9.72f-15)/17.52f?(exp2(value*17.52f-9.72f)-exp2(-16.f))*2:exp2(value*17.52f-9.72f));
        case T_ACESCCT:return value<=.15525114155f?(value-.0729055342f)/10.54023774f:(value>=(log2(65504.f)+9.72f)/17.52f?65504.f:exp2(value*17.52f-9.72f));
        case T_PQ:{float p=pow(min(v,1.f),32.f/2523);return pow(max(p-3424.f/4096,0.f)/max(2413.f/128-2392.f/128*p,1e-12f),16384.f/2610);}
        case T_HLG:{v=clamp(v,0.f,1.f);return v<=.5f?v*v/3:(exp((v-.55991073f)/.17883277f)+.28466892f)/12;}
        }return v;
    }
    float3 fcRGB(device const float4 *pixels,uint2 at,constant FCU &u) {
        float3 rgb=pixels[at.y*u.geometry.x+at.x].rgb;
        return u.weights.w>0?(rgb*1023-64)/876:rgb;
    }
    kernel void falseColorDisplay(device const float4 *pixels [[buffer(0)]],constant FCU &u [[buffer(1)]],
        device const FCBand *bands [[buffer(2)]],device const uchar *mask [[buffer(3)]],constant uint2 &maskSize [[buffer(4)]],
        texture2d<float,access::write> output [[texture(0)]],uint2 at [[thread_position_in_grid]]) {
        if(any(at>=u.geometry.xy))return;
        if(maskSize.x>0&&mask[min(maskSize.y-1,at.y*maskSize.y/u.geometry.y)*maskSize.x+min(maskSize.x-1,at.x*maskSize.x/u.geometry.x)]==0) {output.write(float4(0,0,0,1),at);return;}
        float3 rgb=fcRGB(pixels,at,u);float4 color=u.fallback;
        if(!all(isfinite(rgb))) {output.write(color,at);return;}
        float luma=dot(rgb,u.weights.xyz);
        // Edge-aware display-only cleanup. 1 IRE noise is averaged; real edges
        // and isolated highlights remain. Measurements and other scopes use raw RGB.
        if(u.options.z>0&&(u.geometry.w==0||u.options.y>=0)) {
            float sum=0,weight=0;
            for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
                uint2 p=uint2(clamp(int2(at)+int2(x,y),int2(0),int2(u.geometry.xy)-1));
                float sample=dot(fcRGB(pixels,p,u),u.weights.xyz);
                float d=(sample-luma)/.01f,w=exp(-.5f*d*d)*(x==0?2:1)*(y==0?2:1);
                if(isfinite(sample)){sum+=sample*w;weight+=w;}
            }
            if(weight>0)luma=sum/weight;
        }
        if(u.options.y>=0) {
            float ire=luma*100;
            color=float4(float3(clamp(luma,0.f,1.f)),1);
            if(isfinite(ire))for(uint i=0;i<u.geometry.z;i++)if(ire>=bands[i].bounds.x&&ire<bands[i].bounds.y){color=bands[i].color;break;}
        }else {
            float value=luma*100;
            if(u.geometry.w==1) {
                uint t=uint(u.options.x);float3 linear=float3(fcLinear(rgb.r,t),fcLinear(rgb.g,t),fcLinear(rgb.b,t));
                float y=dot(linear,u.weights.xyz);if(t==T_HLG)y*=pow(max(y,0.f),.2f);
                value=y*(t==T_PQ?10000:(t==T_HLG?1000:100));
            }else if(u.geometry.w>=2) {
                float3 c=max(rgb,0.f);float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo;
                float saturation=hi>0?d/hi:0,h=0;
                if(d>1e-12f){if(hi==c.r){h=(c.g-c.b)/d;if(h<0)h+=6;}else if(hi==c.g)h=(c.b-c.r)/d+2;else h=(c.r-c.g)/d+4;}
                if(u.geometry.w==2&&saturation<=1e-12f){output.write(color,at);return;}
                value=u.geometry.w==2?h/6*100:saturation*100;
            }
            if(isfinite(value))for(uint i=0;i<u.geometry.z;i++)if(value>=bands[i].bounds.x&&value<bands[i].bounds.y){color=bands[i].color;break;}
        }
        output.write(color,at);
    }
    struct U {float4 raster,roi,mask,weights,signal,viewport,style,vector,bands,gains;};
    struct PlotSample {float2 point;float3 color;float2 lane;};
    PlotSample scopePoint(uint id,uint lane,device const float4 *pixels,constant U &u,device const uchar *mask,constant float4 &ellipse) {
        PlotSample o;o.point=float2(-100);o.color=0;o.lane=float2(0,u.raster.z);
        uint x=id%uint(u.raster.x),y=id/uint(u.raster.x);
        if(x<u.roi.x||x>=u.roi.z||y<u.roi.y||y>=u.roi.w)return o;
        if(u.mask.z>0) {float2 p=((float2(x,y)+.5)/u.raster.xy-ellipse.xy)/max(ellipse.zw,float2(1e-12));if(dot(p*2-1,p*2-1)>1)return o;}
        if(u.mask.x>0) {uint mx=min(uint(u.mask.x)-1,x*uint(u.mask.x)/uint(u.raster.x)),my=min(uint(u.mask.y)-1,y*uint(u.mask.y)/uint(u.raster.y));if(mask[my*uint(u.mask.x)+mx]==0)return o;}
        float3 rgb=pixels[id].rgb;if(!all(isfinite(rgb)))return o;
        if(u.mask.w>0)rgb=(rgb*1023-64)/876;
        if(!all(isfinite(rgb)))return o;
        float luma=dot(rgb,u.weights.xyz),horizontal=float(x-uint(u.roi.x))/max(1.f,u.roi.z-u.roi.x-1);
        float2 p;float3 color=1;
        if(u.style.x>0) {
            int band=luma<u.bands.x?0:(luma<u.bands.y?1:2);if(u.style.w>0&&int(u.style.w)-1!=band)return o;
            float2 chroma;
            if(u.vector.x>0) {
                float3 c=clamp(rgb,0.f,1.f);float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo,light=(hi+lo)*.5;
                float h=0,s=d>1e-12?d/(1-abs(2*light-1)):0;
                if(d>1e-12) {if(hi==c.r)h=fmod((c.g-c.b)/d+6,6.f);else if(hi==c.g)h=(c.b-c.r)/d+2;else h=(c.r-c.g)/d+4;h/=6;}
                float angle=(103+h*360)*M_PI_F/180;chroma=float2(cos(angle),sin(angle))*s*.5;
            } else chroma=float2((rgb.b-luma)/(2*(1-u.weights.z)),(rgb.r-luma)/(2*(1-u.weights.x)));
            p=(.5+chroma*.88*u.weights.w-u.viewport.xy)*u.viewport.zw+.5;
            color=u.vector.y>0?clamp(rgb,0.f,1.f)*.8+.2:float3(.8,1,.9);
            float radius=length(chroma)*2,boost=1+u.vector.z*exp(-pow(radius/.25,2.f));
            color*=boost*(u.vector.w>0?u.gains[band]:1);
        } else {
            int mode=int(u.signal.z);int channel=mode==0?3:((mode==3||mode==5)?(lane==0?3:int(lane)-1):int(lane));
            if(mode==4)channel=lane==0?3:(lane==1?4:5);
            if(channel>=0&&channel<3&&!(int(u.style.z)&(1<<channel)))return o;
            float value=channel==3?luma:(channel==4?.5+(rgb.b-luma)/(2*(1-u.weights.z)):(channel==5?.5+(rgb.r-luma)/(2*(1-u.weights.x)):rgb[max(0,channel)]));
            float signal=(value-u.signal.x)/u.signal.y;
            if(signal<0&&signal>-1e-6)signal=0;if(signal>1&&signal<1+1e-6)signal=1;
            // Window excursions are omitted; a viewport zoom may bring admitted
            // base-window samples into view, never paint them on a clamp rail.
            if(signal<0||signal>1)return o;
            float nx=horizontal;
            if(mode>=2&&mode<=4) {uint count=mode==3?4:3;float lo=floor(float(lane)*u.raster.z/count),hi=floor(float(lane+1)*u.raster.z/count)-1;nx=(lo+horizontal*(hi-lo))/(u.raster.z-1);o.lane=float2(lo,hi+1);}
            p=float2(nx,signal);p=(p-u.viewport.xy)*u.viewport.zw+.5;
            if(int(u.signal.w)&1) {
                if(channel==0||channel==5)color=(int(u.signal.w)&2)?float3(1,0,0):float3(1,.19,.24);
                else if(channel==1)color=(int(u.signal.w)&2)?float3(0,1,0):float3(.15,1,.39);
                else if(channel==2||channel==4)color=(int(u.signal.w)&2)?float3(0,0,1):float3(.22,.48,1);
                else color=float3(1);
            }
        }
        if(any(p<0)||any(p>1))return o;
        o.point=p;o.color=color;return o;
    }
    void atomicContribution(device atomic_uint *bins,uint index,uint value) {
        if(simd_all(index==simd_broadcast_first(index))) {
            uint total=simd_sum(value);if(simd_is_first())atomic_fetch_add_explicit(bins+index,total,memory_order_relaxed);
        } else atomic_fetch_add_explicit(bins+index,value,memory_order_relaxed);
    }
    kernel void scopeAccumulate(device const float4 *pixels [[buffer(0)]],constant U &u [[buffer(1)]],device const uchar *mask [[buffer(2)]],constant float4 &ellipse [[buffer(3)]],device atomic_uint *bins [[buffer(4)]],constant float &maximum [[buffer(5)]],uint id [[thread_position_in_grid]]) {
        if(id>=uint(u.raster.x)*uint(u.raster.y))return;
        int channels=u.style.x>0?1:(int(u.signal.z)==0?1:((int(u.signal.z)==3||int(u.signal.z)==5)?4:3));
        for(int lane=0;lane<channels;lane++) {
            PlotSample point=scopePoint(id,lane,pixels,u,mask,ellipse);
            float2 p=point.point;if(any(p<0)||any(p>1)||!all(isfinite(p)))continue;
            float2 xy=float2(p.x,1-p.y)*(u.raster.zw-1);uint2 base=uint2(xy);float2 f=fract(xy);
            for(uint dy=0;dy<2;dy++)for(uint dx=0;dx<2;dx++) {
                uint2 at=min(base+uint2(dx,dy),uint2(u.raster.zw)-1);
                if(u.style.x==0&&int(u.signal.z)>=2&&int(u.signal.z)<=4) {
                    float lo=((point.lane.x/(u.raster.z-1)-u.viewport.x)*u.viewport.z+.5)*(u.raster.z-1);
                    float hi=(((point.lane.y-1)/(u.raster.z-1)-u.viewport.x)*u.viewport.z+.5)*(u.raster.z-1);
                    if(at.x<ceil(lo)||at.x>floor(hi))continue;
                }
                float weight=(dx?f.x:1-f.x)*(dy?f.y:1-f.y);
                uint index=(at.y*uint(u.raster.z)+at.x)*4;
                if(u.style.x>0) {
                    float3 color=point.color/maximum;
                    for(uint channel=0;channel<3;channel++)atomicContribution(bins,index+channel,uint(round(weight*color[channel]*u.gains.w)));
                }else atomicContribution(bins,index+lane,uint(round(weight*u.gains.w)));
            }
        }
    }
    float3 channelTint(int lane,constant U &u) {
        if(!(int(u.signal.w)&1))return float3(1);
        int mode=int(u.signal.z),channel=mode==0?3:((mode==3||mode==5)?(lane==0?3:lane-1):lane);
        if(mode==4)channel=lane==0?3:(lane==1?4:5);
        bool pure=int(u.signal.w)&2;
        if(channel==0||channel==5)return pure?float3(1,0,0):float3(1,.19,.24);
        if(channel==1)return pure?float3(0,1,0):float3(.15,1,.39);
        if(channel==2||channel==4)return pure?float3(0,0,1):float3(.22,.48,1);
        return float3(1);
    }
    kernel void scopeDisplay(constant float4 &exposure [[buffer(0)]],device const uint4 *bins [[buffer(1)]],constant U &u [[buffer(2)]],texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
        if(p.x>=output.get_width()||p.y>=output.get_height())return;
        float4 values=float4(bins[p.y*output.get_width()+p.x])/exposure.y;
        float3 c=0;
        if(u.style.x>0) {
            // Optical reconstruction only. Keep the measured coordinates and
            // density independent of this display filter; no temporal history.
            float3 trace=values.rgb*.72f;
            int2 last=int2(output.get_width()-1,output.get_height()-1);
            for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
                if(x==0&&y==0)continue;
                uint2 q=uint2(clamp(int2(p)+int2(x,y),int2(0),last));
                trace+=float3(bins[q.y*output.get_width()+q.x].xyz)/exposure.y*((x==0||y==0)?.06f:.01f);
            }
            c=trace*exposure.z;
        }
        else {int channels=int(u.signal.z)==0?1:((int(u.signal.z)==3||int(u.signal.z)==5)?4:3);for(int i=0;i<channels;i++)c+=values[i]*channelTint(i,u);}
        float peak=max(c.r,max(c.g,c.b));
        float3 result;
        if(u.style.x==0&&(int(u.signal.z)==1||int(u.signal.z)==5))result=pow(1-exp(-c*exposure.x*2.5f),float3(.72f));
        else {float intensity=pow(1-exp(-peak*exposure.x),.72f);result=peak>0?c/peak*intensity:float3(0);}
        output.write(float4(result,1),p);
    }
    """#
}
