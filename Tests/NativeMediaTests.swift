import Foundation

/// Standalone native protocol tests; test vectors are public RFC3711/RFC2202
/// values, not captured session keys or footage. Run script/test_native_media.sh.
@main struct NativeMediaTests {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static let key=hex("e1f97a0d3e018be0d64fa32c06de4139"),salt=hex("0ec675ad498afeebb6960b3aabe6")
    static var checks=0
    static func hex(_ text:String)->Data {
        var out=Data(),i=text.startIndex
        while i<text.endIndex {let j=text.index(i,offsetBy:2);out.append(UInt8(text[i..<j],radix:16)!);i=j}
        return out
    }
    static func check(_ value:@autoclosure ()->Bool,_ message:String)throws {checks+=1;if !value() {throw Failure(description:message)}}
    static func u16(_ value:UInt16)->Data {Data([UInt8(truncatingIfNeeded:value>>8),UInt8(truncatingIfNeeded:value)])}
    static func u32(_ value:UInt32)->Data {Data([UInt8(truncatingIfNeeded:value>>24),UInt8(truncatingIfNeeded:value>>16),UInt8(truncatingIfNeeded:value>>8),UInt8(truncatingIfNeeded:value)])}
    static func protected(sequence:UInt16,timestamp:UInt32=9000,ssrc:UInt32=0x11223344,marker:Bool=true,payload:Data=Data([0x26,1,0x80]),pt:UInt8=96,roc:UInt32=0,
                          extendedHeader:Bool=false,padding:Int=0,masterKey:Data=key,profile:Int=1)throws->Data {
        let keys=try NativeSRTPKeys(masterKey:masterKey,masterSalt:salt,profile:profile)
        var header=Data([UInt8(0x80|(extendedHeader ? 0x12:0)|(padding>0 ? 0x20:0)),(marker ? 0x80:0)|pt])+u16(sequence)+u32(timestamp)+u32(ssrc)
        if extendedHeader {header.append(hex("0102030405060708bede000111aa0000"))} // 2CSRCs + 1word extension
        var content=payload
        if padding>0 {content.append(Data(repeating:0,count:padding-1));content.append(UInt8(padding))}
        let index=(UInt64(roc)<<16)|UInt64(sequence)
        let cipher=try NativeSRTPKeys.crypt(content,key:keys.encryption,iv:keys.iv(ssrc:ssrc,index:index))
        let packet=header+cipher,tag=NativeSRTPKeys.hmac(packet+u32(roc),key:keys.authentication)
        return packet+tag.prefix(keys.tagBytes)
    }
    static func receiver(_ config:NativeMediaConfiguration?=nil)throws->NativeMediaReceiver {
        var c=config ?? NativeMediaConfiguration();c.startupReorderNS=0
        let rx=NativeMediaReceiver(configuration:c,automaticPolling:false)
        try rx.installKeys(masterKey:key,masterSalt:salt,profile:1);return rx
    }
    static func vectors()throws {
        let keys=try NativeSRTPKeys(masterKey:key,masterSalt:salt,profile:1)
        try check(keys.encryption==hex("c61e7a93744f39ee10734afe3ff7a087"),"RFC3711 B3 encryption KDF")
        try check(keys.salt==hex("30cbbc08863d8c85d49db34a9ae1"),"RFC3711 B3 salt KDF")
        try check(keys.authentication==hex("cebe321f6ff7716b6fd4ab49af256a156d38baa4"),"RFC3711 B3 authentication KDF")
        let stream=try NativeSRTPKeys.crypt(Data(repeating:0,count:48),key:hex("2b7e151628aed2a6abf7158809cf4f3c"),iv:hex("f0f1f2f3f4f5f6f7f8f9fafbfcfd0000"))
        try check(stream==hex("e03ead0935c95e80e166b16dd92b4eb4d23513162b02d0f72a43a2fe4a5f97ab41e95b3bb0a2e8dd477901e4fca894c0"),"RFC3711 B2 AES-CM first3 blocks")
        try check(NativeSRTPKeys.hmac(Data("Hi There".utf8),key:Data(repeating:0x0b,count:20))==hex("b617318655057264e28bc0b6fb378c8ef146be00"),"RFC2202 HMAC-SHA1 vector1")
        // Widely used libSRTP reference packet, additionally anchored to the
        // independently checked KDF, counter-mode and HMAC primitives above.
        let packet=try protected(sequence:0x1234,timestamp:0xdecafbad,ssrc:0xcafebabe,marker:false,payload:Data(repeating:0xab,count:16),pt:15)
        try check(packet==hex("800f1234decafbadcafebabe4e55dc4ce79978d88ca4d215949d2402b78d6acc99ea179b8dbb"),"SRTP reference packet")
        do {_=try NativeSRTPKeys(masterKey:key,masterSalt:salt,profile:3);throw Failure(description:"unknown SRTP profile accepted")}
        catch NativeMediaError.unsupportedProfile {}
        print("PASS RFC3711/RFC2202 key derivation, AES-CM, HMAC and SRTP reference vectors")
    }
    static func authenticationReplayAndRollover()throws {
        let rx=try receiver();var timestamps=[UInt32]()
        rx.onAccessUnit={_,ts,_,_ in timestamps.append(ts)}
        let a=try protected(sequence:65535,timestamp:1)
        rx.receive(a,receivedNS:1_000_000_000)
        rx.receive(a,receivedNS:1_001_000_000)
        var tampered=try protected(sequence:0,timestamp:2,roc:1);tampered[tampered.count-1] ^= 1
        rx.receive(tampered,receivedNS:1_002_000_000)
        rx.receive(try protected(sequence:0,timestamp:2,roc:1),receivedNS:1_003_000_000)
        rx.receive(try protected(sequence:65534,timestamp:0,roc:0),receivedNS:1_004_000_000)
        rx.receive(try protected(sequence:1,timestamp:3,roc:1),receivedNS:1_005_000_000)
        try check(rx.statistics.authenticatedPackets==4,"authenticated rollover and previous ROC packet")
        try check(rx.statistics.authenticationFailures==1 && rx.statistics.replayDrops==1,"tamper/replay independently rejected")
        try check(timestamps==[1,2,3],"rollover delivers ordered media and discards genuinely late old AU")
        var newKey=key;newKey[newKey.count-1] ^= 1
        try rx.installKeys(masterKey:newKey,masterSalt:salt,profile:1)
        rx.receive(try protected(sequence:2,timestamp:4,roc:1,masterKey:newKey),receivedNS:1_006_000_000)
        try check(timestamps.last==4,"rekey preserves ROC")
        let short=NativeMediaReceiver(automaticPolling:false)
        try short.installKeys(masterKey:key,masterSalt:salt,profile:2)
        var shortAU=0;short.onAccessUnit={_,_,_,_ in shortAU+=1}
        short.receive(try protected(sequence:10,profile:2),receivedNS:1_000_000_000);short.poll(nowNS:1_020_000_000)
        try check(shortAU==1 && short.statistics.authenticatedPackets==1,"SHA1_32 profile")
        let guarded=try receiver()
        guarded.receive(try protected(sequence:4),receivedNS:1_000_000_000)
        var forged=try protected(sequence:30000);forged[forged.count-2] ^= 1
        guarded.receive(forged,receivedNS:1_001_000_000)
        guarded.receive(try protected(sequence:5),receivedNS:1_002_000_000)
        try check(guarded.statistics.authenticatedPackets==2 && guarded.statistics.authenticationFailures==1,"forged sequence cannot advance ROC/replay state")
        print("PASS authenticated SRTP, tamper/replay rejection, rollover, previous ROC, rekey and SHA1_32")
    }
    static func rtpAndAP()throws {
        let rx=try receiver();var output=[Data]()
        rx.onAccessUnit={bytes,_,_,_ in output.append(bytes)}
        let nal=Data([0x26,1,0x80,0x11])
        rx.receive(try protected(sequence:1,payload:nal,extendedHeader:true,padding:8),receivedNS:1_000_000_000)
        try check(output.first==Data([0,0,0,1])+nal,"RTP CSRC/extension/padding boundaries")
        let vps=Data([64,1,0xaa]),sps=Data([66,1,0xbb]),pps=Data([68,1,0xcc])
        let ap=Data([96,1])+u16(UInt16(vps.count))+vps+u16(UInt16(sps.count))+sps+u16(UInt16(pps.count))+pps
        rx.receive(try protected(sequence:2,timestamp:12000,payload:ap),receivedNS:1_001_000_000)
        let expected=[vps,sps,pps].reduce(Data()){$0+Data([0,0,0,1])+$1}
        try check(output.last==expected,"HEVC AP preserves all NAL boundaries")
        rx.receive(try protected(sequence:3,timestamp:15000,payload:nal),receivedNS:1_002_000_000)
        try check(output.last==expected+Data([0,0,0,1])+nal,"same-source cached parameter sets prefix random-access AU")
        let count=output.count
        rx.receive(try protected(sequence:4,timestamp:18000,payload:Data([96,1,0,20,0x26,1])),receivedNS:1_003_000_000)
        rx.receive(try protected(sequence:5,timestamp:21000,payload:Data([0x80,1,0x80])),receivedNS:1_004_000_000)
        rx.receive(try protected(sequence:6,timestamp:24000,payload:Data([2,0,0x80])),receivedNS:1_005_000_000)
        try check(output.count==count && rx.statistics.discardedAccessUnits==3,"malformed AP and forbidden/temporal-zero NALs rejected")
        print("PASS RTP variable headers/padding and independently validated HEVC single/AP NALs")
    }
    static func repairAfter75MS()throws {
        let rx=try receiver();var output=[Data](),nacks=[UInt16]()
        rx.onAccessUnit={bytes,_,_,_ in output.append(bytes)}
        rx.onNACK={_,sequences in nacks.append(contentsOf:sequences)}
        let start=Data([98,1,0x93,0x80]),middle=Data([98,1,0x13,0xaa]),end=Data([98,1,0x53,0xbb])
        let t:UInt64=2_000_000_000
        rx.receive(try protected(sequence:100,marker:false,payload:start),receivedNS:t)
        rx.receive(try protected(sequence:102,payload:end),receivedNS:t+2_000_000)
        rx.poll(nowNS:t+12_000_000)
        try check(nacks.contains(101) && output.isEmpty,"missing FU prompts NACK without premature AU discard")
        // More than a64/128-packet replay window passes while the repair waits.
        for seq in 103...1000 {
            rx.receive(try protected(sequence:UInt16(seq),timestamp:UInt32(seq)*3000,payload:Data([2,1,0x80])),receivedNS:t+20_000_000)
        }
        rx.receive(try protected(sequence:101,marker:false,payload:middle),receivedNS:t+75_000_000)
        try check(output.first==Data([0,0,0,1,0x26,1,0x80,0xaa,0xbb]),"75ms retransmission restores exact FU NAL")
        try check(rx.statistics.replayDrops==0 && rx.statistics.lostPackets==0 && rx.statistics.discardedAccessUnits==0,"late repair remains in replay/reorder windows")
        try check(output.count==899,"repaired AU and all complete queued successor AUs delivered")
        print("PASS missing FU repaired after75ms behind898 later packets; exact bytes and no loss latch")
    }
    static func lossDoesNotGateLaterPFrames()throws {
        var configuration=NativeMediaConfiguration();configuration.reorderWindowNS=150_000_000
        let rx=try receiver(configuration);var keys=[Bool](),pli=0
        rx.onAccessUnit={_,_,key,_ in keys.append(key)};rx.onKeyframeNeeded={pli+=1}
        let t:UInt64=3_000_000_000
        rx.receive(try protected(sequence:199,timestamp:15000),receivedNS:t)
        rx.receive(try protected(sequence:200,timestamp:18000,marker:false,payload:Data([98,1,0x81,0x80])),receivedNS:t+1_000_000)
        rx.receive(try protected(sequence:202,timestamp:18000,payload:Data([98,1,0x41,0xaa])),receivedNS:t+2_000_000)
        rx.poll(nowNS:t+153_000_000)
        try check(rx.statistics.discardedAccessUnits==1 && rx.statistics.lostPackets==1 && pli==1,"only known incomplete AU discarded after loss deadline")
        rx.receive(try protected(sequence:203,timestamp:21000,payload:Data([2,1,0x80,0xcc])),receivedNS:t+160_000_000)
        try check(keys==[true,false],"complete next P AU forwarded without waiting for keyframe")
        try check(!rx.requiresRandomAccess,"random-access state is initial/newstream informational, not a loss latch")
        let before=rx.statistics.authenticatedPackets
        rx.receive(try protected(sequence:201,timestamp:18000,marker:false,payload:Data([98,1,1,0xdd])),receivedNS:t+170_000_000)
        try check(rx.statistics.authenticatedPackets==before+1 && rx.statistics.latePackets==1,"too-late repair rejected by media order rather than corrupting next AU")
        print("PASS bounded150ms loss recovery: discard damaged AU and continue complete P AUs")
    }
    static func repairAfter200MSAndDiagnostics()throws {
        let t:UInt64=5_000_000_000
        func scenario(_ c:NativeMediaConfiguration)throws->(NativeMediaReceiver,[Data]) {
            let rx=try receiver(c);var output=[Data]()
            rx.onAccessUnit={bytes,_,_,_ in output.append(bytes)};rx.onNACK={_,_ in}
            rx.receive(try protected(sequence:100,marker:false,payload:Data([98,1,0x93,0x80])),receivedNS:t)
            rx.receive(try protected(sequence:102,payload:Data([98,1,0x53,0xbb])),receivedNS:t+2_000_000)
            rx.poll(nowNS:t+12_000_000)
            rx.poll(nowNS:t+153_000_000)
            // Repair uses authenticated RTX with the original sequence number.
            rx.receive(try protected(sequence:1,ssrc:0x55667788,marker:false,payload:u16(101)+Data([98,1,0x13,0xaa]),pt:97),receivedNS:t+200_000_000)
            return (rx,output)
        }
        let (smooth,output)=try scenario(NativeMediaConfiguration())
        try check(output==[Data([0,0,0,1,0x26,1,0x80,0xaa,0xbb])] && smooth.statistics.lostPackets==0,"default250ms reconstructs exact FU with200ms repair")
        let stats=smooth.statistics
        try check(stats.repairArrivals==1 && stats.repairArrivalsWithinDeadline==1 && stats.repairArrivalsAfterDeadline==0 && stats.firstNACKToRepairP50MS==188 && stats.firstNACKToRepairP95MS==188 && stats.firstNACKToRepairMaxMS==188,"firstNACK to authenticated RTX arrival measures188ms within deadline")
        var short=NativeMediaConfiguration();short.reorderWindowNS=150_000_000
        let (expired,discarded)=try scenario(short)
        try check(discarded.isEmpty && expired.statistics.lostPackets==1 && expired.statistics.latePackets==1,"explicit150ms expires before200ms repair")
        try check(expired.statistics.repairArrivalsAfterDeadline==1 && expired.statistics.firstNACKToRepairP95MS==188 && expired.statistics.repairEvents.contains{$0.kind=="loss" && $0.reason=="repair-deadline"} && expired.statistics.repairEvents.last?.reason=="after-deadline","expired NACK retained and timestamped late repair attributed")
        // A late original after expiry is also measured, beyond the old window.
        let late=try receiver(short);late.onNACK={_,_ in}
        late.receive(try protected(sequence:1),receivedNS:t)
        late.receive(try protected(sequence:3,timestamp:12000),receivedNS:t+2_000_000)
        late.poll(nowNS:t+12_000_000);late.poll(nowNS:t+153_000_000)
        late.receive(try protected(sequence:2,timestamp:10000),receivedNS:t+1_000_000_000)
        try check(late.statistics.repairArrivalsAfterDeadline==1 && late.statistics.firstNACKToRepairMaxMS==988,"expired request survives for2seconds and measures late original")
        late.receive(try protected(sequence:5,timestamp:15000),receivedNS:t+1_001_000_000)
        late.poll(nowNS:t+1_012_000_000);late.poll(nowNS:t+1_160_000_000)
        late.poll(nowNS:t+3_200_000_000)
        late.receive(try protected(sequence:4,timestamp:14000),receivedNS:t+3_201_000_000)
        try check(late.statistics.repairArrivals==1 && late.statistics.retainedRepairRequests==0,"expired diagnostics removed after bounded2second history")
        try check(stats.dictionary["firstNACKToRepairP95MS"] as? Double==188 && stats.dictionary["repairEvents"] != nil,"repair diagnostics appended to existing statistics dictionary")
        // Repeated repaired losses exercise bounded sample/event retention.
        let bounded=try receiver();bounded.onNACK={_,_ in}
        bounded.receive(try protected(sequence:1),receivedNS:t)
        for n in 0..<2100 {
            let base=UInt16(2+n*2),now=t+UInt64(n)*20_000_000
            bounded.receive(try protected(sequence:base+1,timestamp:UInt32(n+1)*3000),receivedNS:now+1_000_000)
            bounded.poll(nowNS:now+10_000_000)
            bounded.receive(try protected(sequence:base,timestamp:UInt32(n+1)*3000,marker:false,payload:Data([2,1,0x80])),receivedNS:now+11_000_000)
        }
        try check(bounded.statistics.repairArrivals==2100 && bounded.statistics.repairTimingWindowSamples==2048 && bounded.statistics.repairEvents.count==64 && bounded.statistics.retainedRepairRequests==0,"repair timing2048 and event64 rings stay bounded")
        print("PASS default250ms versus explicit150ms at200ms repair; firstNACK timing, expired2s history and bounded diagnostics")
    }
    static func startupRTXAndBounds()throws {
        var c=NativeMediaConfiguration();c.startupReorderNS=10_000_000
        let rx=NativeMediaReceiver(configuration:c,automaticPolling:false);try rx.installKeys(masterKey:key,masterSalt:salt,profile:1)
        var output=[Data]();rx.onAccessUnit={bytes,_,_,_ in output.append(bytes)}
        let t:UInt64=4_000_000_000
        rx.receive(try protected(sequence:11,payload:Data([98,1,0x53,0xbb])),receivedNS:t)
        rx.receive(try protected(sequence:10,marker:false,payload:Data([98,1,0x93,0x80])),receivedNS:t+2_000_000)
        rx.poll(nowNS:t+12_000_000)
        try check(output==[Data([0,0,0,1,0x26,1,0x80,0xbb])],"initial packet reorder does not truncate first FU")
        let rtx=try receiver();var recovered=0;rtx.onAccessUnit={_,_,_,_ in recovered+=1}
        rtx.receive(try protected(sequence:20,marker:false,payload:Data([98,1,0x93,0x80])),receivedNS:t)
        rtx.receive(try protected(sequence:22,payload:Data([98,1,0x53,0xcc])),receivedNS:t+1_000_000)
        rtx.receive(try protected(sequence:1,ssrc:0x55667788,marker:false,payload:u16(21)+Data([98,1,0x13,0xbb]),pt:97),receivedNS:t+75_000_000)
        try check(recovered==1 && rtx.statistics.retransmissionPackets==1,"authenticated RTX OSN repairs original media sequence")
        var limited=NativeMediaConfiguration();limited.maximumQueuedPackets=64
        let bounded=try receiver(limited)
        bounded.receive(try protected(sequence:1,marker:false,payload:Data([98,1,0x81,0x80])),receivedNS:t)
        for n in 3...300 {bounded.receive(try protected(sequence:UInt16(n),timestamp:UInt32(n)*3000,payload:Data([2,1,0x80])),receivedNS:t+20_000_000)}
        try check(bounded.statistics.peakQueuedPackets<=65 && bounded.statistics.lostPackets>0,"reorder memory bounded even before deadline")
        let meta=try receiver()
        meta.configure(metadata:["media":["videoPayloadTypes":[110],"rtxPayloadTypes":["111":110],"rtxSSRCs":["2":1],"parameterSets":[],"donlPresent":false]])
        meta.receive(try protected(sequence:1,pt:110),receivedNS:t)
        try check(meta.statistics.authenticatedPackets==1,"SDP metadata convenience honors negotiated payload type")
        print("PASS startup reorder, RTX, queue bounds and negotiated SDP media configuration")
    }
    static func main() {
        do {try vectors();try authenticationReplayAndRollover();try rtpAndAP();try repairAfter75MS();try lossDoesNotGateLaterPFrames();try startupRTXAndBounds();try repairAfter200MSAndDiagnostics();print("PASS \(checks) native media checks")}
        catch {FileHandle.standardError.write(Data("FAIL native media: \(error)\n".utf8));exit(1)}
    }
}
