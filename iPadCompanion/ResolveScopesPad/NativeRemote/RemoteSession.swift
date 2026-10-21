import Foundation
import JavaScriptCore
import CryptoKit
import CommonCrypto
import Security
import Darwin

/// Control-only Direct/IP session: signaling, ICE, DTLS, SCTP and SRTCP.
/// Encrypted RTP is delivered directly from recvmsg to native media; JavaScript
/// never authenticates, decrypts, reorders or assembles incoming video packets.
final class RemoteSession: @unchecked Sendable {
    var onStatus:((String)->Void)?
    var onFailure:((String)->Void)?
    var onMetadata:(([String:Any])->Void)?
    var onSRTPKeys:((Data,Data,Int)->Void)?
    var onMediaDatagram:((Data,UInt64)->Void)?
    var onStats:(([String:Any])->Void)?
    let queue=DispatchQueue(label:"studio.resolvescopes.remote.control",qos:.userInitiated)
    private var context:JSContext?
    private var timers:[Int32:DispatchSourceTimer]=[:]
    private var nextTimer:Int32=0
    private var udp:[Int32:DispatchSourceRead]=[:]
    private var sockets=Set<Int32>()
    private var websockets:[Int32:WebSocketState]=[:]
    private var privateKeys:[String:P256.Signing.PrivateKey]=[:]
    private var publicKeys:[String:P256.Signing.PublicKey]=[:]
    private var generation=UUID()
    private struct TimingWindow {
        var values=[Double](),index=0
        mutating func record(_ value:Double) {guard value.isFinite,value>=0 else{return};if values.count<2048 {values.append(value)}else {values[index]=value;index=(index+1)%2048}}
        var summary:[String:Any] {let s=values.sorted();guard !s.isEmpty else{return ["samples":0]};return ["samples":s.count,"medianMS":s[s.count/2],"p95MS":s[Int(Double(s.count-1)*0.95)],"maxMS":s.last!]}
    }
    private var kernelQueueAge=TimingWindow(),packetJSTime=TimingWindow(),drainTime=TimingWindow(),auIntervals=TimingWindow()
    private var timestampedPackets=0,udpTruncatedPackets=0,lastAUTime:Double?,auGapsOver500MS=0
    private var nativeAESBytes=0,nativeHMACCalls=0,mediaPackets=0,mediaBytes=0
    private var mediaEnabled=false
    private let resourceDirectory:URL?
    init(resourceDirectory:URL?=nil) {self.resourceDirectory=resourceDirectory}
    deinit {
        for timer in timers.values {timer.cancel()}
        for source in udp.values {source.cancel()}
        for fd in sockets {Darwin.close(fd)}
        for ws in websockets.values {ws.task.cancel(with:.normalClosure,reason:nil);ws.session.invalidateAndCancel()}
    }
    func connect(host:String) {
        queue.async {[weak self] in
            guard let self else{return};self.stopOnQueue()
            do {
                guard !host.isEmpty,!host.contains(where:{$0.isWhitespace}) else {throw TransportError.invalidHost}
                let ip=try self.localAddress(toward:host)
                try self.prepareContext()
                self.context?.objectForKeyedSubscript("__rmSendCommand")?.call(withArguments:[["type":"connect","host":host,"ip":ip]])
            }catch {self.fail(error.localizedDescription)}
        }
    }
    func disconnect() {queue.async {[weak self] in self?.stopOnQueue()}}
    func requestKeyframe() {queue.async {[weak self] in self?.context?.objectForKeyedSubscript("__rmSendCommand")?.call(withArguments:[["type":"idr"]])}}
    func sendNACK(mediaSSRC:UInt32,sequences:[UInt16]) {
        guard !sequences.isEmpty else{return}
        let bounded=Array(sequences.prefix(256)).map(Int.init)
        queue.async {[weak self] in self?.context?.objectForKeyedSubscript("__rmSendCommand")?.call(withArguments:[["type":"nack","ssrc":mediaSSRC,"sequences":bounded]])}
    }
    private func fail(_ message:String) {onStatus?("Remote Monitor 오류 · "+message);onFailure?(message);stopOnQueue()}
    private func stopOnQueue() {
        generation=UUID()
        // Cancelling native resources also makes all pending callbacks inert.
        for timer in timers.values {timer.cancel()};timers.removeAll()
        for source in udp.values {source.cancel()};udp.removeAll()
        for fd in sockets {Darwin.close(fd)};sockets.removeAll()
        for ws in websockets.values {ws.task.cancel(with:.normalClosure,reason:nil);ws.session.invalidateAndCancel()};websockets.removeAll()
        context?.exceptionHandler=nil;context=nil;privateKeys.removeAll();publicKeys.removeAll()
        kernelQueueAge=TimingWindow();packetJSTime=TimingWindow();drainTime=TimingWindow();auIntervals=TimingWindow()
        timestampedPackets=0;udpTruncatedPackets=0;lastAUTime=nil;auGapsOver500MS=0;nativeAESBytes=0;nativeHMACCalls=0;mediaPackets=0;mediaBytes=0;mediaEnabled=false
    }
    private func resource(_ name:String)throws->String {
        let filename=name+".js"
        let candidates=[resourceDirectory?.appendingPathComponent(filename),
                        Bundle.main.url(forResource:name,withExtension:"js",subdirectory:"NativeRemote"),
                        Bundle.main.url(forResource:name,withExtension:"js")].compactMap{$0}
        guard let url=candidates.first(where:{FileManager.default.fileExists(atPath:$0.path)}) else {throw TransportError.missingResource(filename)}
        return try String(contentsOf:url,encoding:.utf8)
    }
    private func prepareContext()throws {
        guard let ctx=JSContext() else {throw TransportError.context}
        context=ctx
        ctx.exceptionHandler={[weak self] _,exception in
            guard let self else{return}
            let message=exception?.toString() ?? "JavaScript 예외"
            self.onStatus?("Remote Monitor 오류 · "+message);self.onFailure?(message)
        }
        let now:@convention(block) ()->Double = {ProcessInfo.processInfo.systemUptime*1000}
        let log:@convention(block) (String)->Void = {[weak self] text in if text.hasPrefix("ERROR") {self?.onStatus?(text)}}
        let utf8:@convention(block) (String)->JSValue? = {[weak self] text in self?.bytes(Data(text.utf8))}
        let decode:@convention(block) (JSValue,Bool)->String? = {[weak self] value,fatal in
            guard let data=self?.data(value) else{return nil};return fatal ? String(data:data,encoding:.utf8):String(decoding:data,as:UTF8.self)
        }
        let random:@convention(block) (Int32)->JSValue? = {[weak self] n in
            guard n>=0,n<=65_536 else{return nil}
            if n == 0 {return self?.bytes(Data())}
            var data=Data(count:Int(n))
            let result=data.withUnsafeMutableBytes{SecRandomCopyBytes(kSecRandomDefault,$0.count,$0.baseAddress!)}
            guard result == errSecSuccess else{return nil};return self?.bytes(data)
        }
        let url:@convention(block) (String)->[String:String]? = {text in
            guard let c=URLComponents(string:text),let scheme=c.scheme,let host=c.host else{return nil}
            return ["protocol":scheme+":","hostname":host,"port":c.port.map(String.init) ?? "","pathname":c.percentEncodedPath,"username":c.user ?? "","password":c.password ?? "","search":c.percentEncodedQuery.map{"?"+$0} ?? "","hash":c.percentEncodedFragment.map{"#"+$0} ?? ""]
        }
        let b64decode:@convention(block) (String)->String? = {text in guard let d=Data(base64Encoded:text) else{return nil};return String(d.map{Character(UnicodeScalar(Int($0))!)})}
        let b64encode:@convention(block) (String)->String = {text in Data(text.unicodeScalars.map{UInt8(truncatingIfNeeded:$0.value)}).base64EncodedString()}
        let timer:@convention(block) (JSValue,Double,Bool)->Int32 = {[weak self] fn,ms,repeats in self?.makeTimer(fn,milliseconds:ms,repeats:repeats) ?? -1}
        let cancelTimer:@convention(block) (Int32)->Void = {[weak self] id in self?.timers.removeValue(forKey:id)?.cancel()}
        let openUDP:@convention(block) ()->Int32 = {[weak self] in self?.openUDP() ?? -1}
        let bindUDP:@convention(block) (Int32,String,Int32)->[String:Any]? = {[weak self] fd,host,port in self?.bindUDP(fd,host:host,port:port)}
        let udpAddress:@convention(block) (Int32)->[String:Any]? = {[weak self] fd in self?.udpAddress(fd)}
        let sendUDP:@convention(block) (Int32,JSValue,String,Int32)->String = {[weak self] fd,value,host,port in self?.sendUDP(fd,value:value,host:host,port:port) ?? "Transport stopped"}
        let closeUDP:@convention(block) (Int32)->Void = {[weak self] fd in self?.closeUDP(fd)}
        let setUDPBuffer:@convention(block) (Int32,Int32,Bool)->Int32 = {fd,n,receive in
            var size=n;let option=receive ? SO_RCVBUF:SO_SNDBUF
            _=setsockopt(fd,SOL_SOCKET,option,&size,socklen_t(MemoryLayout<Int32>.size));var len=socklen_t(MemoryLayout<Int32>.size)
            _=getsockopt(fd,SOL_SOCKET,option,&size,&len);return size
        }
        let wsOpen:@convention(block) (Int32,String)->Void = {[weak self] id,url in self?.openWebSocket(id,url:url)}
        let wsSend:@convention(block) (Int32,JSValue)->Void = {[weak self] id,value in self?.sendWebSocket(id,value:value)}
        let wsClose:@convention(block) (Int32)->Void = {[weak self] id in self?.websockets[id]?.task.cancel(with:.normalClosure,reason:nil)}
        let post:@convention(block) (JSValue)->Void = {[weak self] message in self?.receive(message)}
        let hash:@convention(block) (String,JSValue)->JSValue? = {[weak self] name,value in
            guard let self,let data=self.data(value) else{return nil}
            let result:Data
            switch name.uppercased() {case "SHA-1":result=Data(Insecure.SHA1.hash(data:data));case "SHA-256":result=Data(SHA256.hash(data:data));case "SHA-384":result=Data(SHA384.hash(data:data));case "SHA-512":result=Data(SHA512.hash(data:data));default:return nil}
            return self.bytes(result)
        }
        let generate:@convention(block) ()->String = {[weak self] in
            let id=UUID().uuidString,key=P256.Signing.PrivateKey();self?.privateKeys[id]=key;self?.publicKeys[id]=key.publicKey;return id
        }
        let export:@convention(block) (String,String,String)->JSValue? = {[weak self] format,id,type in
            guard let self else{return nil}
            if format == "pkcs8",type == "private",let key=self.privateKeys[id] {return self.bytes(key.derRepresentation)}
            if let key=self.publicKeys[id] {
                if format == "spki" {return self.bytes(key.derRepresentation)}
                if format == "raw" {return self.bytes(key.x963Representation)}
            };return nil
        }
        let importKey:@convention(block) (String,JSValue,String)->String? = {[weak self] format,value,type in
            guard let self,let data=self.data(value) else{return nil};let id=UUID().uuidString
            if type == "private",format == "pkcs8",let key=try? P256.Signing.PrivateKey(derRepresentation:data) {self.privateKeys[id]=key;self.publicKeys[id]=key.publicKey;return id}
            let key:P256.Signing.PublicKey?
            if format == "spki" {key=try? P256.Signing.PublicKey(derRepresentation:data)}else if format == "raw" {key=try? P256.Signing.PublicKey(x963Representation:data)}else {key=nil}
            if let key {self.publicKeys[id]=key;return id};return nil
        }
        let sign:@convention(block) (String,JSValue)->JSValue? = {[weak self] id,value in
            guard let self,let key=self.privateKeys[id],let data=self.data(value),let signature=try? key.signature(for:data) else{return nil};return self.bytes(signature.rawRepresentation)
        }
        let verify:@convention(block) (String,JSValue,JSValue)->Bool = {[weak self] id,signature,value in
            guard let self,let key=self.publicKeys[id],let signature=self.data(signature),let data=self.data(value),let s=try? P256.Signing.ECDSASignature(rawRepresentation:signature) else{return false};return key.isValidSignature(s,for:data)
        }
        let aesCTR:@convention(block) (JSValue,JSValue,JSValue,Int32)->JSValue? = {[weak self] key,iv,input,offset in
            guard let self,let key=self.data(key),let iv=self.data(iv),let input=self.data(input),let output=Self.aesCTR(key:key,iv:iv,input:input,offset:Int(offset)) else{return nil}
            self.nativeAESBytes += input.count;return self.bytes(output)
        }
        let hmac:@convention(block) (String,JSValue,JSValue)->JSValue? = {[weak self] name,key,input in
            guard let self,let key=self.data(key),let input=self.data(input) else{return nil};let symmetric=SymmetricKey(data:key),output:Data
            switch name.lowercased().replacingOccurrences(of:"-",with:"") {case "sha1":output=Data(HMAC<Insecure.SHA1>.authenticationCode(for:input,using:symmetric));case "sha256":output=Data(HMAC<SHA256>.authenticationCode(for:input,using:symmetric));case "sha384":output=Data(HMAC<SHA384>.authenticationCode(for:input,using:symmetric));case "sha512":output=Data(HMAC<SHA512>.authenticationCode(for:input,using:symmetric));default:return nil}
            self.nativeHMACCalls += 1;return self.bytes(output)
        }
        let exportSRTP:@convention(block) (JSValue,JSValue,Int32)->Void = {[weak self] key,salt,profile in
            guard let self,let key=self.data(key),let salt=self.data(salt),key.count == 16,salt.count == 14,[1,2].contains(profile) else {self?.fail("Unsupported negotiated native SRTP profile");return}
            self.onSRTPKeys?(key,salt,Int(profile));self.mediaEnabled=true
        }
        for (name,object) in ["__rmExportSRTP":exportSRTP,"__rmNow":now,"__rmLog":log,"__rmUTF8":utf8,"__rmDecodeUTF8":decode,"__rmRandom":random,"__rmURL":url,"__rmBase64Decode":b64decode,"__rmBase64Encode":b64encode,"__rmTimer":timer,"__rmCancelTimer":cancelTimer,"__rmUDPOpen":openUDP,"__rmUDPBind":bindUDP,"__rmUDPAddress":udpAddress,"__rmUDPSend":sendUDP,"__rmUDPClose":closeUDP,"__rmUDPBuffer":setUDPBuffer,"__rmWSOpen":wsOpen,"__rmWSSend":wsSend,"__rmWSClose":wsClose,"__rmPost":post,"__rmHash":hash,"__rmGenerateKey":generate,"__rmExportKey":export,"__rmImportKey":importKey,"__rmSign":sign,"__rmVerify":verify,"__rmAESCTR":aesCTR,"__rmHMAC":hmac] as [String:Any] {
            ctx.setObject(object,forKeyedSubscript:name as NSString)
        }
        ctx.evaluateScript(try resource("SessionBootstrap"),withSourceURL:URL(fileURLWithPath:"SessionBootstrap.js"))
        guard ctx.exception == nil else {throw TransportError.script(ctx.exception.toString())}
        ctx.evaluateScript(try resource("SessionVendor"),withSourceURL:URL(fileURLWithPath:"SessionVendor.js"))
        guard ctx.exception == nil else {throw TransportError.script(ctx.exception.toString())}
    }
    private func makeTimer(_ callback:JSValue,milliseconds:Double,repeats:Bool)->Int32 {
        guard timers.count<2048 else {onFailure?("수신 타이머 한도를 초과했습니다");return -1}
        nextTimer &+= 1;let id=nextTimer,token=generation,timer=DispatchSource.makeTimerSource(queue:queue)
        let delay=max(0,min(86_400_000,milliseconds))/1000
        timer.schedule(deadline:.now()+delay,repeating:repeats ? max(0.001,delay):.infinity,leeway:.milliseconds(0))
        timer.setEventHandler {[weak self] in
            guard let self,self.generation == token else{return}
            if !repeats {self.timers.removeValue(forKey:id)?.cancel()}
            callback.call(withArguments:[])
        };timers[id]=timer;timer.resume();return id
    }
    private func bytes(_ data:Data)->JSValue? {
        guard let context,let pointer=malloc(max(1,data.count)) else{return nil}
        data.copyBytes(to:pointer.assumingMemoryBound(to:UInt8.self),count:data.count)
        guard let object=JSObjectMakeTypedArrayWithBytesNoCopy(context.jsGlobalContextRef,kJSTypedArrayTypeUint8Array,pointer,data.count,{p,_ in free(p)},nil,nil) else {free(pointer);return nil}
        return JSValue(jsValueRef:object,in:context)
    }
    private func data(_ value:JSValue)->Data? {
        guard let context,!value.isNull,!value.isUndefined,let object=JSValueToObject(context.jsGlobalContextRef,value.jsValueRef,nil) else{return nil}
        let type=JSValueGetTypedArrayType(context.jsGlobalContextRef,object,nil)
        if type == kJSTypedArrayTypeArrayBuffer {
            let count=JSObjectGetArrayBufferByteLength(context.jsGlobalContextRef,object,nil)
            if count == 0 {return Data()}
            guard count<=16_777_216,let pointer=JSObjectGetArrayBufferBytesPtr(context.jsGlobalContextRef,object,nil) else{return nil};return Data(bytes:pointer,count:count)
        }
        guard type != kJSTypedArrayTypeNone else{return nil}
        let count=JSObjectGetTypedArrayByteLength(context.jsGlobalContextRef,object,nil)
        if count == 0 {return Data()}
        guard count<=16_777_216,let pointer=JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef,object,nil) else{return nil}
        let offset=JSObjectGetTypedArrayByteOffset(context.jsGlobalContextRef,object,nil)
        return Data(bytes:pointer.advanced(by:offset),count:count)
    }
    private func receive(_ message:JSValue) {
        let type=message.forProperty("type")?.toString() ?? ""
        switch type {
        case "metadata":onMetadata?(message.toDictionary() as? [String:Any] ?? [:])
        case "stats":
            var result=message.toDictionary() as? [String:Any] ?? [:]
            result["native"]=["mediaPackets":mediaPackets,"mediaBytes":mediaBytes,"kernelReceiveQueueAge":kernelQueueAge.summary,"controlPacketJS":packetJSTime.summary,"udpDrain":drainTime.summary,"truncatedUDPPackets":udpTruncatedPackets]
            result["architecture"]="native SRTP/RTP/HEVC; JavaScript control-only signaling/ICE/DTLS/SCTP/SRTCP"
            onStats?(result)
        case "status":onStatus?(message.forProperty("text")?.toString() ?? "")
        case "error":let text=message.forProperty("message")?.toString() ?? "수신 실패";onStatus?("Remote Monitor 오류 · "+text);onFailure?(text)
        case "state","ice-state":onStatus?("Remote Monitor · "+(message.forProperty("connection")?.toString() ?? message.forProperty("ice")?.toString() ?? "연결 중"))
        case "host-log":if message.forProperty("level")?.toInt32() ?? 0 > 1 {onStatus?(message.forProperty("text")?.toString() ?? "")}
        default:break
        }
    }
    private func openUDP()->Int32 {
        let fd=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP)
        guard fd>=0 else{return -1};_ = fcntl(fd,F_SETFL,O_NONBLOCK);sockets.insert(fd)
        var size:Int32=8*1024*1024;_ = setsockopt(fd,SOL_SOCKET,SO_RCVBUF,&size,socklen_t(MemoryLayout<Int32>.size))
        var enabled:Int32=1;_ = setsockopt(fd,SOL_SOCKET,SO_TIMESTAMP,&enabled,socklen_t(MemoryLayout<Int32>.size));return fd
    }
    private func bindUDP(_ fd:Int32,host:String,port:Int32)->[String:Any]? {
        guard sockets.contains(fd),port>=0,port<=65535 else{return nil}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(port).bigEndian
        guard inet_pton(AF_INET,host,&address.sin_addr) == 1 else{return nil}
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        guard result == 0 else{return nil}
        let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:queue),token=generation
        source.setEventHandler {[weak self] in guard let self,self.generation == token else{return};self.drainUDP(fd)}
        udp[fd]=source;source.resume();return udpAddress(fd)
    }
    private func udpAddress(_ fd:Int32)->[String:Any]? {
        var address=sockaddr_in(),length=socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&length)}}) == 0 else{return nil}
        return ["address":Self.ipv4(address.sin_addr),"port":Int(UInt16(bigEndian:address.sin_port)),"family":"IPv4"]
    }
    private func sendUDP(_ fd:Int32,value:JSValue,host:String,port:Int32)->String {
        guard sockets.contains(fd),port>0,port<=65535,let data=data(value),data.count<=65_507 else{return "Invalid UDP packet"}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(port).bigEndian
        guard inet_pton(AF_INET,host,&address.sin_addr) == 1 else{return "Invalid IPv4 destination"}
        let n=data.withUnsafeBytes {bytes in withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){sendto(fd,bytes.baseAddress,bytes.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}}
        return n == data.count ? "":String(cString:strerror(errno))
    }
    private func drainUDP(_ fd:Int32) {
        var buffer=[UInt8](repeating:0,count:65_536),control=[UInt8](repeating:0,count:128)
        let started=ProcessInfo.processInfo.systemUptime*1000
        defer {drainTime.record(ProcessInfo.processInfo.systemUptime*1000-started)}
        for _ in 0..<32 {
            guard sockets.contains(fd) else {break}
            if ProcessInfo.processInfo.systemUptime*1000-started>=2 {break}
            var address=sockaddr_in(),controlCount=0,flags:Int32=0
            let n=buffer.withUnsafeMutableBytes {payload in control.withUnsafeMutableBytes {ancillary in
                var iov=iovec(iov_base:payload.baseAddress,iov_len:payload.count)
                return withUnsafeMutablePointer(to:&address) {name in withUnsafeMutablePointer(to:&iov) {iov in
                    var message=msghdr(msg_name:UnsafeMutableRawPointer(name),msg_namelen:socklen_t(MemoryLayout<sockaddr_in>.size),msg_iov:iov,msg_iovlen:1,msg_control:ancillary.baseAddress,msg_controllen:socklen_t(ancillary.count),msg_flags:0)
                    let count=recvmsg(fd,&message,0);controlCount=Int(message.msg_controllen);flags=message.msg_flags;return count
                }}
            }}
            if n<0 {if errno != EAGAIN && errno != EWOULDBLOCK {onStatus?("UDP 수신 오류 · "+String(cString:strerror(errno)))};break}
            if flags & MSG_TRUNC != 0 {udpTruncatedPackets += 1;continue}
            let receivedMS=ProcessInfo.processInfo.systemUptime*1000
            let age=Self.kernelAgeMS(control:control,count:controlCount)
            if let age {timestampedPackets += 1;kernelQueueAge.record(age)}
            let packet=Data(buffer.prefix(n))
            // RFC 5764 / RFC 7983 demux. SRTCP (PT 192...223) stays on the
            // authenticated JS control path; RTP is never copied into JSCore.
            if n>=2,(buffer[0] & 0xc0) == 0x80,!(192...223).contains(Int(buffer[1])) {
                guard mediaEnabled else {continue}
                mediaPackets += 1;mediaBytes += n
                onMediaDatagram?(packet,DispatchTime.now().uptimeNanoseconds)
                continue
            }
            guard let value=bytes(packet) else{break}
            let beforeJS=ProcessInfo.processInfo.systemUptime*1000
            context?.objectForKeyedSubscript("__rmUDPDeliver")?.call(withArguments:[fd,value,Self.ipv4(address.sin_addr),Int(UInt16(bigEndian:address.sin_port)),receivedMS,age ?? -1])
            packetJSTime.record(ProcessInfo.processInfo.systemUptime*1000-beforeJS)
        }
    }
    private static func kernelAgeMS(control:[UInt8],count:Int)->Double? {
        control.withUnsafeBytes {bytes in
            let limit=min(count,bytes.count),headerSize=(MemoryLayout<cmsghdr>.size+3) & ~3
            var offset=0
            while offset+MemoryLayout<cmsghdr>.size<=limit {
                let header=bytes.loadUnaligned(fromByteOffset:offset,as:cmsghdr.self),length=Int(header.cmsg_len)
                guard length>=headerSize,offset+length<=limit else{return nil}
                if header.cmsg_level == SOL_SOCKET,header.cmsg_type == SCM_TIMESTAMP,length>=headerSize+MemoryLayout<timeval>.size {
                    let time=bytes.loadUnaligned(fromByteOffset:offset+headerSize,as:timeval.self)
                    let age=(Date().timeIntervalSince1970-Double(time.tv_sec)-Double(time.tv_usec)/1_000_000)*1000
                    return age.isFinite && age >= -2 && age<60_000 ? max(0,age):nil
                }
                offset += (length+3) & ~3
            };return nil
        }
    }
    private static func aesCTR(key:Data,iv:Data,input:Data,offset:Int)->Data? {
        guard key.count == 16,iv.count == 16,offset>=0,offset<=16_777_216,input.count<=16_777_216 else{return nil}
        var counter=Array(iv),carry=offset/16
        for i in stride(from:15,through:0,by:-1) {let sum=Int(counter[i])+(carry&255);counter[i]=UInt8(truncatingIfNeeded:sum);carry=(carry>>8)+(sum>>8)}
        let skip=offset%16,padded=Data(repeating:0,count:skip)+input
        var cryptor:CCCryptorRef?
        let status=key.withUnsafeBytes {key in counter.withUnsafeBytes {iv in CCCryptorCreateWithMode(CCOperation(kCCEncrypt),CCMode(kCCModeCTR),CCAlgorithm(kCCAlgorithmAES),CCPadding(ccNoPadding),iv.baseAddress,key.baseAddress,key.count,nil,0,0,CCModeOptions(kCCModeOptionCTR_BE),&cryptor)}}
        guard status == kCCSuccess,let cryptor else{return nil};defer {CCCryptorRelease(cryptor)}
        if padded.isEmpty {return Data()}
        var output=Data(count:padded.count+16),written=0
        let result=padded.withUnsafeBytes {input in output.withUnsafeMutableBytes {output in CCCryptorUpdate(cryptor,input.baseAddress,input.count,output.baseAddress,output.count,&written)}}
        guard result == kCCSuccess,written>=skip+input.count else{return nil};return output.subdata(in:skip..<(skip+input.count))
    }
    private func closeUDP(_ fd:Int32) {udp.removeValue(forKey:fd)?.cancel();if sockets.remove(fd) != nil {Darwin.close(fd)}}
    private static func ipv4(_ value:in_addr)->String {var a=value,buffer=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN));inet_ntop(AF_INET,&a,&buffer,socklen_t(buffer.count));return String(cString:buffer)}
    private func localAddress(toward host:String)throws->String {
        // Resolve an IPv4 destination and ask the routing table which local
        // interface it would use. UDP connect emits no payload.
        let host=host.replacingOccurrences(of:"^wss?://",with:"",options:.regularExpression).split(separator:"/").first.map(String.init) ?? host
        let name=host.split(separator:":").first.map(String.init) ?? host
        var hints=addrinfo();hints.ai_family=AF_INET;hints.ai_socktype=SOCK_DGRAM
        var result:UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name,"16410",&hints,&result) == 0,let result else {throw TransportError.invalidHost}
        defer {freeaddrinfo(result)}
        let fd=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);guard fd>=0 else {throw TransportError.network};defer {Darwin.close(fd)}
        guard Darwin.connect(fd,result.pointee.ai_addr,result.pointee.ai_addrlen) == 0 else {throw TransportError.network}
        var address=sockaddr_in(),length=socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&length)}}) == 0 else {throw TransportError.network}
        return Self.ipv4(address.sin_addr)
    }
    private final class WebSocketState {
        let session:URLSession,task:URLSessionWebSocketTask
        init(_ session:URLSession,_ task:URLSessionWebSocketTask){self.session=session;self.task=task}
    }
    private final class WebSocketDelegate:NSObject,URLSessionWebSocketDelegate,@unchecked Sendable {
        weak var owner:RemoteSession?;let id:Int32,token:UUID
        init(owner:RemoteSession,id:Int32,token:UUID){self.owner=owner;self.id=id;self.token=token}
        func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didOpenWithProtocol protocol:String?) {owner?.webSocketEvent(id,token:token,type:"open")}
        func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didCloseWith closeCode:URLSessionWebSocketTask.CloseCode,reason:Data?) {owner?.webSocketEvent(id,token:token,type:"close")}
    }
    private func openWebSocket(_ id:Int32,url:String) {
        guard let url=URL(string:url),["ws","wss"].contains(url.scheme?.lowercased() ?? "") else{return}
        let delegate=WebSocketDelegate(owner:self,id:id,token:generation)
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30
        let session=URLSession(configuration:config,delegate:delegate,delegateQueue:nil),task=session.webSocketTask(with:url)
        task.maximumMessageSize=1_048_576
        websockets[id]=WebSocketState(session,task);task.resume();receiveWebSocket(id,task:task,token:generation)
    }
    private func receiveWebSocket(_ id:Int32,task:URLSessionWebSocketTask,token:UUID) {
        Task {[weak self] in
            do {
                let message=try await task.receive();let data:Data
                switch message {case .data(let d):data=d;case .string(let s):data=Data(s.utf8);@unknown default:return}
                self?.queue.async {[weak self] in
                    guard let self,self.generation == token,self.websockets[id]?.task === task,let value=self.bytes(data) else{return}
                    self.context?.objectForKeyedSubscript("__rmWSEvent")?.call(withArguments:[id,"data",value]);self.receiveWebSocket(id,task:task,token:token)
                }
            }catch {self?.webSocketEvent(id,token:token,type:"error",message:error.localizedDescription)}
        }
    }
    private func sendWebSocket(_ id:Int32,value:JSValue) {
        guard let task=websockets[id]?.task,let data=data(value),data.count<=1_048_576 else{return};let token=generation
        Task {[weak self] in do {try await task.send(.data(data))}catch {self?.webSocketEvent(id,token:token,type:"error",message:error.localizedDescription)}}
    }
    private func webSocketEvent(_ id:Int32,token:UUID,type:String,message:String="") {
        queue.async {[weak self] in guard let self,self.generation == token,self.websockets[id] != nil else{return};self.context?.objectForKeyedSubscript("__rmWSEvent")?.call(withArguments:[id,type,message])}
    }
    private enum TransportError:LocalizedError {
        case invalidHost,network,context,missingResource(String),script(String?)
        var errorDescription:String? {switch self {case .invalidHost:return "유효한 Resolve IPv4 주소를 입력하세요";case .network:return "Resolve로 연결할 로컬 IPv4 경로가 없습니다";case .context:return "JavaScriptCore를 시작할 수 없습니다";case .missingResource(let name):return "수신 자산 누락: "+name;case .script(let text):return text ?? "수신 스크립트 오류"}}
    }
}
