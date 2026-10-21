import Foundation
import CoreVideo
import Metal
#if canImport(ScopeCore)
import ScopeCore
#endif

/// Concrete decoder-buffer interpretation, resolved once by the same metadata
/// path as numeric sampling. Encoded stream range never silently overrides it.
struct LocalScopePixelLayout:Sendable {
    let bits:Int,subsampleY:Int
    let isYUV:Bool,full:Bool
    let kr:Float,kb:Float
}

/// Converts decoder IOSurface planes on GPU, preserving code-value headroom.
/// Native video presentation never waits on this worker or its command queue.
final class LocalScopeGPURenderer:@unchecked Sendable {
    static let shared:LocalScopeGPURenderer? = try? LocalScopeGPURenderer()
    let renderer:FullRasterScopeRenderer
    private let queue:MTLCommandQueue,pipeline:MTLComputePipelineState
    private var cache:CVMetalTextureCache
    private var rgb:MTLBuffer?
    private let lock=NSLock()
    enum Failure:Error {case texture,allocation,command}
    init() throws {
        renderer=try FullRasterScopeRenderer()
        guard let queue=renderer.device.makeCommandQueue() else {throw Failure.allocation};self.queue=queue
        var cache:CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,renderer.device,nil,&cache) == kCVReturnSuccess,let cache else {throw Failure.texture};self.cache=cache
        let library=try renderer.device.makeLibrary(source:Self.source,options:nil)
        pipeline=try renderer.device.makeComputePipelineState(function:library.makeFunction(name:"decodeScopeRGB")!)
    }
    func render(pixelBuffer:CVPixelBuffer,layout:LocalScopePixelLayout,settings:ScopeSettings,waveform:WaveformSettings,vector:VectorScopeSettings,
                requests:[FullRasterScopeKind:FullRasterScopeRequest],falseColor:FalseColorMapping = .defaultIRE,falseColorZone:Double?=nil,presentation:FalseColorPresentation?=nil) throws -> FullRasterScopeRender {
        lock.lock();defer{lock.unlock()}
        let buffer=try convertLocked(pixelBuffer:pixelBuffer,layout:layout)
        return try renderer.render(input:buffer,width:CVPixelBufferGetWidth(pixelBuffer),height:CVPixelBufferGetHeight(pixelBuffer),settings:settings,waveform:waveform,vector:vector,requests:requests,falseColor:falseColor,falseColorZone:falseColorZone,presentation:presentation)
    }
    // Exposed internally for numeric GPU conversion checks; production only
    // reads the much smaller scope textures, never this full RGB buffer.
    func convertedRGB(pixelBuffer:CVPixelBuffer,layout:LocalScopePixelLayout) throws -> [Float] {
        lock.lock();defer{lock.unlock()}
        let buffer=try convertLocked(pixelBuffer:pixelBuffer,layout:layout)
        return Array(UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:Float.self),count:CVPixelBufferGetWidth(pixelBuffer)*CVPixelBufferGetHeight(pixelBuffer)*4))
    }
    private func convertLocked(pixelBuffer:CVPixelBuffer,layout:LocalScopePixelLayout) throws -> MTLBuffer {
        let width=CVPixelBufferGetWidth(pixelBuffer),height=CVPixelBufferGetHeight(pixelBuffer)
        guard width>0,height>0,width<=16384,height<=16384,width*height<=64_000_000 else {throw LocalScopeAnalysisError.dimensions}
        func texture(_ format:MTLPixelFormat,_ w:Int,_ h:Int,_ plane:Int) throws -> (CVMetalTexture,MTLTexture) {
            var ref:CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixelBuffer,nil,format,w,h,plane,&ref) == kCVReturnSuccess,
                  let ref,let texture=CVMetalTextureGetTexture(ref) else {throw Failure.texture}
            return (ref,texture)
        }
        let y=try texture(layout.isYUV ? (layout.bits == 10 ? .r16Unorm:.r8Unorm):.bgra8Unorm,width,height,0)
        let uv=layout.isYUV ? try texture(layout.bits == 10 ? .rg16Unorm:.rg8Unorm,CVPixelBufferGetWidthOfPlane(pixelBuffer,1),CVPixelBufferGetHeightOfPlane(pixelBuffer,1),1):y
        let bytes=width*height*16
        guard let output=(rgb.flatMap{$0.length>=bytes ? $0:nil} ?? renderer.device.makeBuffer(length:bytes,options:.storageModeShared)),
              let command=queue.makeCommandBuffer(),let compute=command.makeComputeCommandEncoder() else {throw Failure.allocation}
        // One retained full-resolution buffer; old dimensions are replaced.
        rgb=output
        var geometry=SIMD4<UInt32>(UInt32(width),UInt32(height),UInt32(layout.subsampleY),layout.isYUV ? 1:0)
        let maxCode:Float=layout.bits == 10 ? 1023:255,center:Float=layout.bits == 10 ? 512:128
        var levels=SIMD4<Float>(layout.bits == 10 ? 65535/64:255,layout.full ? 0:(layout.bits == 10 ? 64:16),layout.full ? maxCode:(layout.bits == 10 ? 876:219),center)
        var color=SIMD4<Float>(layout.kr,layout.kb,layout.full ? maxCode:(layout.bits == 10 ? 896:224),0)
        compute.setComputePipelineState(pipeline);compute.setTexture(y.1,index:0);compute.setTexture(uv.1,index:1)
        compute.setBuffer(output,offset:0,index:0);compute.setBytes(&geometry,length:16,index:1);compute.setBytes(&levels,length:16,index:2);compute.setBytes(&color,length:16,index:3)
        compute.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));compute.endEncoding()
        command.commit();command.waitUntilCompleted()
        // Keep CVMetalTexture owners alive until the command has consumed planes.
        withExtendedLifetime((y.0,uv.0)) {}
        guard command.status == .completed else {throw Failure.command}
        return output
    }
    private static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void decodeScopeRGB(texture2d<float,access::read> luma [[texture(0)]],texture2d<float,access::read> chroma [[texture(1)]],device float4 *output [[buffer(0)]],constant uint4 &geometry [[buffer(1)]],constant float4 &levels [[buffer(2)]],constant float4 &color [[buffer(3)]],uint2 at [[thread_position_in_grid]]) {
        if(at.x>=geometry.x||at.y>=geometry.y)return;
        float3 rgb;
        if(geometry.w==0)rgb=luma.read(at).rgb;
        else {
            float y=(luma.read(at).r*levels.x-levels.y)/levels.z;
            float2 c=(chroma.read(uint2(at.x/2,at.y/geometry.z)).rg*levels.x-levels.w)/color.z;
            float r=y+2*(1-color.x)*c.y,b=y+2*(1-color.y)*c.x,g=(y-color.x*r-color.y*b)/(1-color.x-color.y);
            rgb=float3(r,g,b);
        }
        output[at.y*geometry.x+at.x]=float4(rgb,1);
    }
    """#
}
