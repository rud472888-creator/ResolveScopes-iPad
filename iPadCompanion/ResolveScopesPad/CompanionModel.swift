import SwiftUI
import QuartzCore
import Darwin

// This target no longer compiles the Mac-sharing client or its frame timers.
enum CompanionClock {
    static func nowNS()->UInt64 {var t=timespec();clock_gettime(CLOCK_MONOTONIC,&t);return UInt64(t.tv_sec)*1_000_000_000+UInt64(t.tv_nsec)}
}
struct ReceivedFrame {
    let packet:CompanionPacket
    let images:[CompanionPanel:UIImage]
    let receivedAt:Date
    let receivedNS:UInt64
    let decodedNS:UInt64
    var contentFingerprint:UInt64=0
    var viewImages:[UUID:UIImage]=[:]
    var viewRequests:[UUID:FullRasterScopeRequest]=[:]
    var viewKinds:[UUID:CompanionPanel]=[:]
}
private final class FrameMailbox:@unchecked Sendable {
    private let lock=NSLock();private var value:ReceivedFrame?
    func put(_ frame:ReceivedFrame) {lock.lock();value=frame;lock.unlock()}
    func take()->ReceivedFrame? {lock.lock();defer{lock.unlock()};let frame=value;value=nil;return frame}
}
private struct DisplaySample:Codable,Sendable {
    let sequence:UInt64,receivedNS:UInt64,decodedNS:UInt64,submittedNS:UInt64,presentedNS:UInt64,contentFingerprint:UInt64
    let gpuTracePixels:Int,processingMS:Double
}
@MainActor final class CompanionModel:NSObject,ObservableObject {
    @Published var host=UserDefaults.standard.string(forKey:"host") ?? ""
    @Published private(set) var status="연결 전"
    @Published private(set) var connected=false
    @Published private(set) var connecting=false
    @Published private(set) var held=false
    @Published private(set) var displayed:ReceivedFrame?
    @Published private(set) var performanceText="네이티브 수신 측정 대기"
    @Published private(set) var remoteFormatDescription=""
    @Published var remotePrimaries=ColorSpace.rec709 {didSet{configureAnalysis()}}
    @Published var remoteTransfer=TransferFunction.gamma24 {didSet{configureAnalysis()}}
    @Published var remoteWaveformMode=WaveformMode.luma {didSet{configureAnalysis()}}
    @Published var remoteSampleWidth=480 {didSet{configureAnalysis()}}
    @Published var falseColorMode=UserDefaults.standard.string(forKey:"falseColorMode").flatMap(FalseColorStyle.init(rawValue:)) ?? .tvLogic {didSet{UserDefaults.standard.set(falseColorMode.rawValue,forKey:"falseColorMode");configureAnalysis()}}
    @Published var falseColorSpan:Double = {
        let defaults=UserDefaults.standard
        if !defaults.bool(forKey:"falseColorSpan25Migration1242") {
            defaults.set(25.0,forKey:"falseColorSpan");defaults.set(true,forKey:"falseColorSpan25Migration1242")
        }
        return defaults.object(forKey:"falseColorSpan") as? Double ?? 25
    }() {didSet{UserDefaults.standard.set(falseColorSpan,forKey:"falseColorSpan");configureAnalysis()}}
    @Published var falseColorCenter=UserDefaults.standard.object(forKey:"falseColorCenter") as? Double ?? 55 {didSet{UserDefaults.standard.set(falseColorCenter,forKey:"falseColorCenter");configureAnalysis()}}
    let scopesEnabled:Bool
    let videoPresenter=NativeVideoPresenter()
    private var session:RemoteSession?
    private var media:NativeMediaReceiver?
    private var decoder:NativeVideoDecoder?
    private var analyzer:LocalScopeAnalyzer?
    private var rasterViews:[UUID:FullRasterScopeRegistration]=[:]
    private var gate:NativeSessionGate?
    private var connectionID=UUID()
    private var mailbox=FrameMailbox()
    private var newest:ReceivedFrame?
    private var link:CADisplayLink?
    private var submitted:(ReceivedFrame,UInt64)?
    private var samples=[DisplaySample]()
    private var lastReport:UInt64=0
    private var events=[String](),controlStats=[String:Any](),mediaStats=[String:Any]()
    private var decoderEvents=[NativeDecodeEvent]()
    private let telemetryQueue=DispatchQueue(label:"studio.resolvescopes.native.telemetry",qos:.utility)
    private var writing=false
    var frameAge:TimeInterval? {videoPresenter.age}
    override init() {
        let args=ProcessInfo.processInfo.arguments
        scopesEnabled = !args.contains("--video-only")
        super.init()
        if args.contains("--scope-quality-benchmark") {
            status="스코프 품질 시험 중"
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                do {
                    let output=try LocalScopeAnalyzer.qualityBenchmark()
                    Task { @MainActor in
                        guard let self else {return}
                        let stats=output.statistics
                        let packet=CompanionPacket(session:UUID(),generation:1,sequence:1,source:"TEST · 품질 검증 신호",status:"실기기 연산 시험 완료",isTest:true,macHeld:false,dimensions:"GPU Trace3200×1800 · 수치480×270",conditions:output.conditions,metrics:["meanIRE":Double(stats.meanLuma)*100,"minIRE":Double(stats.minLuma)*100,"maxIRE":Double(stats.maxLuma)*100,"maxNits":stats.maxNits,"belowBlackPercent":stats.belowBlackPercent,"aboveWhitePercent":stats.aboveWhitePercent,"outOfGamutPercent":stats.outOfGamutPercent,"sampleCount":Double(stats.sampleCount)])
                        self.displayed=ReceivedFrame(packet:packet,images:output.images.mapValues{UIImage(cgImage:$0)},receivedAt:Date(),receivedNS:0,decodedNS:0,viewImages:output.viewImages.mapValues{UIImage(cgImage:$0)},viewRequests:output.viewRequests,viewKinds:output.viewKinds)
                        self.status="품질 검증 완료 · 연결 버튼으로 실영상 전환"
                    }
                } catch {Task { @MainActor in self?.status="품질 시험 실패 · \(error.localizedDescription)"} }
            }
            return
        }
        if let index=args.firstIndex(of:"--remote-host"),index+1<args.count {
            host=args[index+1];DispatchQueue.main.async{[weak self] in self?.connect()}
        }
    }
    func connect() {
        let host=host.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !host.isEmpty else{status="Resolve 주소를 입력하세요";return}
        disconnect();UIApplication.shared.isIdleTimerDisabled=true;connecting=true;status="네이티브 Resolve 연결 중"
        samples=[];events=[];controlStats=[:];mediaStats=[:];decoderEvents=[];lastReport=0
        let id=UUID(),gate=NativeSessionGate(),mailbox=FrameMailbox(),format=NativeFormatBox()
        connectionID=id;self.gate=gate;self.mailbox=mailbox
        let session=RemoteSession();let media=NativeMediaReceiver(queue:session.queue),decoder=NativeVideoDecoder()
        self.session=session;self.media=media;self.decoder=decoder
        session.onStatus={[weak self] text in Task{@MainActor in guard let self,self.connectionID==id else{return};self.status=text;self.record(text)}}
        session.onFailure={[weak self] text in Task{@MainActor in guard let self,self.connectionID==id else{return};self.disconnect();self.status=text;self.record(text)}}
        session.onSRTPKeys={[weak self] key,salt,profile in
            do {try media.installKeys(masterKey:key,masterSalt:salt,profile:profile)}
            catch {Task{@MainActor in guard let self,self.connectionID==id else{return};self.disconnect();self.status="SRTP 보안 세션 설정 실패"}}
        }
        session.onMediaDatagram={data,time in media.receive(data,receivedNS:time)}
        media.onNACK={[weak session] ssrc,sequences in session?.sendNACK(mediaSSRC:ssrc,sequences:sequences)}
        media.onKeyframeNeeded={[weak session] in session?.requestKeyframe()}
        media.onAccessUnit={data,timestamp,_,time in guard gate.isValid else{return};decoder.decode(data,timestamp:timestamp,receivedNS:time)}
        media.onStatistics={[weak self] stats in Task{@MainActor in guard let self,self.connectionID==id else{return};self.mediaStats=stats.dictionary}}
        session.onStats={[weak self] stats in Task{@MainActor in guard let self,self.connectionID==id else{return};self.controlStats=stats}}
        session.onMetadata={[weak self] metadata in
            if let config=metadata["media"] as? [String:Any] {media.configure(metadata:config);return}
            guard let timeline=metadata["timeline"] as? [String:Any] else{return}
            let codec=timeline["videoCodec"] as? Int ?? 2,chroma=codec==7 ? 2:1,depth=codec==1 ? 8:10
            let full=timeline["videoIsInFullRange"] as? Bool ?? false
            decoder.configure(chroma:chroma,depth:depth,fullRange:full)
            format.set(.init(fullRange:full,sourceDescription:"Resolve HEVC · 네이티브 수신",rawMetadata:timeline.mapValues{String(describing:$0)}))
            Task{@MainActor in
                guard let self,self.connectionID==id else{return}
                self.connected=true;self.connecting=false
                self.remoteFormatDescription="HEVC \(timeline["videoWidth"] ?? "?")×\(timeline["videoHeight"] ?? "?") · \(chroma==2 ? "4:2:2":"4:2:0") \(depth)-bit"
                self.record(self.remoteFormatDescription)
            }
        }
        decoder.onKeyframeNeeded={[weak session] in session?.requestKeyframe()}
        decoder.onEvent={[weak self] event in Task{@MainActor in guard let self,self.connectionID==id else{return};self.decoderEvents.append(event);if self.decoderEvents.count>128 {self.decoderEvents.removeFirst(self.decoderEvents.count-128)}}}
        decoder.onStatus={[weak self] text in Task{@MainActor in guard let self,self.connectionID==id else{return};self.status=text;self.record(text)}}
        let scopeSession=UUID()
        let analyzer=LocalScopeAnalyzer(onResult:{output in
            guard gate.isValid else{return}
            var fingerprint:UInt64=14695981039346656037
            for value in output.frame.rgba {fingerprint=(fingerprint ^ UInt64(value.bitPattern)) &* 1099511628211}
            let s=output.statistics
            let packet=CompanionPacket(session:scopeSession,generation:output.sequence,sequence:output.sequence,source:"Resolve · 네이티브 수신",status:output.gpuTracePixels>0 ? "GPU 전체 픽셀 Trace":"CPU 표본 Trace",isTest:false,macHeld:false,dimensions:"\(output.gpuTracePixels>0 ? "GPU Trace":"수신") \(output.frame.sourceWidth)×\(output.frame.sourceHeight) · 수치 \(output.frame.width)×\(output.frame.height)",conditions:output.conditions+"\n"+output.warnings.joined(separator:"\n"),metrics:["meanIRE":Double(s.meanLuma)*100,"minIRE":Double(s.minLuma)*100,"maxIRE":Double(s.maxLuma)*100,"maxNits":s.maxNits,"belowBlackPercent":s.belowBlackPercent,"aboveWhitePercent":s.aboveWhitePercent,"outOfGamutPercent":s.outOfGamutPercent,"sampleCount":Double(s.sampleCount),"gpuTracePixels":Double(output.gpuTracePixels),"scopeProcessingMS":output.processingMS])
            mailbox.put(.init(packet:packet,images:output.images.mapValues{UIImage(cgImage:$0)},receivedAt:Date(),receivedNS:output.timestampNS,decodedNS:CompanionClock.nowNS(),contentFingerprint:fingerprint,viewImages:output.viewImages.mapValues{UIImage(cgImage:$0)},viewRequests:output.viewRequests,viewKinds:output.viewKinds))
        },onError:{[weak self] error in Task{@MainActor in guard let self,self.connectionID==id else{return};self.status="분석 오류 · \(error.localizedDescription)"}})
        self.analyzer=analyzer;configureAnalysis()
        let presenter=videoPresenter,analyze=scopesEnabled
        decoder.onFrame={[weak self] buffer,sequence,time in
            guard gate.isValid else{return}
            presenter.submit(buffer,sequence:sequence,receivedNS:time)
            if analyze {analyzer.submit(pixelBuffer:buffer,sequence:sequence,timestampNS:time,format:format.get())}
            if gate.claimFirstFrame() {Task{@MainActor in
                guard let self,self.connectionID==id,self.displayed==nil else{return}
                let packet=CompanionPacket(session:scopeSession,generation:sequence,sequence:sequence,source:"Resolve · 네이티브 수신",status:analyze ? "첫 스코프 계산 중":"영상 재생 검증",isTest:false,macHeld:false,dimensions:"\(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer))")
                let frame=ReceivedFrame(packet:packet,images:[:],receivedAt:Date(),receivedNS:time,decodedNS:CompanionClock.nowNS());self.newest=frame;self.displayed=frame
            }}
        }
        let link=CADisplayLink(target:self,selector:#selector(scopeTick));link.add(to:.main,forMode:.common);self.link=link
        UserDefaults.standard.set(host,forKey:"host");session.connect(host:host)
    }
    func setScopeRaster(id:UUID,panel:CompanionPanel,request:FullRasterScopeRequest?) {
        guard let kind=FullRasterScopeKind(rawValue:panel.rawValue),let request else {
            if rasterViews.removeValue(forKey:id) != nil {configureAnalysis()};return
        }
        let value=FullRasterScopeRegistration(kind:kind,request:request)
        guard rasterViews[id] != value else {return}
        rasterViews[id]=value;configureAnalysis()
    }
    private func configureAnalysis() {
        var config=LocalScopeConfiguration();config.settings.colorSpace=remotePrimaries;config.settings.transfer=remoteTransfer;config.settings.sampleWidth=remoteSampleWidth;config.waveform.mode=remoteWaveformMode;config.waveform.colorize=remoteWaveformMode != .luma;config.rasterViews=rasterViews;config.presentation = .init(mode:falseColorMode,target:falseColorCenter,span:falseColorSpan);analyzer?.configure(config)
    }
    @objc private func scopeTick() {
        let now=CompanionClock.nowNS()
        if let (frame,time)=submitted {
            samples.append(.init(sequence:frame.packet.sequence,receivedNS:frame.receivedNS,decodedNS:frame.decodedNS,submittedNS:time,presentedNS:now,contentFingerprint:frame.contentFingerprint,gpuTracePixels:Int(frame.packet.metrics["gpuTracePixels"] ?? 0),processingMS:frame.packet.metrics["scopeProcessingMS"] ?? 0));submitted=nil
            if samples.count>5400 {samples.removeFirst(samples.count-5400)}
        }
        if let frame=mailbox.take() {newest=frame;if !held {displayed=frame;submitted=(frame,now)}}
        if now-lastReport>1_000_000_000 {lastReport=now;report(now)}
    }
    private func report(_ now:UInt64) {
        let video=videoPresenter.report(),recent=samples.filter{now >= $0.presentedNS && now-$0.presentedNS<2_000_000_000}
        let scopeFPS=Double(recent.count)/2
        performanceText=(videoPresenter.isVisible ? String(format:"영상 %.1f",video.fps):"영상 숨김")+String(format:" · 스코프 %.1f fps",scopeFPS)+(videoPresenter.isVisible ? (video.medianLocalMS.map{String(format:" · 앱 처리 %.0f ms",$0)} ?? ""):"")
        guard !writing,let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
        struct Report:Codable,Sendable {
            let version:String,source:String,definition:String
            let capturedNS:UInt64
            let analysisEnabled:Bool,videoVisible:Bool
            let videoFPS:Double,scopeFPS:Double
            let videoSamples:[RemoteVideoSample],scopeSamples:[DisplaySample]
            let decoderEvents:[NativeDecodeEvent]
        }
        let value=Report(version:"1.22-gpu",source:remoteFormatDescription,definition:"Authenticated AU completion to immediate video layer submission; network/sender/optical latency excluded",capturedNS:now,analysisEnabled:scopesEnabled,videoVisible:videoPresenter.isVisible,videoFPS:video.fps,scopeFPS:scopeFPS,videoSamples:video.records,scopeSamples:samples,decoderEvents:decoderEvents)
        let diagnostics:[String:Any]=["version":"1.22-gpu","events":events,"status":status,"format":remoteFormatDescription,"media":mediaStats,"control":controlStats]
        let diagnosticData=try? JSONSerialization.data(withJSONObject:diagnostics)
        writing=true
        telemetryQueue.async{[weak self] in
            if let data=try? JSONEncoder().encode(value) {try? data.write(to:folder.appendingPathComponent("NativeMonitorTelemetry.json"),options:.atomic)}
            if let diagnosticData {try? diagnosticData.write(to:folder.appendingPathComponent("NativeMonitorDiagnostics.json"),options:.atomic)}
            DispatchQueue.main.async{self?.writing=false}
        }
    }
    private func record(_ text:String) {if events.last != text {events.append(text);if events.count>40 {events.removeFirst(events.count-40)}}}
    func disconnect() {
        UIApplication.shared.isIdleTimerDisabled=false
        connectionID=UUID();gate?.invalidate();gate=nil;link?.invalidate();link=nil
        session?.disconnect();session=nil;media?.reset();media=nil;decoder?.reset();decoder=nil;analyzer?.reset();analyzer=nil
        submitted=nil;mailbox=FrameMailbox();connected=false;connecting=false
        videoPresenter.reset(keepImage:held)
        if !held {displayed=nil;newest=nil};status="연결 해제됨"
    }
    func toggleHold() {held.toggle();videoPresenter.setHeld(held);submitted=nil;if !held {displayed=connected ? newest:nil}}
}
private final class NativeSessionGate:@unchecked Sendable {
    private let lock=NSLock();private var valid=true,firstFrame=false
    var isValid:Bool {lock.lock();defer{lock.unlock()};return valid}
    func invalidate() {lock.lock();valid=false;lock.unlock()}
    func claimFirstFrame()->Bool {lock.lock();defer{lock.unlock()};guard valid,!firstFrame else{return false};firstFrame=true;return true}
}
private final class NativeFormatBox:@unchecked Sendable {
    private let lock=NSLock();private var value=LocalScopeSourceFormat()
    func set(_ value:LocalScopeSourceFormat) {lock.lock();self.value=value;lock.unlock()}
    func get()->LocalScopeSourceFormat {lock.lock();defer{lock.unlock()};return value}
}
