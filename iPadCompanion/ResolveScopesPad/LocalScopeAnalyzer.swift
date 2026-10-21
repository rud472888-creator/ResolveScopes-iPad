import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
#if canImport(ScopeCore)
import ScopeCore
#endif
#if canImport(CompanionKit)
import CompanionKit
#endif

enum LocalScopeYCbCrMatrix:String,Sendable {
    case bt601="BT.601",bt709="BT.709",bt2020="BT.2020 non-constant luminance"
    var weights:(Double,Double) {
        switch self {case .bt601:return (0.299,0.114);case .bt709:return (0.2126,0.0722);case .bt2020:return (0.2627,0.0593)}
    }
}

// Explicit diagnostic launch only; never runs in a monitoring session. Measures
// analysis + image/guide generation on-device, excluding network and decoding.
extension LocalScopeAnalyzer {
    static func qualityBenchmark() throws -> LocalScopeAnalysis {
        var buffer:CVPixelBuffer?
        let width=3200,height=1800
        guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer) == kCVReturnSuccess,let buffer else {throw LocalScopeAnalysisError.unreadableBuffer}
        CVPixelBufferLockBaseAddress(buffer,[])
        for y in 0..<height {
            let row=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(buffer,0))
            for x in 0..<width {
                let u=Double(x)/Double(width-1),v=Double(y)/Double(height-1)
                let signal=0.1+0.7*(0.6*u+0.4*v)+0.07*sin(u*28+v*11)+0.025*sin(u*129-v*77)
                row.storeBytes(of:UInt16((64+876*signal).rounded())<<6,toByteOffset:x*2,as:UInt16.self)
            }
        }
        for y in 0..<height/2 {
            let row=CVPixelBufferGetBaseAddressOfPlane(buffer,1)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(buffer,1))
            for x in 0..<width/2 {
                let u=Double(x)/Double(width/2-1),v=Double(y)/Double(height/2-1)
                row.storeBytes(of:UInt16((512+85*sin(v*9+u*5)).rounded())<<6,toByteOffset:x*4,as:UInt16.self)
                row.storeBytes(of:UInt16((512+70*sin(v*7)).rounded())<<6,toByteOffset:x*4+2,as:UInt16.self)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("ScopeQuality122",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var rows=[[String:Any]](),selected:LocalScopeAnalysis?
        for quality in [320,480,640,960] {
            var configuration=LocalScopeConfiguration();configuration.settings.sampleWidth=quality
            var times=[Double](),stages=[String:Double]()
            for iteration in 0..<18 {
                let output=try autoreleasepool {try analyze(pixelBuffer:buffer,sequence:UInt64(iteration+1),timestampNS:0,
                    format:.init(matrix:.bt709,primaries:.rec709,transfer:.gamma24),configuration:configuration)}
                guard output.gpuTracePixels==width*height else {throw LocalScopeGPURenderer.Failure.command}
                if iteration>=3 {
                    times.append(output.processingMS)
                    for (key,value) in output.stageMS {stages[key,default:0]+=value/15}
                }
                if iteration == 17 {
                    if quality == 480 {selected=output}
                    for (panel,image) in output.images {
                        let url=folder.appendingPathComponent("\(panel.rawValue)-\(quality).png")
                        guard let writer=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else {throw LocalScopeAnalysisError.image}
                        CGImageDestinationAddImage(writer,image,nil)
                        guard CGImageDestinationFinalize(writer) else {throw LocalScopeAnalysisError.image}
                    }
                }
            }
            times.sort()
            rows.append(["numericSampleWidth":quality,"gpuTracePixels":width*height,"iterations":times.count,"medianMS":times[times.count/2],"p95MS":times[Int(ceil(Double(times.count)*0.95))-1],"maxMS":times.last!,"meanStagesMS":stages])
        }
        let report:[String:Any]=["source":"3200x1800 synthetic YUV420 10-bit video-range","scopeRaster":"GPU full received3200x1800;1536x768 waveform/parade,1024x1024 vector",
                                 "measurement":"analysis and CGImage/guide creation only; not stream FPS or end-to-end latency","results":rows]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("benchmark.json"),options:.atomic)
        return selected!
    }
}

/// Overrides must come from a verified mapping or the user's selection. Unknown
/// Remote Monitor enum indices are retained as descriptions, never guessed here.
struct LocalScopeSourceFormat:Sendable {
    /// Encoded-stream range metadata. The decoder may convert to a different
    /// range; the concrete CVPixelBuffer type remains authoritative by default.
    var fullRange:Bool?
    var decodedFullRangeOverride:Bool?
    var matrix:LocalScopeYCbCrMatrix?
    var primaries:ColorSpace?
    var transfer:TransferFunction?
    var sourceDescription:String
    var rawMetadata:[String:String]
    init(fullRange:Bool?=nil,decodedFullRangeOverride:Bool?=nil,matrix:LocalScopeYCbCrMatrix?=nil,primaries:ColorSpace?=nil,
         transfer:TransferFunction?=nil,sourceDescription:String="Remote Monitor 디코드 영상",rawMetadata:[String:String]=[:]) {
        self.fullRange=fullRange;self.decodedFullRangeOverride=decodedFullRangeOverride;self.matrix=matrix;self.primaries=primaries;self.transfer=transfer
        self.sourceDescription=sourceDescription;self.rawMetadata=rawMetadata
    }
}

struct LocalScopeConfiguration:Sendable {
    var settings=ScopeSettings()
    var waveform=WaveformSettings()
    var vector=VectorScopeSettings()
    var falseColor=FalseColorMapping.defaultIRE
    var falseColorZone:Double?=nil
    var presentation:FalseColorPresentation?=nil
    var rasterViews:[UUID:FullRasterScopeRegistration]=[:]
    init() {}
}

/// Measurements describe the sampled, decoded compressed stream; they are not
/// original Resolve Float values or an exhaustive full-resolution QC result.
struct LocalScopeAnalysis:@unchecked Sendable {
    let images:[CompanionPanel:CGImage]
    let statistics:ScopeStatistics
    let frame:VideoFrame
    let settings:ScopeSettings
    let conditions:String
    let warnings:[String]
    let processingMS:Double
    var stageMS:[String:Double]=[:]
    var viewImages:[UUID:CGImage]=[:]
    var viewRequests:[UUID:FullRasterScopeRequest]=[:]
    var viewKinds:[UUID:CompanionPanel]=[:]
    var gpuTracePixels:Int=0
    var sequence:UInt64 {frame.sequence}
    var timestampNS:UInt64 {frame.timestampNS}
}

enum LocalScopeAnalysisError:Error,LocalizedError {
    case dimensions,unsupportedPixelFormat(OSType),unreadableBuffer,unsupportedMatrix(String),image
    var errorDescription:String? {
        switch self {
        case .dimensions:return "디코드 영상 크기가 분석 제한을 벗어났습니다."
        case .unsupportedPixelFormat(let type):return "지원하지 않는 디코드 픽셀 형식: \(String(format:"%08x",type))"
        case .unreadableBuffer:return "디코드 픽셀 버퍼를 읽을 수 없습니다."
        case .unsupportedMatrix(let value):return "지원하지 않는 YCbCr 행렬: \(value). 검증된 행렬을 직접 선택하세요."
        case .image:return "로컬 스코프 이미지를 만들 수 없습니다."
        }
    }
}

/// One frame in computation plus one replaceable pending frame. Video playback
/// must use the decoder's separate display path and never wait for this worker.
final class LocalScopeAnalyzer:@unchecked Sendable {
    private struct Input {
        let pixelBuffer:CVPixelBuffer,sequence:UInt64,timestampNS:UInt64,format:LocalScopeSourceFormat,epoch:UInt64
    }
    private let queue=DispatchQueue(label:"studio.resolvescopes.ipad.local-analysis",qos:.userInitiated)
    private let lock=NSLock()
    private var pending:Input?
    private var latest:Input?
    private var busy=false
    private var epoch:UInt64=0
    private var configuration=LocalScopeConfiguration()
    private let onResult:(LocalScopeAnalysis)->Void
    private let onError:(Error)->Void
    init(onResult:@escaping (LocalScopeAnalysis)->Void,onError:@escaping (Error)->Void={_ in}) {
        self.onResult=onResult;self.onError=onError
    }
    func configure(_ value:LocalScopeConfiguration) {
        lock.lock();configuration=value;epoch &+= 1
        if let last=latest {pending=Input(pixelBuffer:last.pixelBuffer,sequence:last.sequence,timestampNS:last.timestampNS,format:last.format,epoch:epoch)}
        let start=pending != nil && !busy
        if start {busy=true};lock.unlock()
        if start {queue.async {[weak self] in self?.drain()}}
    }
    func reset() {lock.lock();epoch &+= 1;pending=nil;latest=nil;lock.unlock()}
    func submit(pixelBuffer:CVPixelBuffer,sequence:UInt64,timestampNS:UInt64,format:LocalScopeSourceFormat = .init()) {
        lock.lock()
        pending=Input(pixelBuffer:pixelBuffer,sequence:sequence,timestampNS:timestampNS,format:format,epoch:epoch)
        latest=pending
        let start = !busy
        busy=true;lock.unlock()
        if start {queue.async {[weak self] in self?.drain()}}
    }
    private func drain() {
        while true {
            lock.lock()
            guard let next=pending else {busy=false;lock.unlock();return}
            pending=nil;let config=configuration;lock.unlock()
            autoreleasepool {
                do {
                    let output=try Self.analyze(pixelBuffer:next.pixelBuffer,sequence:next.sequence,timestampNS:next.timestampNS,format:next.format,configuration:config)
                    lock.lock();let valid=next.epoch == epoch;lock.unlock()
                    if valid {onResult(output)}
                }catch {
                    lock.lock();let valid=next.epoch == epoch;lock.unlock()
                    if valid {onError(error)}
                }
            }
        }
    }
    static func analyze(pixelBuffer:CVPixelBuffer,sequence:UInt64,timestampNS:UInt64,
                        format:LocalScopeSourceFormat = .init(),configuration:LocalScopeConfiguration = .init()) throws -> LocalScopeAnalysis {
        let start=ProcessInfo.processInfo.systemUptime
        let converted=try sampledFrame(pixelBuffer:pixelBuffer,sequence:sequence,timestampNS:timestampNS,format:format,settings:configuration.settings)
        let conversionMS=(ProcessInfo.processInfo.systemUptime-start)*1000
        let gpu=LocalScopeGPURenderer.shared
        let useGPU=gpu != nil && FullRasterScopeRenderer.supports(configuration.waveform)
        func cpu(_ raster:Bool,_ renderFC:Bool=false)->ScopeResult {
            ScopeEngine.analyze(frame:converted.frame,settings:converted.settings,falseColorMapping:configuration.falseColor,
                                waveform:configuration.waveform,renderLegacyPlots:false,collectCIETrace:false,renderLegacyCIE:false,collectDistributions:false,rasterizeWaveforms:raster,rasterizeFalseColor:renderFC || gpu == nil,falseColorZone:configuration.falseColorZone,presentation:configuration.presentation)
        }
        var result=cpu(!useGPU)
        // Skipped CPU rasters are black placeholders, never valid display fallbacks.
        var bitmaps:[CompanionPanel:ScopeBitmap]=[.source:result.source]
        if !useGPU {bitmaps[.waveform]=result.waveform;bitmaps[.parade]=result.parade}
        if gpu == nil {bitmaps[.falseColor]=result.falseColor}
        var viewBitmaps=[UUID:(CompanionPanel,ScopeBitmap,FullRasterScopeRequest)]()
        var gpuMS:Double=0,tracePixels=0,warnings=converted.warnings
        let gpuStart=ProcessInfo.processInfo.systemUptime
        if let gpu {
            do {
                let active:Set<FullRasterScopeKind>=configuration.rasterViews.isEmpty ? [.waveform,.parade,.vectorscope,.falseColor]:Set(configuration.rasterViews.values.map(\.kind))
                let batches=FullRasterScopeBatch.make(registrations:configuration.rasterViews,active:active)
                var assigned=Set<CompanionPanel>()
                for batch in batches {
                    let output=try gpu.render(pixelBuffer:pixelBuffer,layout:converted.layout,settings:converted.settings,waveform:configuration.waveform,vector:configuration.vector,requests:batch.requests,falseColor:configuration.falseColor,falseColorZone:configuration.falseColorZone,presentation:configuration.presentation)
                    if let fc=output.falseColor {bitmaps[.falseColor]=fc}
                    for (kind,bitmap) in [(FullRasterScopeKind.waveform,output.wave),(.parade,output.parade),(.vectorscope,output.vectors["combined"])] {
                        guard let bitmap,let panel=CompanionPanel(rawValue:kind.rawValue) else {continue}
                        if assigned.insert(panel).inserted {bitmaps[panel]=bitmap}
                        if let request=batch.requests[kind] {for id in batch.owners[kind] ?? [] {viewBitmaps[id]=(panel,bitmap,request)}}
                    }
                    tracePixels=output.receivedPixels
                }
                if !FullRasterScopeRenderer.supports(configuration.waveform) {warnings.append("추가 파형 필터: CPU 표본 파형 사용")}
            }catch {
                warnings.append("GPU 분석 실패 · CPU 표본 대체: \(error)")
                result=cpu(true,true);bitmaps[.falseColor]=result.falseColor;bitmaps[.waveform]=result.waveform;bitmaps[.parade]=result.parade;viewBitmaps=[:];tracePixels=0
            }
        }else {warnings.append("GPU 사용 불가 · CPU 표본 Trace")}
        gpuMS=(ProcessInfo.processInfo.systemUptime-gpuStart)*1000
        if tracePixels == 0 {bitmaps[.vectorscope]=VectorScope.analyze(frame:converted.frame,settings:converted.settings,vector:configuration.vector).combined}
        let imageStart=ProcessInfo.processInfo.systemUptime
        func image(_ bitmap:ScopeBitmap,panel:CompanionPanel,viewport:WaveformViewport = .init()) throws -> CGImage {
            guard let provider=CGDataProvider(data:Data(bitmap.rgba) as CFData),
                  let plain=CGImage(width:bitmap.width,height:bitmap.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:bitmap.width*4,
                                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                                    provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw LocalScopeAnalysisError.image}
            if panel == .waveform || panel == .parade || panel == .vectorscope,
               let context=CGContext(data:nil,width:bitmap.width,height:bitmap.height,bitsPerComponent:8,bytesPerRow:bitmap.width*4,
                                     space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.draw(plain,in:CGRect(x:0,y:0,width:bitmap.width,height:bitmap.height))
                var guides=CompanionPlotOverlay.make(panel:panel,settings:converted.settings,waveform:configuration.waveform,vector:configuration.vector)
                guides.viewport=viewport;guides.draw(in:context,width:bitmap.width,height:bitmap.height)
                return context.makeImage() ?? plain
            }
            return plain
        }
        var images=[CompanionPanel:CGImage](),viewImages=[UUID:CGImage]()
        for (panel,bitmap) in bitmaps {images[panel]=try image(bitmap,panel:panel)}
        for (id,item) in viewBitmaps {viewImages[id]=try image(item.1,panel:item.0,viewport:item.2.viewport)}
        let trace=tracePixels>0 ? "GPU Trace 수신 \(converted.frame.sourceWidth)×\(converted.frame.sourceHeight) 전체 픽셀":"CPU Trace 표본 격자"
        return LocalScopeAnalysis(images:images,statistics:result.stats,frame:converted.frame,settings:converted.settings,
                                  conditions:trace+"\n"+converted.conditions,warnings:warnings,processingMS:(ProcessInfo.processInfo.systemUptime-start)*1000,
                                  stageMS:["conversion":conversionMS,"sampledStatisticsPreview":result.processingMS,"gpuFullRaster":gpuMS,"imagesAndGuides":(ProcessInfo.processInfo.systemUptime-imageStart)*1000],viewImages:viewImages,viewRequests:viewBitmaps.mapValues{$0.2},viewKinds:viewBitmaps.mapValues{$0.0},gpuTracePixels:tracePixels)
    }
    struct SampledFrame {
        let frame:VideoFrame,settings:ScopeSettings,conditions:String,warnings:[String]
        let layout:LocalScopePixelLayout
    }
    static func sampledFrame(pixelBuffer:CVPixelBuffer,sequence:UInt64,timestampNS:UInt64,
                             format:LocalScopeSourceFormat = .init(),settings fallback:ScopeSettings = .init()) throws -> SampledFrame {
        let width=CVPixelBufferGetWidth(pixelBuffer),height=CVPixelBufferGetHeight(pixelBuffer)
        guard width>0,height>0,width<=16384,height<=16384,width*height<=64_000_000 else {throw LocalScopeAnalysisError.dimensions}
        var settings=fallback,warnings=[String]()
        func attachment(_ key:CFString)->String? {CVBufferCopyAttachment(pixelBuffer,key,nil).map{String(describing:$0)}}
        let primaries=attachment(kCVImageBufferColorPrimariesKey),transfer=attachment(kCVImageBufferTransferFunctionKey),matrix=attachment(kCVImageBufferYCbCrMatrixKey)
        if let override=format.primaries {settings.colorSpace=override}
        else if primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String {settings.colorSpace = .rec2020}
        else if primaries == kCVImageBufferColorPrimaries_P3_D65 as String {settings.colorSpace = .p3D65}
        else if primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String {settings.colorSpace = .rec709}
        else {warnings.append("원색 메타데이터 \(primaries ?? "없음"): 선택한 \(fallback.colorSpace.rawValue) 사용")}
        if let override=format.transfer {settings.transfer=override}
        else if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {settings.transfer = .pq}
        else if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {settings.transfer = .hlg}
        else if transfer == kCVImageBufferTransferFunction_sRGB as String {settings.transfer = .sRGB}
        else if transfer == kCVImageBufferTransferFunction_Linear as String {settings.transfer = .linear}
        else {warnings.append("전달함수 메타데이터 \(transfer ?? "없음"): 선택한 \(fallback.transfer.rawValue) 측정 해석 사용")}
        // Conversion below already expands YUV legal range into encoded RGB.
        // ScopeEngine must not normalize legal range a second time.
        settings.levels = .full
        settings.sampleWidth=min(960,max(160,fallback.sampleWidth))
        let scale=min(1,min(Double(settings.sampleWidth)/Double(width),Double(settings.sampleWidth*9/16)/Double(height)))
        let outWidth=max(1,Int(Double(width)*scale)),outHeight=max(1,Int(Double(height)*scale))
        let pixelType=CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bits:Int,subsampleY:Int,isYUV:Bool,defaultFull:Bool
        switch pixelType {
        case kCVPixelFormatType_32BGRA:bits=8;subsampleY=1;isYUV=false;defaultFull=true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:bits=8;subsampleY=2;isYUV=true;defaultFull=false
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:bits=8;subsampleY=2;isYUV=true;defaultFull=true
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:bits=10;subsampleY=2;isYUV=true;defaultFull=false
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:bits=10;subsampleY=2;isYUV=true;defaultFull=true
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:bits=10;subsampleY=1;isYUV=true;defaultFull=false
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:bits=10;subsampleY=1;isYUV=true;defaultFull=true
        default:throw LocalScopeAnalysisError.unsupportedPixelFormat(pixelType)
        }
        let full=isYUV ? (format.decodedFullRangeOverride ?? defaultFull):true
        if isYUV,let encoded=format.fullRange,encoded != full {warnings.append("송신 범위 \(encoded ? "Full":"Video")와 디코드 버퍼 \(full ? "Full":"Video")가 다름: 디코드 버퍼 범위로 측정")}
        if isYUV,let requested=format.decodedFullRangeOverride,requested != defaultFull {warnings.append("디코드 버퍼 범위를 명시적으로 재정의: \(requested ? "Full":"Video")")}
        let coefficients:LocalScopeYCbCrMatrix
        if let value=format.matrix {coefficients=value}
        else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {coefficients = .bt709}
        else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {coefficients = .bt2020}
        else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {coefficients = .bt601}
        else if let matrix,isYUV {throw LocalScopeAnalysisError.unsupportedMatrix(matrix)}
        else {
            coefficients=settings.colorSpace == .rec2020 ? .bt2020:.bt709
            if isYUV {warnings.append("YCbCr 행렬 메타데이터 없음: 선택 원색의 \(coefficients.rawValue) 가정")}
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer,.readOnly) == kCVReturnSuccess else {throw LocalScopeAnalysisError.unreadableBuffer}
        defer {CVPixelBufferUnlockBaseAddress(pixelBuffer,.readOnly)}
        var rgba=[Float](repeating:1,count:outWidth*outHeight*4)
        if isYUV {
            guard CVPixelBufferGetPlaneCount(pixelBuffer)==2,
                  let yBase=CVPixelBufferGetBaseAddressOfPlane(pixelBuffer,0),let uvBase=CVPixelBufferGetBaseAddressOfPlane(pixelBuffer,1),
                  CVPixelBufferGetWidthOfPlane(pixelBuffer,0)>=width,CVPixelBufferGetHeightOfPlane(pixelBuffer,0)>=height,
                  CVPixelBufferGetWidthOfPlane(pixelBuffer,1)>=(width+1)/2,CVPixelBufferGetHeightOfPlane(pixelBuffer,1)>=(height+subsampleY-1)/subsampleY else {throw LocalScopeAnalysisError.unreadableBuffer}
            let yStride=CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer,0),uvStride=CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer,1)
            let bytes=bits == 10 ? 2:1
            guard yStride>=width*bytes,uvStride>=((width+1)/2)*2*bytes else {throw LocalScopeAnalysisError.unreadableBuffer}
            let maximum=bits == 10 ? 1023.0:255.0,center=bits == 10 ? 512.0:128.0
            let yOffset=full ? 0:(bits == 10 ? 64.0:16.0),yRange=full ? maximum:(bits == 10 ? 876.0:219.0)
            let cRange=full ? maximum:(bits == 10 ? 896.0:224.0)
            let (kr,kb)=coefficients.weights,kg=1-kr-kb
            for y in 0..<outHeight {
                let sy=min(height-1,Int((Double(y)+0.5)*Double(height)/Double(outHeight)))
                let luma=yBase.advanced(by:sy*yStride),chroma=uvBase.advanced(by:(sy/subsampleY)*uvStride)
                for x in 0..<outWidth {
                    let sx=min(width-1,Int((Double(x)+0.5)*Double(width)/Double(outWidth))),cx=(sx/2)*2
                    let yy,cb,cr:Double
                    if bits == 10 {
                        yy=(Double(luma.load(fromByteOffset:sx*2,as:UInt16.self)>>6)-yOffset)/yRange
                        cb=(Double(chroma.load(fromByteOffset:cx*2,as:UInt16.self)>>6)-center)/cRange
                        cr=(Double(chroma.load(fromByteOffset:(cx+1)*2,as:UInt16.self)>>6)-center)/cRange
                    }else {
                        yy=(Double(luma.load(fromByteOffset:sx,as:UInt8.self))-yOffset)/yRange
                        cb=(Double(chroma.load(fromByteOffset:cx,as:UInt8.self))-center)/cRange
                        cr=(Double(chroma.load(fromByteOffset:cx+1,as:UInt8.self))-center)/cRange
                    }
                    let r=yy+2*(1-kr)*cr,b=yy+2*(1-kb)*cb,g=(yy-kr*r-kb*b)/kg,index=(y*outWidth+x)*4
                    rgba[index]=Float(r);rgba[index+1]=Float(g);rgba[index+2]=Float(b)
                }
            }
        }else {
            guard let base=CVPixelBufferGetBaseAddress(pixelBuffer),CVPixelBufferGetBytesPerRow(pixelBuffer)>=width*4 else {throw LocalScopeAnalysisError.unreadableBuffer}
            let stride=CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<outHeight {
                let sy=min(height-1,Int((Double(y)+0.5)*Double(height)/Double(outHeight))),row=base.advanced(by:sy*stride)
                for x in 0..<outWidth {
                    let sx=min(width-1,Int((Double(x)+0.5)*Double(width)/Double(outWidth))),i=(y*outWidth+x)*4
                    rgba[i]=Float(row.load(fromByteOffset:sx*4+2,as:UInt8.self))/255
                    rgba[i+1]=Float(row.load(fromByteOffset:sx*4+1,as:UInt8.self))/255
                    rgba[i+2]=Float(row.load(fromByteOffset:sx*4,as:UInt8.self))/255
                }
            }
            warnings.append("디코더 BGRA 8-bit 변환 후 측정: 원본 10-bit·YCbCr headroom 보존은 보장하지 않음")
        }
        let frame=VideoFrame(width:outWidth,height:outHeight,rgba:rgba,sequence:sequence,timestampNS:timestampNS,sourceWidth:width,sourceHeight:height)
        var raw=""
        for (key,value) in format.rawMetadata.sorted(by:{$0.key<$1.key}).prefix(12) {
            let entry="\(key.prefix(48))=\(value.prefix(96))"
            guard raw.utf8.count+entry.utf8.count+2<=500 else {break}
            raw += (raw.isEmpty ? "":", ")+entry
        }
        let conditions="\(format.sourceDescription.prefix(160)) · 디코드 압축 영상의 iPad 로컬 분석\n\(width)×\(height) · 수치 표본 \(outWidth)×\(outHeight) · \(bits)-bit \(isYUV ? (full ? "Full":"Video") : "BGRA Full")\n\(settings.colorSpace.rawValue) · \(settings.transfer.rawValue) · \(isYUV ? coefficients.rawValue:"decoder RGB")\n원본 Float/전체 픽셀 QC 아님"+(raw.isEmpty ? "":"\n송신 원문: \(raw)")
        return SampledFrame(frame:frame,settings:settings,conditions:conditions,warnings:warnings,layout:.init(bits:bits,subsampleY:subsampleY,isYUV:isYUV,full:full,kr:Float(coefficients.weights.0),kb:Float(coefficients.weights.1)))
    }
}
