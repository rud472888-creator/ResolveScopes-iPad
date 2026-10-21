import Foundation
import CommonCrypto
import Darwin

// Independent native implementation of RFC3711 AES-CM/HMAC-SHA1 SRTP and
// RFC7798 non-interleaved HEVC RTP. No media packet crosses the JS boundary.
enum NativeMediaError:Error {
    case invalidKey,unsupportedProfile,cryptographicFailure(Int32),malformed,authentication,replay
}

struct NativeSRTPKeys {
    let encryption:Data,authentication:Data,salt:Data,tagBytes:Int
    init(masterKey:Data,masterSalt:Data,profile:Int)throws {
        guard masterKey.count==16,masterSalt.count==14 else {throw NativeMediaError.invalidKey}
        guard profile==1 || profile==2 else {throw NativeMediaError.unsupportedProfile}
        encryption=try Self.derive(masterKey:masterKey,masterSalt:masterSalt,label:0,length:16)
        authentication=try Self.derive(masterKey:masterKey,masterSalt:masterSalt,label:1,length:20)
        salt=try Self.derive(masterKey:masterKey,masterSalt:masterSalt,label:2,length:14)
        tagBytes=profile==1 ? 10:4
    }
    static func derive(masterKey:Data,masterSalt:Data,label:UInt8,length:Int)throws->Data {
        guard masterKey.count==16,masterSalt.count==14,length>0,length<=256 else {throw NativeMediaError.invalidKey}
        var iv=Data(masterSalt);iv.append(contentsOf:[0,0]);iv[7] ^= label
        return try crypt(Data(repeating:0,count:length),key:masterKey,iv:iv)
    }
    static func crypt(_ data:Data,key:Data,iv:Data)throws->Data {
        guard key.count==16,iv.count==16,data.count<=65_536 else {throw NativeMediaError.invalidKey}
        if data.isEmpty {return Data()}
        var ref:CCCryptorRef?
        let status=key.withUnsafeBytes {keyBytes in iv.withUnsafeBytes {ivBytes in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt),CCMode(kCCModeCTR),CCAlgorithm(kCCAlgorithmAES),CCPadding(ccNoPadding),
                ivBytes.baseAddress,keyBytes.baseAddress,key.count,nil,0,0,CCModeOptions(kCCModeOptionCTR_BE),&ref)
        }}
        guard status==kCCSuccess,let ref else {throw NativeMediaError.cryptographicFailure(status)}
        defer {CCCryptorRelease(ref)}
        var output=Data(count:data.count),written=0
        let capacity=output.count
        let result=output.withUnsafeMutableBytes {dst in data.withUnsafeBytes {src in
            CCCryptorUpdate(ref,src.baseAddress,data.count,dst.baseAddress,capacity,&written)
        }}
        guard result==kCCSuccess,written==data.count else {throw NativeMediaError.cryptographicFailure(result)}
        return output
    }
    static func hmac(_ data:Data,key:Data)->Data {
        var bytes=[UInt8](repeating:0,count:Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes {k in data.withUnsafeBytes {d in CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),k.baseAddress,key.count,d.baseAddress,data.count,&bytes)}}
        return Data(bytes)
    }
    func iv(ssrc:UInt32,index:UInt64)->Data {
        var iv=Data(salt);iv.append(contentsOf:[0,0])
        for i in 0..<4 {iv[4+i] ^= UInt8(truncatingIfNeeded:ssrc >> (24-i*8))}
        for i in 0..<6 {iv[8+i] ^= UInt8(truncatingIfNeeded:index >> (40-i*8))}
        return iv
    }
}

/// 4096 authenticated indices retain retransmissions across a250ms video burst;
/// a64-packet replay window would reject useful late repair at high RTP rates.
private struct NativeSRTPReplay {
    var highest:UInt64?
    var words=[UInt64](repeating:0,count:64)
    func estimate(sequence:UInt16)->UInt64 {
        guard let highest else {return UInt64(sequence)}
        let low=Int(highest & 0xffff),seq=Int(sequence),roc=UInt32(truncatingIfNeeded:highest >> 16)
        let guessed:UInt32
        if low<32768,seq-low>32768 {guessed=roc &- 1}
        else if low>=32768,low-32768>seq {guessed=roc &+ 1}
        else {guessed=roc}
        return (UInt64(guessed)<<16)|UInt64(sequence)
    }
    func permits(_ index:UInt64)->Bool {
        guard let highest else {return true}
        if index>highest {return true}
        guard highest-index<4096 else {return false}
        let slot=Int(index & 4095)
        return words[slot>>6] & (UInt64(1)<<UInt64(slot & 63)) == 0
    }
    mutating func accept(_ index:UInt64) {
        if let highest,index>highest {
            if index-highest>=4096 {words=[UInt64](repeating:0,count:64)}
            else {
                for i in (highest+1)...index {
                    let slot=Int(i & 4095);words[slot>>6] &= ~(UInt64(1)<<UInt64(slot & 63))
                }
            }
        }
        highest=max(highest ?? index,index)
        let slot=Int(index & 4095);words[slot>>6] |= UInt64(1)<<UInt64(slot & 63)
    }
}

private struct NativeRTPHeader {
    let sequence:UInt16,timestamp:UInt32,ssrc:UInt32,payloadType:UInt8,marker:Bool,padding:Bool,length:Int
    init(_ data:Data,tagBytes:Int)throws {
        guard data.count>=12+tagBytes,data[0]>>6==2 else {throw NativeMediaError.malformed}
        let bodyEnd=data.count-tagBytes
        var n=12+Int(data[0] & 15)*4
        guard n<=bodyEnd else {throw NativeMediaError.malformed}
        if data[0] & 0x10 != 0 {
            guard n+4<=bodyEnd else {throw NativeMediaError.malformed}
            n += 4+Int(Self.u16(data,n+2))*4
            guard n<=bodyEnd else {throw NativeMediaError.malformed}
        }
        sequence=Self.u16(data,2);timestamp=Self.u32(data,4);ssrc=Self.u32(data,8)
        payloadType=data[1] & 0x7f;marker=data[1] & 0x80 != 0;padding=data[0] & 0x20 != 0;length=n
    }
    static func u16(_ d:Data,_ i:Int)->UInt16 {(UInt16(d[i])<<8)|UInt16(d[i+1])}
    static func u32(_ d:Data,_ i:Int)->UInt32 {(UInt32(d[i])<<24)|(UInt32(d[i+1])<<16)|(UInt32(d[i+2])<<8)|UInt32(d[i+3])}
}

struct NativeMediaConfiguration:Sendable {
    var videoPayloadTypes:Set<UInt8>=[96]
    var rtxPayloadTypes:[UInt8:UInt8]=[97:96]
    var rtxSSRCs:[UInt32:UInt32]=[:]
    var parameterSets:[Data]=[]
    var donlPresent=false
    var reorderWindowNS:UInt64=250_000_000
    var startupReorderNS:UInt64=10_000_000
    var nackDelayNS:UInt64=8_000_000
    var nackRepeatNS:UInt64=30_000_000
    var maximumQueuedPackets=4096
    var maximumQueuedBytes=8_388_608
    var maximumAccessUnitBytes=16_777_216
    init() {}
}

/// Payload-free bounded diagnostics. uptimeNS shares the raw UDP/deadline clock;
/// monotonicNS shares the presentation clock for correlation on a live device.
struct NativeMediaRepairEvent:Codable,Sendable {
    var kind:String,uptimeNS:UInt64,monotonicNS:UInt64,mediaSSRC:UInt32
    var sequence:UInt16?,rtpTimestamp:UInt32?,packetCount:Int?,delayMS:Double?,reason:String?
}

struct NativeMediaStatistics:Codable,Sendable {
    var receivedDatagrams:UInt64=0,authenticatedPackets:UInt64=0,authenticationFailures:UInt64=0,replayDrops:UInt64=0
    var malformedPackets:UInt64=0,ignoredPayloadPackets:UInt64=0,retransmissionPackets:UInt64=0,latePackets:UInt64=0
    var nackRequests:UInt64=0,nackSequences:UInt64=0,keyframeRequests:UInt64=0,lostPackets:UInt64=0
    var discardedAccessUnits:UInt64=0,accessUnits:UInt64=0,randomAccessUnits:UInt64=0,accessUnitBytes:UInt64=0
    var accessUnitGapsOver500MS:UInt64=0,peakQueuedPackets=0,peakQueuedBytes=0
    var hasRandomAccess=false
    var repairArrivals:UInt64=0,repairArrivalsWithinDeadline:UInt64=0,repairArrivalsAfterDeadline:UInt64=0
    // Percentiles describe the last2048 arrivals; maximum is the session maximum.
    var firstNACKToRepairP50MS:Double?,firstNACKToRepairP95MS:Double?,firstNACKToRepairMaxMS:Double?
    var repairTimingWindowSamples=0,retainedRepairRequests=0
    var currentRepairDeadlineMS:Double=250
    var repairEvents:[NativeMediaRepairEvent]=[]
    var dictionary:[String:Any] {
        guard let data=try? JSONEncoder().encode(self),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {return [:]}
        return value
    }
}

final class NativeMediaReceiver:@unchecked Sendable {
    /// Callbacks run on the serial receiver queue; the decoder should enqueue
    /// work without blocking. Final UInt64 is AU completion CLOCK_MONOTONIC NS,
    /// matching CompanionClock.nowNS, not the raw datagram's uptime timestamp.
    var onAccessUnit:((Data,UInt32,Bool,UInt64)->Void)?
    var onNACK:((UInt32,[UInt16])->Void)?
    var onKeyframeNeeded:(()->Void)?
    var onStatistics:((NativeMediaStatistics)->Void)?
    let queue:DispatchQueue
    private let specific=DispatchSpecificKey<UInt8>()
    private var timer:DispatchSourceTimer?
    private var configuration:NativeMediaConfiguration
    private var keys:NativeSRTPKeys?
    private var replay:[UInt32:NativeSRTPReplay]=[:]
    private var streams:[UInt32:Stream]=[:]
    private var counters=NativeMediaStatistics()
    private var repairTimingMS:[Double]=[],repairTimingCursor=0
    private static let maximumRepairRequests=4096,maximumRepairSamples=2048
    private static let repairHistoryNS:UInt64=2_000_000_000
    private var lastStatisticsNS:UInt64=0,lastKeyframeRequestNS:UInt64?,lastAUUptimeNS:UInt64?
    private struct Packet {
        var sequence:UInt16,index:Int64,timestamp:UInt32,ssrc:UInt32,payloadType:UInt8,marker:Bool,payload:Data,receivedNS:UInt64
    }
    private struct Fragment {var header0:UInt8,header1:UInt8,data:Data}
    private final class AccessUnit {
        let timestamp:UInt32,startedNS:UInt64
        var bytes=Data(),nalTypes=Set<UInt8>(),fragment:Fragment?,damaged=false,nalCount=0
        init(timestamp:UInt32,startedNS:UInt64) {self.timestamp=timestamp;self.startedNS=startedNS}
    }
    private struct RepairRequest {
        var firstNACKNS:UInt64,deadlineNS:UInt64,retireNS:UInt64,expired=false
    }
    private final class Stream {
        var packets:[Int64:Packet]=[:],queuedBytes=0,expected:Int64?,highest:Int64?
        var firstNS:UInt64?,started=false,gapNS:UInt64?,lastNackNS:UInt64?
        var au:AccessUnit?
        var repairRequests:[Int64:RepairRequest]=[:]
        var lastRepairCleanupNS:UInt64=0
        var parameterSets:[UInt8:Data]=[:]
        init(parameterSets:[Data]) {
            for nal in parameterSets {if let type=NativeMediaReceiver.nalType(nal),(32...34).contains(type) {self.parameterSets[type]=nal}}
        }
    }
    init(queue:DispatchQueue?=nil,configuration:NativeMediaConfiguration = .init(),automaticPolling:Bool=true) {
        self.queue=queue ?? DispatchQueue(label:"studio.resolvescopes.native.media",qos:.userInitiated)
        self.configuration=Self.sanitized(configuration)
        self.queue.setSpecific(key:specific,value:1)
        if automaticPolling {
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now() + .milliseconds(5),repeating:.milliseconds(5),leeway:.milliseconds(1))
            timer.setEventHandler {[weak self] in self?.pollOnQueue(DispatchTime.now().uptimeNanoseconds)}
            self.timer=timer;timer.resume()
        }
    }
    deinit {timer?.cancel()}
    private func synchronized<T>(_ body:()->T)->T {if DispatchQueue.getSpecific(key:specific) != nil {return body()};return queue.sync(execute:body)}
    private func synchronizedThrowing<T>(_ body:()throws->T)throws->T {if DispatchQueue.getSpecific(key:specific) != nil {return try body()};return try queue.sync(execute:body)}
    var statistics:NativeMediaStatistics {synchronized{statisticsSnapshot()}}
    private func statisticsSnapshot()->NativeMediaStatistics {
        var result=counters
        result.currentRepairDeadlineMS=Double(configuration.reorderWindowNS)/1_000_000
        result.retainedRepairRequests=streams.values.reduce(0){$0+$1.repairRequests.count}
        result.repairTimingWindowSamples=repairTimingMS.count
        if !repairTimingMS.isEmpty {
            let sorted=repairTimingMS.sorted()
            result.firstNACKToRepairP50MS=sorted[Int((Double(sorted.count-1)*0.50).rounded(.up))]
            result.firstNACKToRepairP95MS=sorted[Int((Double(sorted.count-1)*0.95).rounded(.up))]
        }
        return result
    }
    /// Informational initial/new-stream status only. It never gates access units.
    var requiresRandomAccess:Bool {synchronized{!counters.hasRandomAccess}}
    func configure(_ value:NativeMediaConfiguration) {synchronized {configuration=Self.sanitized(value);streams.removeAll();counters.hasRandomAccess=false}}
    func configure(metadata:[String:Any]) {
        let media=(metadata["media"] as? [String:Any]) ?? metadata
        guard media["videoPayloadTypes"] != nil else {return}
        synchronized {
            var value=configuration
            if let types=media["videoPayloadTypes"] as? [Int] {
                value.videoPayloadTypes=Set(types.compactMap{($0>=0 && $0<128) ? UInt8($0):nil})
            }
            if let map=media["rtxPayloadTypes"] as? [String:Int] {
                value.rtxPayloadTypes=[:]
                for (key,type) in map {if let pt=UInt8(key),pt<128,type>=0,type<128 {value.rtxPayloadTypes[pt]=UInt8(type)}}
            }
            if let map=media["rtxSSRCs"] as? [String:Int] {
                value.rtxSSRCs=[:]
                for (key,ssrc) in map {if let rtx=UInt32(key),let media=UInt32(exactly:ssrc) {value.rtxSSRCs[rtx]=media}}
            }
            if let sets=media["parameterSets"] as? [String] {
                value.parameterSets=sets.prefix(16).compactMap {text in
                    guard text.utf8.count<=90_000,let nal=Data(base64Encoded:text),nal.count<=65_536 else {return nil}
                    return nal
                }
            }
            if let donl=media["donlPresent"] as? Bool {value.donlPresent=donl}
            configuration=Self.sanitized(value);streams.removeAll();counters.hasRandomAccess=false
        }
    }
    func installKeys(masterKey:Data,masterSalt:Data,profile:Int)throws {
        let derived=try NativeSRTPKeys(masterKey:masterKey,masterSalt:masterSalt,profile:profile)
        // Rekeying preserves ROC and replay history; reset() begins a new DTLS
        // association. Unauthenticated traffic never changes either value.
        synchronized{keys=derived}
    }
    func reset() {synchronized {keys=nil;replay.removeAll();streams.removeAll();counters=NativeMediaStatistics();lastStatisticsNS=0;lastKeyframeRequestNS=nil;lastAUUptimeNS=nil;repairTimingMS.removeAll();repairTimingCursor=0}}
    func receive(_ datagram:Data,receivedNS:UInt64) {synchronized{receiveOnQueue(datagram,receivedNS:receivedNS)}}
    func poll(nowNS:UInt64) {synchronized{pollOnQueue(nowNS)}}
    private static func sanitized(_ input:NativeMediaConfiguration)->NativeMediaConfiguration {
        var c=input
        c.videoPayloadTypes=Set(c.videoPayloadTypes.filter{$0<128})
        c.rtxPayloadTypes=c.rtxPayloadTypes.filter{$0.key<128 && c.videoPayloadTypes.contains($0.value)}
        c.reorderWindowNS=min(500_000_000,max(100_000_000,c.reorderWindowNS))
        c.startupReorderNS=min(30_000_000,c.startupReorderNS)
        c.nackDelayNS=min(30_000_000,c.nackDelayNS);c.nackRepeatNS=max(10_000_000,min(100_000_000,c.nackRepeatNS))
        c.maximumQueuedPackets=max(64,min(8192,c.maximumQueuedPackets));c.maximumQueuedBytes=max(65_536,min(33_554_432,c.maximumQueuedBytes))
        c.maximumAccessUnitBytes=max(65_536,min(33_554_432,c.maximumAccessUnitBytes))
        c.parameterSets=Array(c.parameterSets.filter{$0.count<=65_536}.prefix(16))
        return c
    }
    private func receiveOnQueue(_ d:Data,receivedNS:UInt64) {
        counters.receivedDatagrams &+= 1
        guard let keys else {counters.ignoredPayloadPackets &+= 1;return}
        guard d.count<=65_535 else {counters.malformedPackets &+= 1;return}
        do {
            let header=try NativeRTPHeader(d,tagBytes:keys.tagBytes)
            guard configuration.videoPayloadTypes.contains(header.payloadType) || configuration.rtxPayloadTypes[header.payloadType] != nil else {counters.ignoredPayloadPackets &+= 1;return}
            guard replay[header.ssrc] != nil || replay.count<8 else {counters.ignoredPayloadPackets &+= 1;return}
            var context=replay[header.ssrc] ?? NativeSRTPReplay()
            let index=context.estimate(sequence:header.sequence)
            guard context.permits(index) else {throw NativeMediaError.replay}
            let end=d.count-keys.tagBytes
            var authenticated=Data(d.prefix(end)),roc=UInt32(truncatingIfNeeded:index>>16).bigEndian
            withUnsafeBytes(of:&roc){authenticated.append(contentsOf:$0)}
            let expected=NativeSRTPKeys.hmac(authenticated,key:keys.authentication)
            var mismatch:UInt8=0
            for i in 0..<keys.tagBytes {mismatch |= expected[i] ^ d[end+i]}
            guard mismatch==0 else {throw NativeMediaError.authentication}
            var payload=try NativeSRTPKeys.crypt(Data(d[header.length..<end]),key:keys.encryption,iv:keys.iv(ssrc:header.ssrc,index:index))
            if header.padding {
                guard let count=payload.last,count>0,Int(count)<=payload.count else {throw NativeMediaError.malformed}
                payload.removeLast(Int(count))
            }
            guard !payload.isEmpty else {throw NativeMediaError.malformed}
            context.accept(index);replay[header.ssrc]=context;counters.authenticatedPackets &+= 1
            var packet=Packet(sequence:header.sequence,index:Int64(index),timestamp:header.timestamp,ssrc:header.ssrc,payloadType:header.payloadType,marker:header.marker,payload:payload,receivedNS:receivedNS)
            if let originalPT=configuration.rtxPayloadTypes[header.payloadType] {
                guard payload.count>=3 else {throw NativeMediaError.malformed}
                let target:UInt32?
                if let explicit=configuration.rtxSSRCs[header.ssrc] {target=explicit}
                else if streams.count==1 {target=streams.keys.first}
                else {target=nil}
                guard let target,let stream=streams[target] else {counters.ignoredPayloadPackets &+= 1;return}
                packet.sequence=NativeRTPHeader.u16(payload,0);packet.payload=Data(payload.dropFirst(2));packet.payloadType=originalPT;packet.ssrc=target
                packet.index=Self.extended(packet.sequence,around:stream.highest ?? Int64(packet.sequence));counters.retransmissionPackets &+= 1
            }
            guard streams[packet.ssrc] != nil || streams.count<4 else {counters.ignoredPayloadPackets &+= 1;return}
            let stream=streams[packet.ssrc] ?? Stream(parameterSets:configuration.parameterSets)
            streams[packet.ssrc]=stream
            cleanupRepairRequests(stream,now:receivedNS)
            // Measure authenticated original/RTX arrivals before the late-order
            // rejection. Expired NACK records survive another2s for attribution.
            recordRepairArrival(packet,stream:stream,now:receivedNS)
            if let expected=stream.expected,stream.started,packet.index<expected {counters.latePackets &+= 1;return}
            guard stream.packets[packet.index]==nil else {counters.latePackets &+= 1;return}
            stream.highest=max(stream.highest ?? packet.index,packet.index)
            stream.packets[packet.index]=packet;stream.queuedBytes += packet.payload.count
            if stream.firstNS==nil {stream.firstNS=receivedNS;stream.expected=packet.index}
            if !stream.started {stream.expected=min(stream.expected ?? packet.index,packet.index)}
            counters.peakQueuedPackets=max(counters.peakQueuedPackets,stream.packets.count);counters.peakQueuedBytes=max(counters.peakQueuedBytes,stream.queuedBytes)
            drain(stream,ssrc:packet.ssrc,now:receivedNS)
        }catch NativeMediaError.authentication {counters.authenticationFailures &+= 1}
        catch NativeMediaError.replay {counters.replayDrops &+= 1}
        catch {counters.malformedPackets &+= 1}
    }
    private static func extended(_ sequence:UInt16,around highest:Int64)->Int64 {
        var candidate=(highest & ~Int64(0xffff))|Int64(sequence)
        if candidate-highest>32768 {candidate-=65536}
        else if highest-candidate>32768 {candidate+=65536}
        return candidate
    }
    private func pollOnQueue(_ now:UInt64) {
        for (ssrc,stream) in streams {
            cleanupRepairRequests(stream,now:now)
            drain(stream,ssrc:ssrc,now:now)
            if let au=stream.au,now>=au.startedNS,now-au.startedNS>configuration.reorderWindowNS,stream.packets.isEmpty {
                discard(stream,ssrc:ssrc,now:now,reason:"unfinished-au-timeout");requestKeyframe(now)
            }
        }
        if now>=lastStatisticsNS,now-lastStatisticsNS>=1_000_000_000 {lastStatisticsNS=now;onStatistics?(statisticsSnapshot())}
    }
    private func drain(_ stream:Stream,ssrc:UInt32,now:UInt64) {
        if !stream.started {
            guard let first=stream.firstNS,now>=first,now-first>=configuration.startupReorderNS else {return}
            stream.started=true
        }
        while let expected=stream.expected {
            if let packet=stream.packets.removeValue(forKey:expected) {
                stream.queuedBytes -= packet.payload.count;stream.expected=expected+1;stream.gapNS=nil;stream.lastNackNS=nil
                consume(packet,stream:stream,now:now);continue
            }
            guard let next=stream.packets.keys.min(),next>expected else {return}
            let first=stream.gapNS ?? (stream.packets[next]?.receivedNS ?? now)
            stream.gapNS=first
            let age=now>=first ? now-first:0
            if age>=configuration.nackDelayNS,(stream.lastNackNS==nil || (now>=stream.lastNackNS! && now-stream.lastNackNS!>=configuration.nackRepeatNS)) {
                let count=min(256,next-expected),missing=(0..<count).map{UInt16(truncatingIfNeeded:expected+$0)}
                if let onNACK,!missing.isEmpty {
                    var firstRequests=0
                    for offset in 0..<count where stream.repairRequests[expected+offset]==nil {
                        // Retire oldest deadlines first under an extreme burst;
                        // this bounds diagnostics independently from media queues.
                        if stream.repairRequests.count>=Self.maximumRepairRequests,
                           let oldest=stream.repairRequests.min(by:{$0.value.retireNS<$1.value.retireNS})?.key {
                            stream.repairRequests.removeValue(forKey:oldest)
                        }
                        let deadline=first+configuration.reorderWindowNS
                        stream.repairRequests[expected+offset]=RepairRequest(firstNACKNS:now,deadlineNS:deadline,retireNS:deadline+Self.repairHistoryNS)
                        firstRequests+=1
                    }
                    if firstRequests>0 {recordEvent("nack",ssrc:ssrc,sequence:UInt16(truncatingIfNeeded:expected),timestamp:stream.packets[next]?.timestamp,count:firstRequests,now:now)}
                    onNACK(ssrc,missing);counters.nackRequests &+= 1;counters.nackSequences &+= UInt64(missing.count)
                }
                stream.lastNackNS=now
            }
            let overflow=stream.packets.count>configuration.maximumQueuedPackets || stream.queuedBytes>configuration.maximumQueuedBytes
            guard age>=configuration.reorderWindowNS || overflow else {return}
            counters.lostPackets &+= UInt64(next-expected)
            for index in stream.repairRequests.keys where index>=expected && index<next {
                stream.repairRequests[index]?.expired=true
                stream.repairRequests[index]?.retireNS=now+Self.repairHistoryNS
            }
            recordEvent("loss",ssrc:ssrc,sequence:UInt16(truncatingIfNeeded:expected),timestamp:stream.au?.timestamp ?? stream.packets[next]?.timestamp,count:Int(next-expected),now:now,delayMS:Double(age)/1_000_000,reason:overflow ? "queue-bound":"repair-deadline")
            if let au=stream.au {au.damaged=true;au.fragment=nil}
            stream.expected=next;stream.gapNS=nil;stream.lastNackNS=nil;requestKeyframe(now)
        }
    }
    private func requestKeyframe(_ now:UInt64) {
        if let last=lastKeyframeRequestNS,now>=last,now-last<1_000_000_000 {return}
        lastKeyframeRequestNS=now
        if let onKeyframeNeeded {onKeyframeNeeded();counters.keyframeRequests &+= 1}
    }
    private func cleanupRepairRequests(_ stream:Stream,now:UInt64) {
        guard now>=stream.lastRepairCleanupNS,now-stream.lastRepairCleanupNS>=100_000_000 else {return}
        stream.lastRepairCleanupNS=now
        stream.repairRequests=stream.repairRequests.filter{$0.value.retireNS>=now}
    }
    private func recordRepairArrival(_ packet:Packet,stream:Stream,now:UInt64) {
        guard let request=stream.repairRequests.removeValue(forKey:packet.index),now>=request.firstNACKNS,now<=request.retireNS else {return}
        let delay=Double(now-request.firstNACKNS)/1_000_000
        let within = !request.expired && now<=request.deadlineNS
        counters.repairArrivals &+= 1
        if within {counters.repairArrivalsWithinDeadline &+= 1}else {counters.repairArrivalsAfterDeadline &+= 1}
        counters.firstNACKToRepairMaxMS=max(counters.firstNACKToRepairMaxMS ?? delay,delay)
        if repairTimingMS.count<Self.maximumRepairSamples {repairTimingMS.append(delay)}
        else {repairTimingMS[repairTimingCursor]=delay;repairTimingCursor=(repairTimingCursor+1)%Self.maximumRepairSamples}
        recordEvent("repair",ssrc:packet.ssrc,sequence:packet.sequence,timestamp:packet.timestamp,now:now,delayMS:delay,reason:within ? "within-deadline":"after-deadline")
    }
    private func recordEvent(_ kind:String,ssrc:UInt32,sequence:UInt16?=nil,timestamp:UInt32?=nil,count:Int?=nil,now:UInt64,delayMS:Double?=nil,reason:String?=nil) {
        var t=timespec();clock_gettime(CLOCK_MONOTONIC,&t)
        let monotonicNS=UInt64(t.tv_sec)*1_000_000_000+UInt64(t.tv_nsec)
        if counters.repairEvents.count>=64 {counters.repairEvents.removeFirst()}
        counters.repairEvents.append(NativeMediaRepairEvent(kind:kind,uptimeNS:now,monotonicNS:monotonicNS,mediaSSRC:ssrc,sequence:sequence,rtpTimestamp:timestamp,packetCount:count,delayMS:delayMS,reason:reason))
    }
    private func discard(_ stream:Stream,ssrc:UInt32,now:UInt64,reason:String) {
        if let au=stream.au {
            counters.discardedAccessUnits &+= 1;stream.au=nil
            recordEvent("au-discard",ssrc:ssrc,timestamp:au.timestamp,now:now,reason:reason)
        }
    }
    private static func nalType(_ nal:Data)->UInt8? {
        guard nal.count>=2,nal[0] & 0x80 == 0,nal[1] & 7 != 0 else {return nil}
        let type=(nal[0]>>1)&63
        return type<=47 ? type:nil
    }
    private func appendNAL(_ nal:Data,to au:AccessUnit,stream:Stream)throws {
        guard let type=Self.nalType(nal),au.nalCount<128,au.bytes.count+nal.count+4<=configuration.maximumAccessUnitBytes else {throw NativeMediaError.malformed}
        au.bytes.append(contentsOf:[0,0,0,1]);au.bytes.append(nal);au.nalTypes.insert(type);au.nalCount+=1
        if (32...34).contains(type),nal.count<=65_536 {stream.parameterSets[type]=nal}
    }
    private func consume(_ packet:Packet,stream:Stream,now:UInt64) {
        if let au=stream.au,au.timestamp != packet.timestamp {discard(stream,ssrc:packet.ssrc,now:now,reason:"timestamp-before-marker");requestKeyframe(now)}
        if stream.au==nil {stream.au=AccessUnit(timestamp:packet.timestamp,startedNS:packet.receivedNS)}
        guard let au=stream.au else {return}
        do {
            let p=packet.payload
            guard p.count>=2,p[0] & 0x80 == 0,p[1] & 7 != 0 else {throw NativeMediaError.malformed}
            let type=(p[0]>>1)&63
            if type<=47 {
                guard au.fragment==nil else {throw NativeMediaError.malformed}
                let nal:Data
                if configuration.donlPresent {guard p.count>=5 else {throw NativeMediaError.malformed};nal=Data(p.prefix(2))+Data(p.dropFirst(4))}
                else {nal=p}
                try appendNAL(nal,to:au,stream:stream)
            }else if type==48 {
                guard au.fragment==nil else {throw NativeMediaError.malformed}
                var offset=configuration.donlPresent ? 4:2,count=0
                while offset<p.count {
                    if count>0,configuration.donlPresent {guard offset+1<p.count else {throw NativeMediaError.malformed};offset+=1}
                    guard offset+2<=p.count else {throw NativeMediaError.malformed}
                    let length=Int(NativeRTPHeader.u16(p,offset));offset+=2
                    guard length>=2,offset+length<=p.count else {throw NativeMediaError.malformed}
                    try appendNAL(Data(p[offset..<(offset+length)]),to:au,stream:stream);offset+=length;count+=1
                }
                guard count>=2 else {throw NativeMediaError.malformed}
            }else if type==49 {
                guard p.count>=4 else {throw NativeMediaError.malformed}
                let start=p[2] & 0x80 != 0,end=p[2] & 0x40 != 0,fuType=p[2]&63
                guard !(start && end),fuType<=47 else {throw NativeMediaError.malformed}
                let header0=(p[0]&0x81)|(fuType<<1),offset=(configuration.donlPresent && start) ? 5:3
                guard offset<p.count else {throw NativeMediaError.malformed}
                if start {
                    guard au.fragment==nil else {throw NativeMediaError.malformed}
                    var nal=Data([header0,p[1]]);nal.append(p.dropFirst(offset))
                    guard nal.count+au.bytes.count+4<=configuration.maximumAccessUnitBytes else {throw NativeMediaError.malformed}
                    au.fragment=Fragment(header0:header0,header1:p[1],data:nal)
                }else {
                    guard var fragment=au.fragment,fragment.header0==header0,fragment.header1==p[1],
                          fragment.data.count+p.count-offset+au.bytes.count+4<=configuration.maximumAccessUnitBytes else {throw NativeMediaError.malformed}
                    fragment.data.append(p.dropFirst(offset));au.fragment=fragment
                    if end {au.fragment=nil;try appendNAL(fragment.data,to:au,stream:stream)}
                }
            }else {throw NativeMediaError.malformed} // PACI/interleaving not negotiated.
        }catch {au.damaged=true;au.fragment=nil;counters.malformedPackets &+= 1;requestKeyframe(now)}
        guard packet.marker else {return}
        defer {stream.au=nil}
        guard !au.damaged,au.fragment==nil,!au.bytes.isEmpty else {counters.discardedAccessUnits &+= 1;recordEvent("au-discard",ssrc:packet.ssrc,timestamp:au.timestamp,now:now,reason:au.damaged ? "damaged":"incomplete");requestKeyframe(now);return}
        let key=au.nalTypes.contains{(16...23).contains($0)}
        var bytes=Data()
        if key {
            for type:UInt8 in [32,33,34] where !au.nalTypes.contains(type) {
                if let nal=stream.parameterSets[type] {bytes.append(contentsOf:[0,0,0,1]);bytes.append(nal)}
            }
        }
        guard bytes.count+au.bytes.count<=configuration.maximumAccessUnitBytes else {counters.discardedAccessUnits &+= 1;recordEvent("au-discard",ssrc:packet.ssrc,timestamp:au.timestamp,now:now,reason:"au-byte-bound");requestKeyframe(now);return}
        bytes.append(au.bytes)
        if key {counters.randomAccessUnits &+= 1;counters.hasRandomAccess=true}
        if !counters.hasRandomAccess {requestKeyframe(now)}
        counters.accessUnits &+= 1;counters.accessUnitBytes &+= UInt64(bytes.count)
        if let last=lastAUUptimeNS,now>=last,now-last>500_000_000 {counters.accessUnitGapsOver500MS &+= 1}
        lastAUUptimeNS=now
        var t=timespec();clock_gettime(CLOCK_MONOTONIC,&t)
        let completedNS=UInt64(t.tv_sec)*1_000_000_000+UInt64(t.tv_nsec)
        onAccessUnit?(bytes,packet.timestamp,key,completedNS)
    }
}
