#!/bin/bash
set -euo pipefail
TASK_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TASK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resolvescopes-local-scope.XXXXXX")"
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
cat > "$TASK_TEST_DIR/LocalScopeAnalyzerTests.swift" <<'SWIFT'
import Foundation
import CoreVideo

@main struct LocalScopeCheck {
 static func buffer(_ type:OSType,width:Int=4,height:Int=2)throws->CVPixelBuffer {
  var value:CVPixelBuffer?
  let attrs=[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary
  let code=CVPixelBufferCreate(kCFAllocatorDefault,width,height,type,attrs,&value)
  guard code == kCVReturnSuccess,let value else {throw NSError(domain:"pixel",code:Int(code))}
  return value
 }
 static func fill(_ b:CVPixelBuffer,values:[Int],bits:Int) {
  CVPixelBufferLockBaseAddress(b,[]);defer {CVPixelBufferUnlockBaseAddress(b,[])}
  let w=CVPixelBufferGetWidth(b),h=CVPixelBufferGetHeight(b)
  for y in 0..<h {
   let row=CVPixelBufferGetBaseAddressOfPlane(b,0)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(b,0))
   for x in 0..<w {
    if bits==10 {row.storeBytes(of:UInt16(values[x])<<6,toByteOffset:x*2,as:UInt16.self)}
    else {row.storeBytes(of:UInt8(values[x]),toByteOffset:x,as:UInt8.self)}
   }
  }
  let cw=CVPixelBufferGetWidthOfPlane(b,1),ch=CVPixelBufferGetHeightOfPlane(b,1)
  for y in 0..<ch {
   let row=CVPixelBufferGetBaseAddressOfPlane(b,1)!.advanced(by:y*CVPixelBufferGetBytesPerRowOfPlane(b,1))
   for x in 0..<cw*2 {
    if bits==10 {row.storeBytes(of:UInt16(512)<<6,toByteOffset:x*2,as:UInt16.self)}
    else {row.storeBytes(of:UInt8(128),toByteOffset:x,as:UInt8.self)}
   }
  }
 }
 static func close(_ a:Float,_ b:Double,_ note:String) {precondition(abs(Double(a)-b)<1e-6,"\(note): \(a) != \(b)")}
 static func main()throws {
  let format=LocalScopeSourceFormat(matrix:.bt709,primaries:.rec709,transfer:.gamma24)
  FileHandle.standardError.write(Data("CHECK y8\n".utf8));let y8=try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);fill(y8,values:[0,16,235,255],bits:8)
  let a=try LocalScopeAnalyzer.analyze(pixelBuffer:y8,sequence:1,timestampNS:123,format:format)
  close(a.frame.rgba[4],0,"8-bit legal black");close(a.frame.rgba[8],1,"8-bit legal white")
  close(a.frame.rgba[0],-16.0/219,"8-bit superblack");close(a.frame.rgba[12],239.0/219,"8-bit superwhite")
  precondition(a.statistics.belowBlackPercent==25 && a.statistics.aboveWhitePercent==25)
  precondition(a.images.count==5 && a.statistics.sampleCount==8 && a.settings.levels == .full)
  FileHandle.standardError.write(Data("CHECK y10\n".utf8));let y10=try buffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange);fill(y10,values:[0,64,940,1023],bits:10)
  let b=try LocalScopeAnalyzer.sampledFrame(pixelBuffer:y10,sequence:2,timestampNS:456,format:format)
  close(b.frame.rgba[4],0,"10-bit legal black");close(b.frame.rgba[8],1,"10-bit legal white")
  close(b.frame.rgba[0],-64.0/876,"10-bit superblack");close(b.frame.rgba[12],959.0/876,"10-bit superwhite")
  FileHandle.standardError.write(Data("CHECK full\n".utf8));let yf=try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);fill(yf,values:[0,16,235,255],bits:8)
  let f=try LocalScopeAnalyzer.sampledFrame(pixelBuffer:yf,sequence:3,timestampNS:789,format:format)
  close(f.frame.rgba[0],0,"full black");close(f.frame.rgba[12],1,"full white");close(f.frame.rgba[4],16.0/255,"full gray")
  FileHandle.standardError.write(Data("CHECK metadata\n".utf8));CVBufferSetAttachment(y10,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
  CVBufferSetAttachment(y10,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,.shouldPropagate)
  CVBufferSetAttachment(y10,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
  let hdr=try LocalScopeAnalyzer.sampledFrame(pixelBuffer:y10,sequence:4,timestampNS:0)
  precondition(hdr.settings.colorSpace == .rec2020 && hdr.settings.transfer == .pq)
  let unknown=try buffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange);fill(unknown,values:[0,64,940,1023],bits:10)
  CVBufferSetAttachment(unknown,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_SMPTE_240M_1995,.shouldPropagate)
  do {_ = try LocalScopeAnalyzer.sampledFrame(pixelBuffer:unknown,sequence:5,timestampNS:0);preconditionFailure("unsupported SMPTE240M matrix accepted")}
  catch LocalScopeAnalysisError.unsupportedMatrix {} 
  _ = try LocalScopeAnalyzer.sampledFrame(pixelBuffer:y10,sequence:6,timestampNS:0,format:format)
  let encodedFull=LocalScopeSourceFormat(fullRange:true,matrix:.bt709,primaries:.rec709,transfer:.gamma24)
  let convertedLegal=try LocalScopeAnalyzer.sampledFrame(pixelBuffer:y10,sequence:7,timestampNS:0,format:encodedFull)
  close(convertedLegal.frame.rgba[4],0,"decoder output range wins over source metadata")
  precondition(convertedLegal.warnings.contains{$0.contains("디코드 버퍼")})
  FileHandle.standardError.write(Data("CHECK bgra\n".utf8));let bgra=try buffer(kCVPixelFormatType_32BGRA,width:2,height:1)
  CVPixelBufferLockBaseAddress(bgra,[])
  let p=CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to:UInt8.self)
  for i in 0..<8 {p[i]=0};p[2]=255;p[3]=255;p[7]=255
  CVPixelBufferUnlockBaseAddress(bgra,[])
  let rgb=try LocalScopeAnalyzer.sampledFrame(pixelBuffer:bgra,sequence:7,timestampNS:0,format:format)
  close(rgb.frame.rgba[0],1,"BGRA red");close(rgb.frame.rgba[1],0,"BGRA green")
  precondition(rgb.warnings.contains{$0.contains("8-bit")})
  FileHandle.standardError.write(Data("CHECK GPU conversion and full-pixel trace\n".utf8))
  let gpu=try LocalScopeGPURenderer()
  for item in [y8,y10,yf,bgra] {
   let sample=try LocalScopeAnalyzer.sampledFrame(pixelBuffer:item,sequence:0,timestampNS:0,format:format)
   let fullRGB=try gpu.convertedRGB(pixelBuffer:item,layout:sample.layout)
   precondition(fullRGB.count==sample.frame.rgba.count)
   for i in fullRGB.indices {precondition(abs(fullRGB[i]-sample.frame.rgba[i])<0.000002,"GPU decoded RGB mismatch at \(i): \(fullRGB[i]) vs \(sample.frame.rgba[i])")}
  }
  let spike=try buffer(kCVPixelFormatType_32BGRA,width:1280,height:720)
  CVPixelBufferLockBaseAddress(spike,[])
  memset(CVPixelBufferGetBaseAddress(spike)!,0,CVPixelBufferGetBytesPerRow(spike)*720)
  for i in 0..<4 {CVPixelBufferGetBaseAddress(spike)!.storeBytes(of:UInt8(255),toByteOffset:i,as:UInt8.self)}
  CVPixelBufferUnlockBaseAddress(spike,[])
  var sampleOptions=ScopeSettings();sampleOptions.sampleWidth=480
  let sparse=try LocalScopeAnalyzer.sampledFrame(pixelBuffer:spike,sequence:0,timestampNS:0,format:format,settings:sampleOptions)
  precondition(stride(from:0,to:sparse.frame.rgba.count,by:4).allSatisfy{sparse.frame.rgba[$0]==0})
  let full=try gpu.render(pixelBuffer:spike,layout:sparse.layout,settings:sparse.settings,waveform:.init(),vector:.init(),requests:[.waveform:.init(width:512,height:512)])
  precondition(full.receivedPixels==1280*720 && full.wave!.rgba[0]>0,"full-resolution highlight was lost")
  FileHandle.standardError.write(Data("CHECK mailbox\n".utf8));let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
  let lock=NSLock();var sequences=[UInt64]()
  let analyzer=LocalScopeAnalyzer(onResult:{result in
   lock.lock();sequences.append(result.sequence);lock.unlock()
   if result.sequence==10 {entered.signal();_ = release.wait(timeout:.now()+3)}
   if result.sequence==100 {finished.signal()}
  })
  analyzer.submit(pixelBuffer:y8,sequence:10,timestampNS:0,format:format)
  precondition(entered.wait(timeout:.now()+3) == .success)
  for n in 11...100 {analyzer.submit(pixelBuffer:y8,sequence:UInt64(n),timestampNS:0,format:format)}
  release.signal();precondition(finished.wait(timeout:.now()+3) == .success)
  lock.lock();let values=sequences;lock.unlock();precondition(values==[10,100],"mailbox \(values)")
  var viewConfig=LocalScopeConfiguration(),camera=WaveformViewport();camera.zoomY=2
  let viewID=UUID();viewConfig.rasterViews[viewID] = .init(kind:.waveform,request:.init(width:512,height:512,viewport:camera))
  let viewResult=try LocalScopeAnalyzer.analyze(pixelBuffer:y8,sequence:1,timestampNS:0,format:format,configuration:viewConfig)
  precondition(viewResult.viewImages[viewID]?.width==512 && viewResult.viewImages[viewID]?.height==512 && viewResult.gpuTracePixels==8)
  precondition(viewResult.viewKinds[viewID] == .waveform)
  precondition(viewResult.images[.falseColor] == nil,"inactive GPU False Color leaked a black CPU placeholder")
  for kind in [FullRasterScopeKind.parade,.vectorscope,.waveform,.vectorscope] {
   viewConfig.rasterViews[viewID] = .init(kind:kind,request:.init(width:512,height:512))
   let changed=try LocalScopeAnalyzer.analyze(pixelBuffer:y8,sequence:2,timestampNS:0,format:format,configuration:viewConfig)
   precondition(changed.viewKinds[viewID]?.rawValue == kind.rawValue,"stale raster kind after scope replacement")
   precondition(changed.viewImages[viewID] != nil && changed.images[.falseColor] == nil)
  }
  viewConfig.rasterViews[viewID] = .init(kind:.falseColor,request:.init())
  let fc=try LocalScopeAnalyzer.analyze(pixelBuffer:y8,sequence:3,timestampNS:0,format:format,configuration:viewConfig)
  precondition(fc.images[.falseColor]?.width==4 && fc.images[.falseColor]?.height==2,"False Color not regenerated at native input size")
  precondition(fc.images[.parade] == nil && fc.viewImages[viewID] == nil,"previous scope image survived replacement")
  FileHandle.standardError.write(Data("PASS scope switch: same-ID parade/vector/waveform/vector/False Color, typed images, no skipped black placeholders\n".utf8))
  analyzer.configure(viewConfig)
  precondition(finished.wait(timeout:.now()+3) == .success,"paused stream did not reraster last input on camera change")
  lock.lock();let rerendered=sequences;lock.unlock();precondition(rerendered==[10,100,100])
  print("PASS: 8-bit420/video+full, 10-bit422/video, superblack/superwhite, no double normalization, BT2020/PQ attachments, unsupported matrix rejection and explicit override, BGRA precision warning, GPU YUV8/YUV10/BGRA numerical equivalence, full-raster one-pixel highlight preservation, five local panels/statistics, latest-only mailbox [10,100], per-view GPU raster and paused-stream camera reraster [100].")
 }
}
SWIFT
TASK_SOURCES=("$TASK_PROJECT_ROOT"/Sources/ScopeCore/*.swift
  "$TASK_PROJECT_ROOT/Sources/CompanionKit/CompanionPacket.swift"
  "$TASK_PROJECT_ROOT/Sources/ResolveScopes/Support/CompanionPlotOverlay.swift"
  "$TASK_PROJECT_ROOT/Sources/ResolveScopes/Support/FullRasterScopeRenderer.swift"
  "$TASK_PROJECT_ROOT/iPadCompanion/ResolveScopesPad/LocalScopeGPURenderer.swift"
  "$TASK_PROJECT_ROOT/iPadCompanion/ResolveScopesPad/LocalScopeAnalyzer.swift"
  "$TASK_TEST_DIR/LocalScopeAnalyzerTests.swift")
if [ "${1:-}" = "--typecheck-ios" ]; then
  TASK_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
  xcrun swiftc -target arm64-apple-ios16.0 -sdk "$TASK_SDK_PATH" -parse-as-library -typecheck "${TASK_SOURCES[@]}"
  echo 'PASS: iOS16 arm64 typecheck, local analyzer + ScopeCore + numeric harness.'
else
  xcrun swiftc -O "${TASK_SOURCES[@]}" -o "$TASK_TEST_DIR/LocalScopeAnalyzerTests"
  "$TASK_TEST_DIR/LocalScopeAnalyzerTests"
fi
