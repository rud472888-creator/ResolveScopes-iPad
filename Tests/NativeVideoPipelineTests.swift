import Foundation
import CoreVideo
import Darwin
enum CompanionClock {static func nowNS()->UInt64 {var t=timespec();clock_gettime(CLOCK_MONOTONIC,&t);return UInt64(t.tv_sec)*1_000_000_000+UInt64(t.tv_nsec)}}
precondition(NativePlaybackStatus.text(connected:true,age:nil,normal:"OK")=="첫 영상 표시 중")
precondition(NativePlaybackStatus.text(connected:true,age:.infinity,normal:"OK")=="첫 영상 표시 중")
precondition(NativePlaybackStatus.text(connected:true,age:.nan,normal:"OK")=="첫 영상 표시 중")
precondition(NativePlaybackStatus.text(connected:true,age:.greatestFiniteMagnitude,normal:"OK")=="새 프레임 대기 99999초")
precondition(NativePlaybackStatus.text(connected:true,age:3,normal:"OK")=="새 프레임 대기 3초")
precondition(NativePlaybackStatus.text(connected:true,age:0,normal:"OK")=="OK")
print("PASS startup status handles nil, infinity, NaN and bounded integer conversion")
let decoder=NativeVideoDecoder();decoder.configure(chroma:2,depth:10,fullRange:false)
let lock=NSLock();var count=0;var types=[UInt32]()
decoder.onStatus={print($0)}
decoder.onFrame={buffer,_,_ in lock.lock();count += 1;types.append(CVPixelBufferGetPixelFormatType(buffer));lock.unlock()}
let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
let nals=NativeVideoDecoder.nalUnits(data);var frames=[Data]();var frame=Data()
for nal in nals {let type=(nal[nal.startIndex]>>1)&63;if type==35,!frame.isEmpty {frames.append(frame);frame=Data()};frame.append(contentsOf:[0,0,0,1]);frame.append(nal)}
if !frame.isEmpty {frames.append(frame)}
for (i,frame) in frames.enumerated() {DispatchQueue.global().asyncAfter(deadline:.now()+Double(i)*0.0){decoder.decode(frame,timestamp:UInt32(i*3750),receivedNS:CompanionClock.nowNS())}}
RunLoop.current.run(until:Date().addingTimeInterval(3))
lock.lock();let result=["inputFrames":frames.count,"decodedFrames":count,"pixelFormats":types.map{String(format:"%08x",$0)}] as [String:Any];lock.unlock()
print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
exit(count==frames.count ? 0:1)
