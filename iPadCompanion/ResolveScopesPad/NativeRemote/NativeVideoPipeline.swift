import SwiftUI
import AVFoundation
import VideoToolbox

struct NativeDecodeEvent:Codable,Sendable {
    let timeNS:UInt64,sequence:UInt64
    let kind:String
    let rtpTimestamp:UInt32
    let status:Int32
}

/// A new asynchronous VideoToolbox pipeline. No FPS timer, four-frame cutoff,
/// or persistent keyframe-wait state sits between complete AUs and the decoder.
final class NativeVideoDecoder:@unchecked Sendable {
    var onFrame:((CVPixelBuffer,UInt64,UInt64)->Void)?
    var onStatus:((String)->Void)?
    var onKeyframeNeeded:(()->Void)?
    var onEvent:((NativeDecodeEvent)->Void)?
    private let queue=DispatchQueue(label:"studio.resolvescopes.native.video.decode",qos:.userInitiated)
    private var session:VTDecompressionSession?
    private var format:CMVideoFormatDescription?
    private var parameters=[Int:Data]()
    private var generation:UInt64=0,sequence:UInt64=0
    private var chroma=1,depth=10,fullRange=false
    private let admission=NSLock()
    private var queuedBytes=0
    private var errorRequestsNS:UInt64=0
    private var recovering=true
    private final class Ticket {
        weak var owner:NativeVideoDecoder?
        let generation:UInt64,sequence:UInt64,receivedNS:UInt64
        let timestamp:UInt32
        init(owner:NativeVideoDecoder,generation:UInt64,sequence:UInt64,receivedNS:UInt64,timestamp:UInt32) {
            self.owner=owner;self.generation=generation;self.sequence=sequence;self.receivedNS=receivedNS;self.timestamp=timestamp
        }
    }
    func configure(chroma:Int,depth:Int,fullRange:Bool) {
        queue.async {[weak self] in
            guard let self else{return}
            if self.chroma != chroma || self.depth != depth || self.fullRange != fullRange {self.invalidate()}
            self.chroma=chroma;self.depth=depth;self.fullRange=fullRange
        }
    }
    func reset() {queue.async {[weak self] in self?.invalidate();self?.parameters=[:]}}
    private func invalidate() {
        generation &+= 1
        if let session {VTDecompressionSessionInvalidate(session)}
        session=nil;format=nil
    }
    func decode(_ data:Data,timestamp:UInt32,receivedNS:UInt64) {
        guard !data.isEmpty,data.count<=16_000_000 else{return}
        admission.lock()
        // A byte safety bound for a stalled dispatch queue, not a frame-rate cap.
        let accepted=queuedBytes+data.count<=32_000_000
        if accepted {queuedBytes += data.count};admission.unlock()
        guard accepted else{onStatus?("디코드 입력 메모리 한도 초과");onKeyframeNeeded?();return}
        queue.async {[weak self] in
            guard let self else{return}
            self.admission.lock();self.queuedBytes -= data.count;self.admission.unlock()
            self.process(data,timestamp:timestamp,receivedNS:receivedNS)
        }
    }
    private func requestRecovery() {
        let now=CompanionClock.nowNS()
        if now-errorRequestsNS>200_000_000 {errorRequestsNS=now;onKeyframeNeeded?()}
    }
    private func process(_ data:Data,timestamp:UInt32,receivedNS:UInt64) {
        let units=Self.nalUnits(data)
        guard !units.isEmpty else{return}
        var changed=false
        for nal in units where nal.count>=2 {
            let type=Int((nal[nal.startIndex]>>1)&63)
            if (32...34).contains(type),parameters[type] != nal {parameters[type]=nal;changed=true}
        }
        if changed,session != nil {invalidate()}
        if session == nil {
            guard (32...34).allSatisfy({parameters[$0] != nil}) else{requestRecovery();return}
            do {try createSession()} catch {onStatus?(error.localizedDescription);requestRecovery();return}
        }
        guard let session,let format else{return}
        var bytes=Data()
        for unit in units {var size=UInt32(unit.count).bigEndian;withUnsafeBytes(of:&size){bytes.append(contentsOf:$0)};bytes.append(unit)}
        var block:CMBlockBuffer?
        var result=CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:bytes.count,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:bytes.count,flags:0,blockBufferOut:&block)
        guard result==noErr,let block else{return}
        result=bytes.withUnsafeBytes{CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:bytes.count)}
        guard result==noErr else{return}
        var sample:CMSampleBuffer?,size=bytes.count
        var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(value:Int64(timestamp),timescale:90_000),decodeTimeStamp:.invalid)
        result=CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)
        guard result==noErr,let sample else{return}
        sequence &+= 1
        let ticket=Unmanaged.passRetained(Ticket(owner:self,generation:generation,sequence:sequence,receivedNS:receivedNS,timestamp:timestamp))
        result=VTDecompressionSessionDecodeFrame(session,sampleBuffer:sample,flags:[._EnableAsynchronousDecompression],frameRefcon:ticket.toOpaque(),infoFlagsOut:nil)
        if result != noErr {ticket.release();recovering=true;onEvent?(.init(timeNS:CompanionClock.nowNS(),sequence:sequence,kind:"decode-rejected",rtpTimestamp:timestamp,status:result));onStatus?("디코드 오류 \(result) · 복구 요청");requestRecovery()}
    }
    private func createSession()throws {
        let sets=(32...34).compactMap{parameters[$0]}.map{NSData(data:$0)}
        var pointers=sets.map{$0.bytes.assumingMemoryBound(to:UInt8.self)},sizes=sets.map{$0.length}
        var description:CMFormatDescription?
        var status=CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:sets.count,parameterSetPointers:&pointers,parameterSetSizes:&sizes,nalUnitHeaderLength:4,extensions:nil,formatDescriptionOut:&description)
        guard status==noErr,let description else{throw DecoderError(code:status)}
        let pixel:OSType
        if depth>8 {pixel=chroma==2 ? (fullRange ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange):(fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)}
        else {pixel=fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange}
        var callback=VTDecompressionOutputCallbackRecord(decompressionOutputCallback:{_,ref,status,_,buffer,_,_ in
            guard let ref else{return}
            let ticket=Unmanaged<Ticket>.fromOpaque(ref).takeRetainedValue()
            guard let owner=ticket.owner else{return}
            owner.queue.async {
                guard ticket.generation==owner.generation else{return}
                if status==noErr,let buffer {
                    if owner.recovering {owner.recovering=false;owner.onEvent?(.init(timeNS:CompanionClock.nowNS(),sequence:ticket.sequence,kind:"decoded-recovered",rtpTimestamp:ticket.timestamp,status:0));owner.onStatus?("네이티브 영상 재생 중")}
                    owner.onFrame?(buffer,ticket.sequence,ticket.receivedNS)
                }else {owner.recovering=true;owner.onEvent?(.init(timeNS:CompanionClock.nowNS(),sequence:ticket.sequence,kind:"decode-output-error",rtpTimestamp:ticket.timestamp,status:status));owner.onStatus?("프레임 출력 오류 \(status)");owner.requestRecovery()}
            }
        },decompressionOutputRefCon:nil)
        var spec=[CFString:Any]()
        if #available(iOS 17.0,*) {spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder]=true}
        status=VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:description,decoderSpecification:spec as CFDictionary,imageBufferAttributes:[kCVPixelBufferPixelFormatTypeKey:pixel,kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,outputCallback:&callback,decompressionSessionOut:&session)
        guard status==noErr,let session else{throw DecoderError(code:status)}
        format=description
        VTSessionSetProperty(session,key:kVTDecompressionPropertyKey_RealTime,value:kCFBooleanTrue)
        onStatus?("네이티브 HEVC \(chroma==2 ? "4:2:2":"4:2:0") \(depth)-bit 디코더")
    }
    static func nalUnits(_ data:Data)->[Data] {
        let b=[UInt8](data);var offsets=[(Int,Int)](),i=0
        while i+2<b.count {
            if b[i]==0,b[i+1]==0 {
                if b[i+2]==1 {offsets.append((i,i+3));i += 3;continue}
                if i+3<b.count,b[i+2]==0,b[i+3]==1 {offsets.append((i,i+4));i += 4;continue}
            };i += 1
        }
        return offsets.enumerated().compactMap{n,p in let end=n+1<offsets.count ? offsets[n+1].0:b.count;return p.1<end ? Data(b[p.1..<end]):nil}
    }
    private struct DecoderError:LocalizedError {let code:OSStatus;var errorDescription:String?{"네이티브 HEVC 설정 오류 \(code)"}}
    deinit {if let session {VTDecompressionSessionInvalidate(session)}}
}

struct RemoteVideoSample:Codable,Sendable {let submittedNS:UInt64,receivedNS:UInt64,sequence:UInt64}

enum NativePlaybackStatus {
    static func text(connected:Bool,age:TimeInterval?,normal:String)->String {
        guard connected else{return "연결 끊김"}
        guard let age,age.isFinite,age>=0 else{return "첫 영상 표시 중"}
        guard age>2 else{return normal}
        return "새 프레임 대기 \(Int(min(age,99_999)))초"
    }
}

#if os(iOS)
/// Frame arrival schedules immediate presentation; no CADisplayLink video gate.
final class NativeVideoPresenter:NSObject,@unchecked Sendable {
    private struct Frame {let buffer:CVPixelBuffer,sequence:UInt64,receivedNS:UInt64}
    private let lock=NSLock()
    private var latest:Frame?,scheduled=false,lastDecodedNS:UInt64?
    private final class Surface {weak var layer:AVSampleBufferDisplayLayer?;init(_ layer:AVSampleBufferDisplayLayer){self.layer=layer}}
    @MainActor private var surfaces=[ObjectIdentifier:Surface]()
    @MainActor private var displayedFrame:Frame?
    @MainActor private var held=false
    @MainActor private var samples=[RemoteVideoSample]()
    func submit(_ buffer:CVPixelBuffer,sequence:UInt64,receivedNS:UInt64) {
        lock.lock();latest=Frame(buffer:buffer,sequence:sequence,receivedNS:receivedNS);lastDecodedNS=CompanionClock.nowNS()
        let needsSchedule = !scheduled;scheduled=true;lock.unlock()
        if needsSchedule {DispatchQueue.main.async {[weak self] in self?.presentLatest()}}
    }
    @MainActor func setHeld(_ value:Bool) {held=value;if !value {presentLatest()}}
    @MainActor func attach(_ layer:AVSampleBufferDisplayLayer) {
        surfaces[ObjectIdentifier(layer)]=Surface(layer);layer.videoGravity = .resizeAspect
        // A newly selected Source must also work on paused/held input.
        if let frame=displayedFrame {enqueue(frame,on:layer)}
        presentLatest()
    }
    @MainActor func detach(_ layer:AVSampleBufferDisplayLayer) {surfaces.removeValue(forKey:ObjectIdentifier(layer));layer.flushAndRemoveImage()}
    @MainActor func reset(keepImage:Bool=false) {lock.lock();latest=nil;scheduled=false;lastDecodedNS=nil;lock.unlock();samples=[];if !keepImage {displayedFrame=nil;for surface in surfaces.values {surface.layer?.flushAndRemoveImage()}}}
    @MainActor private func presentLatest() {
        lock.lock();scheduled=false
        surfaces=surfaces.filter{$0.value.layer != nil}
        guard !held,!surfaces.isEmpty,let frame=latest else{lock.unlock();return}
        latest=nil;lock.unlock()
        displayedFrame=frame
        for surface in surfaces.values {if let layer=surface.layer {enqueue(frame,on:layer)}}
        samples.append(.init(submittedNS:CompanionClock.nowNS(),receivedNS:frame.receivedNS,sequence:frame.sequence))
        if samples.count>5400 {samples.removeFirst(samples.count-5400)}
    }
    @MainActor private func enqueue(_ frame:Frame,on layer:AVSampleBufferDisplayLayer) {
        if #available(iOS 17.0,*) {if layer.sampleBufferRenderer.status == .failed {layer.sampleBufferRenderer.flush()}}
        else if layer.status == .failed {layer.flush()}
        var description:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:frame.buffer,formatDescriptionOut:&description)==noErr,let description else{return}
        var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid),sample:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:frame.buffer,formatDescription:description,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,let sample else{return}
        if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true) {
            let dictionary=unsafeBitCast(CFArrayGetValueAtIndex(attachments,0),to:CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if #available(iOS 17.0,*) {layer.sampleBufferRenderer.enqueue(sample)}else {layer.enqueue(sample)}
    }
    @MainActor var age:TimeInterval? {lock.lock();let time=lastDecodedNS;lock.unlock();return time.map{Double(CompanionClock.nowNS()-$0)/1e9}}
    @MainActor var isVisible:Bool {surfaces.values.contains{$0.layer != nil}}
    @MainActor func report()->(fps:Double,medianLocalMS:Double?,records:[RemoteVideoSample]) {
        let now=CompanionClock.nowNS(),recent=samples.filter{now >= $0.submittedNS && now-$0.submittedNS<2_000_000_000}
        let latencies=recent.map{Double($0.submittedNS-$0.receivedNS)/1e6}.sorted()
        return (Double(recent.count)/2,latencies.isEmpty ? nil:latencies[latencies.count/2],samples)
    }
}
private final class NativeVideoView:UIView {
    override class var layerClass:AnyClass {AVSampleBufferDisplayLayer.self}
    var videoLayer:AVSampleBufferDisplayLayer {layer as! AVSampleBufferDisplayLayer}
}
struct NativeVideoSurface:UIViewRepresentable {
    let presenter:NativeVideoPresenter
    func makeCoordinator()->NativeVideoPresenter {presenter}
    func makeUIView(context:Context)->UIView {let view=NativeVideoView();view.backgroundColor = .black;presenter.attach(view.videoLayer);return view}
    func updateUIView(_ view:UIView,context:Context) {}
    static func dismantleUIView(_ view:UIView,coordinator:NativeVideoPresenter) {if let view=view as? NativeVideoView {coordinator.detach(view.videoLayer)}}
}

#endif
