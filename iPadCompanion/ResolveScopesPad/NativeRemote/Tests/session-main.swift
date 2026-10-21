let gate=DispatchSemaphore(value:0)
var passed=false
extension RemoteSession {
    func selfTest() {
        queue.async {
            do {
                self.onSRTPKeys={key,salt,profile in
                    guard key.count == 16,salt.count == 14,profile == 1 else {fatalError("Key callback")}
                }
                self.onMediaDatagram={data,ns in
                    guard ns>0,let bytes=self.bytes(data) else {fatalError("Native RTP timestamp")}
                    self.context?.objectForKeyedSubscript("__rmTestRaw")?.call(withArguments:[bytes])
                }
                try self.prepareContext()
                let done:@convention(block) (Bool,String)->Void={ok,description in passed=ok;print("CONTROL_SESSION_SELFTEST",ok,description);gate.signal()}
                self.context!.setObject(done,forKeyedSubscript:"__sessionTestDone" as NSString)
                self.context!.evaluateScript("(async()=>{try{__sessionTestDone(true,await __sessionSelfTest());}catch(e){__sessionTestDone(false,String(e)+' '+e.stack);}})()")
            }catch{print(error);gate.signal()}
        }
    }
}
let session=RemoteSession(resourceDirectory:URL(fileURLWithPath:CommandLine.arguments[1]))
session.onFailure={print("FAILURE",$0);gate.signal()}
session.selfTest()
if gate.wait(timeout:.now()+20) == .timedOut {print("SELFTEST TIMEOUT")}
session.disconnect()
exit(passed ? 0:1)
