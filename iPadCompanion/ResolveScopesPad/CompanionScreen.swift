import SwiftUI

// Match the Mac monitor: neutral surfaces, quiet controls, small mono telemetry.
private enum MonitorChrome {
    static let workspace=Color(white:0.115)
    static let header=Color(white:0.075)
    static let surface=Color(white:0.045)
    static let text=Color(white:0.88)
    static let secondary=Color(white:0.58)
    static let border=Color.white.opacity(0.09)
}
private extension CompanionPanel {
    var symbol:String {
        switch self {case .source:return "play.rectangle";case .waveform:return "waveform.path";case .parade:return "chart.bar.xaxis";case .vectorscope:return "scope";case .falseColor:return "camera.filters"}
    }
}
private struct MonitorSheetHeader:View {
    let title:String
    let close:()->Void
    var body:some View {
        HStack {Text(title).font(.system(size:15,weight:.semibold));Spacer();Button(action:close){Image(systemName:"xmark").font(.system(size:12)).frame(width:44,height:44)}.accessibilityLabel("닫기")}
            .padding(.leading,18).padding(.trailing,6).frame(height:52).background(MonitorChrome.header)
    }
}
private struct ScopeSelection:Identifiable {let id:Int}

struct CompanionScreen:View {
    @ObservedObject var model:CompanionModel
    @AppStorage("columns") private var columns=2
    @AppStorage("panelOrder") private var panelOrder="source,waveform,parade,vectorscope,falseColor"
    @AppStorage("panelLayoutStyle") private var layoutRaw=CompanionLayoutStyle.grid.rawValue
    @AppStorage("featuredPanelIndex") private var featuredPanel=0
    @State private var solo:Int?
    @State private var showConnection=false
    @State private var scopeSelection:ScopeSelection?
    @State private var cleanScreen=false
    @State private var fullscreenHint=false
    @State private var showFullscreenExit=false
    private var immersive:Bool {cleanScreen || solo != nil}
    private var panels:[CompanionPanel] {
        let values=panelOrder.split(separator:",").compactMap{CompanionPanel(rawValue:String($0))}
        return values.count == 5 ? values:CompanionPanel.allCases
    }
    private var layout:CompanionLayoutStyle {CompanionLayoutStyle(rawValue:layoutRaw) ?? .grid}
    var body:some View {
        VStack(spacing:0) {
            if !immersive {toolbar;Divider()}
            if let frame=model.displayed {
                if !immersive {statusStrip(frame)}
                GeometryReader {geometry in
                    let arrangement=CompanionPanelLayout.make(size:geometry.size,panelCount:panels.count,style:layout,columns:columns,featured:featuredPanel,solo:solo,sourceOnly:model.scopesEnabled ? nil:(panels.firstIndex(of:.source) ?? 0))
                    ScrollView {
                        ZStack(alignment:.topLeading) {
                            ForEach(arrangement.items) {item in
                                let index=item.id
                                CompanionPanelView(panel:panels[index],image:frame.images[panels[index]],viewImages:frame.viewImages,viewRequests:frame.viewRequests,viewKinds:frame.viewKinds,onRaster:model.setScopeRaster,falseColorMode:$model.falseColorMode,falseColorCenter:$model.falseColorCenter,falseColorSpan:$model.falseColorSpan,cleanScreen:immersive,video:panels[index] == .source && !frame.packet.isTest ? model.videoPresenter:nil,solo:solo == index,
                                    choose:{scopeSelection=ScopeSelection(id:index)},toggleSolo:{solo = solo == index ? nil:index})
                                    .id(panels[index]) // A new scope owns a new raster registration and zoom state.
                                    .frame(width:item.frame.width,height:item.frame.height)
                                    .position(x:item.frame.midX,y:item.frame.midY)
                                    .accessibilityIdentifier("panel-slot-\(index)")
                            }
                        }.frame(width:geometry.size.width,height:arrangement.contentHeight,alignment:.topLeading)
                    }
                }
                if !immersive {metrics(frame.packet)}
            }else {connectionLanding}
        }
        .background(MonitorChrome.workspace)
        .foregroundStyle(MonitorChrome.text).tint(MonitorChrome.text)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden:.automatic)
        .ignoresSafeArea(.container,edges:immersive ? .all:[])
        .overlay(alignment:.top) {if immersive && (fullscreenHint || showFullscreenExit) {Button {solo=nil;cleanScreen=false} label:{Label("전체 화면 종료",systemImage:"arrow.down.right.and.arrow.up.left").font(.caption).padding(10)}.buttonStyle(.plain).background(MonitorChrome.workspace,in:RoundedRectangle(cornerRadius:5)).overlay(RoundedRectangle(cornerRadius:5).stroke(MonitorChrome.border)).padding(.top,12).accessibilityIdentifier("exit-clean-fullscreen")}}
        .simultaneousGesture(LongPressGesture(minimumDuration:0.7).onEnded {_ in if immersive {solo=nil;cleanScreen=false}},including:immersive ? .all:.subviews)
        .simultaneousGesture(TapGesture().onEnded {if immersive {showFullscreenExit=true}},including:immersive ? .all:.subviews)
        .task(id:showFullscreenExit) {if showFullscreenExit {try? await Task.sleep(nanoseconds:3_000_000_000);if !Task.isCancelled {showFullscreenExit=false}}}
        .accessibilityAction(named:"전체 화면 종료") {solo=nil;cleanScreen=false}
        .task(id:immersive) {
            fullscreenHint=immersive
            if immersive {try? await Task.sleep(nanoseconds:2_000_000_000);if !Task.isCancelled {fullscreenHint=false}}
        }
        .onChange(of:layoutRaw) {_ in solo=nil}
        .onChange(of:featuredPanel) {_ in solo=nil}
        .sheet(item:$scopeSelection) {selection in
            VStack(spacing:0) {
                MonitorSheetHeader(title:"스코프 선택") {scopeSelection=nil}
                Divider()
                VStack(spacing:2) {
                    ForEach(CompanionPanel.allCases) {kind in
                        Button {replacePanel(selection.id,kind);scopeSelection=nil} label:{
                            HStack(spacing:12) {Image(systemName:kind.symbol).foregroundStyle(MonitorChrome.secondary).frame(width:20);Text(kind.title);Spacer();if panels[selection.id] == kind {Image(systemName:"checkmark").font(.system(size:12))}}
                                .font(.system(size:13)).padding(.horizontal,14).frame(height:46).contentShape(Rectangle())
                                .background(panels[selection.id] == kind ? Color.white.opacity(0.06):.clear,in:RoundedRectangle(cornerRadius:4))
                        }.buttonStyle(.plain).accessibilityIdentifier("scope-option-\(kind.rawValue)")
                    }
                }.padding(10)
                Spacer(minLength:0)
            }.foregroundStyle(MonitorChrome.text).tint(MonitorChrome.text).background(MonitorChrome.workspace)
                .presentationDetents([.height(340)]).presentationDragIndicator(.hidden)
        }
        .sheet(isPresented:$showConnection) {ConnectionSheet(model:model)}
        .onAppear {columns=min(3,max(1,columns));featuredPanel=min(4,max(0,featuredPanel))}
    }
    private var toolbar:some View {
        HStack(spacing:8) {
            HStack(spacing:7) {
                Image("ResolveScopesMark").resizable().interpolation(.high).frame(width:18,height:18).accessibilityLabel("ResolveScopes 로고")
                Text("ResolveScopes").font(.system(size:15,weight:.semibold))
                Text("1.25.0").font(.system(size:9,design:.monospaced)).foregroundStyle(MonitorChrome.secondary)
            }
            Divider().frame(height:18).padding(.horizontal,6)
            ViewThatFits(in:.horizontal) {
                Text("Resolve · Remote Monitoring").font(.system(size:12))
                Text("Resolve").font(.system(size:12))
            }.lineLimit(1)
            Circle().fill(model.connected ? Color.green:(model.connecting ? .orange:.gray)).frame(width:6,height:6).padding(.leading,4)
            Spacer(minLength:4)
            if model.displayed != nil {
                Button {model.toggleHold()} label:{Label(model.held ? "재개":"Hold",systemImage:model.held ? "play.fill":"pause.fill").padding(.horizontal,8).frame(height:44)}
                    .accessibilityIdentifier("localHold")
                Button {cleanScreen=true} label:{Image(systemName:"arrow.up.left.and.arrow.down.right").frame(width:44,height:44)}.accessibilityLabel("전체 화면 · 화면을 탭하면 종료 버튼 표시").accessibilityIdentifier("clean-fullscreen")
                Menu {
                    Picker("배치",selection:$layoutRaw) {
                        ForEach(CompanionLayoutStyle.allCases) {style in Text(style.title).tag(style.rawValue)}
                    }
                    if layout == .grid {
                        Picker("열 수",selection:$columns) {ForEach(1...3,id:\.self){Text("\($0)열").tag($0)}}
                    }else {
                        Picker("큰 패널",selection:$featuredPanel) {
                            ForEach(panels.indices,id:\.self) {index in Text("패널 \(index+1) · \(panels[index].title)").tag(index)}
                        }
                    }
                    Divider()
                    Button("기본 배치로 복원") {panelOrder="source,waveform,parade,vectorscope,falseColor";columns=2;layoutRaw=CompanionLayoutStyle.grid.rawValue;featuredPanel=0;solo=nil}
                }label:{Image(systemName:"rectangle.split.2x2").frame(width:44,height:44)}.accessibilityLabel("iPad 배치").accessibilityIdentifier("ipad-layout")
            }
            Button {showConnection=true} label:{Image(systemName:"slider.horizontal.3").frame(width:44,height:44)}
                .accessibilityLabel("Resolve 연결 · 측정 설정").accessibilityIdentifier("connection")
        }.font(.system(size:12)).padding(.horizontal,16).frame(height:48).background(MonitorChrome.workspace).buttonStyle(.plain)
    }
    private var connectionLanding:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:10) {Image(systemName:"play.rectangle").foregroundStyle(MonitorChrome.secondary);Text("Resolve 연결").font(.system(size:20,weight:.medium))}
            Text("Resolve의 Remote Monitoring을 시작하고 같은 네트워크의 주소로 연결하세요.")
                .font(.system(size:13)).foregroundStyle(MonitorChrome.secondary).fixedSize(horizontal:false,vertical:true)
            Divider()
            HStack {Circle().fill(model.connecting ? Color.orange:.gray).frame(width:6,height:6);Text(model.status).font(.system(size:11,design:.monospaced))}
            if !model.host.isEmpty {Text(model.host).font(.system(size:12,design:.monospaced)).foregroundStyle(MonitorChrome.secondary)}
            Button("Resolve에 연결") {showConnection=true}.font(.system(size:13,weight:.medium)).buttonStyle(.bordered).frame(minHeight:44)
        }.padding(24).frame(maxWidth:420,alignment:.leading).background(MonitorChrome.surface,in:RoundedRectangle(cornerRadius:5))
            .overlay(RoundedRectangle(cornerRadius:5).stroke(MonitorChrome.border)).padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func statusStrip(_ frame:ReceivedFrame)->some View {
        HStack(spacing:12) {
            Text(frame.packet.timecode ?? "TC —").font(.system(size:11,weight:.medium,design:.monospaced))
                .accessibilityIdentifier("frameTimecode")
            Text(frame.packet.source).foregroundStyle(MonitorChrome.secondary).lineLimit(1)
            if frame.packet.isTest {Text("TEST").foregroundStyle(.yellow)}
            if model.held {Text("iPad HOLD").foregroundStyle(.orange)}
            if frame.packet.macHeld {Text("Mac HOLD").foregroundStyle(.orange)}
            Spacer(minLength:8)
            TimelineView(.periodic(from:.now,by:1)) {context in
                let age=model.frameAge
                Text(NativePlaybackStatus.text(connected:model.connected,age:age,normal:frame.packet.status))
                    .foregroundStyle(!model.connected || (age ?? 0)>2 ? .orange:.secondary).lineLimit(1)
            }
        }.font(.system(size:10,design:.monospaced)).padding(.horizontal,16).frame(height:26).background(MonitorChrome.workspace)
    }
    private func metrics(_ packet:CompanionPacket)->some View {
        VStack(alignment:.leading,spacing:0) {
            Divider()
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:20) {
                    metric("평균 IRE",packet.metrics["meanIRE"])
                    metric("최소 IRE",packet.metrics["minIRE"])
                    metric("최대 IRE",packet.metrics["maxIRE"])
                    metric("최대 nits",packet.metrics["maxNits"])
                    metric("Black %",packet.metrics["belowBlackPercent"])
                    metric("White %",packet.metrics["aboveWhitePercent"])
                    metric("Gamut %",packet.metrics["outOfGamutPercent"])
                    Text(packet.dimensions).font(.system(size:10,design:.monospaced)).foregroundStyle(MonitorChrome.secondary)
                }.padding(.horizontal,14).frame(height:36)
            }
            Divider()
            HStack(spacing:12) {
                Text(model.performanceText).lineLimit(1)
                Spacer(minLength:4)
                Text("\(model.remotePrimaries.rawValue) · \(model.remoteTransfer.rawValue)").lineLimit(1)
            }.font(.system(size:10,design:.monospaced)).foregroundStyle(MonitorChrome.secondary).padding(.horizontal,14).frame(height:26)
            DisclosureGroup("측정 조건") {
                    Text(packet.conditions+"\nTC: \(packet.timecodeOrigin ?? "프레임 TC 없음") · "+"압축 영상의 iPad 로컬 분석 · 원본 Float QC와 구분")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            }.font(.system(size:10)).foregroundStyle(MonitorChrome.secondary).padding(.horizontal,14).padding(.bottom,6)
        }.background(MonitorChrome.workspace)
    }
    private func metric(_ title:String,_ value:Double?)->some View {
        HStack(spacing:6) {Text(title).font(.system(size:9)).foregroundStyle(MonitorChrome.secondary);Text(value.map{String(format:"%.2f",$0)} ?? "—").font(.system(size:11,design:.monospaced))}
    }
    private func replacePanel(_ index:Int,_ panel:CompanionPanel) {
        var values=panels;values[index]=panel;panelOrder=values.map(\.rawValue).joined(separator:",")
    }
}
struct ConnectionSheet:View {
    @ObservedObject var model:CompanionModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0) {
            MonitorSheetHeader(title:"Resolve 연결 · 측정 설정") {dismiss()}
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    section("REMOTE MONITORING") {
                        TextField("Resolve 주소",text:$model.host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .font(.system(size:14,design:.monospaced)).padding(12).background(MonitorChrome.surface,in:RoundedRectangle(cornerRadius:4))
                            .overlay(RoundedRectangle(cornerRadius:4).stroke(MonitorChrome.border))
                        Text("Resolve에서 Remote Monitoring을 시작한 뒤 연결 요청을 승인하세요.").font(.system(size:11)).foregroundStyle(MonitorChrome.secondary)
                        HStack {Circle().fill(model.connected ? Color.green:.gray).frame(width:6,height:6);Text(model.status).font(.system(size:11,design:.monospaced));Spacer()}
                        HStack(spacing:12) {
                            Button(model.connecting ? "연결 중…":"연결") {model.connect()}.disabled(model.connecting).buttonStyle(.bordered)
                            if model.connected || model.connecting {Button("연결 해제",role:.destructive){model.disconnect()}.buttonStyle(.bordered)}
                        }.frame(minHeight:44)
                    }
                    Divider()
                    section("SIGNAL") {
                        setting("Primaries") {Picker("Primaries",selection:$model.remotePrimaries){ForEach(ColorSpace.allCases,id:\.self){Text($0.rawValue).tag($0)}}}
                        setting("Transfer") {Picker("Transfer",selection:$model.remoteTransfer){ForEach(TransferFunction.allCases,id:\.self){Text($0.rawValue).tag($0)}}}
                        setting("파형 모드") {Picker("파형 모드",selection:$model.remoteWaveformMode){ForEach(WaveformMode.allCases,id:\.self){Text($0.rawValue).tag($0)}}}
                        setting("수치 분석") {Picker("수치 분석",selection:$model.remoteSampleWidth){Text("320×180 · 빠름").tag(320);Text("480×270 · 실시간").tag(480);Text("640×360 · 균형").tag(640);Text("960×540 · 정밀").tag(960)}}
                        Text("파형·Parade·Vectorscope·False Color는 수신 전체 픽셀로 계산합니다. 수치 분석 격자는 통계와 미리보기에 적용됩니다.").font(.system(size:11)).foregroundStyle(MonitorChrome.secondary)
                    }
                }.padding(20)
            }
        }.font(.system(size:13)).pickerStyle(.menu).foregroundStyle(MonitorChrome.text).tint(MonitorChrome.text).background(MonitorChrome.workspace).presentationDetents([.large])
    }
    private func setting<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        HStack {Text(title).font(.system(size:13)).foregroundStyle(MonitorChrome.secondary);Spacer();content().labelsHidden().font(.system(size:13)).controlSize(.small)}
            .frame(minHeight:44).overlay(alignment:.bottom){Rectangle().fill(MonitorChrome.border).frame(height:0.5)}
    }
    private func section<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:12) {Text(title).font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(MonitorChrome.secondary);content()}
    }
}

struct CompanionPanelView:View {
    let panel:CompanionPanel
    let image:UIImage?
    var viewImages:[UUID:UIImage]=[:]
    var viewRequests:[UUID:FullRasterScopeRequest]=[:]
    var viewKinds:[UUID:CompanionPanel]=[:]
    var onRaster:(UUID,CompanionPanel,FullRasterScopeRequest?)->Void={_,_,_ in}
    @Binding var falseColorMode:FalseColorStyle
    @Binding var falseColorCenter:Double
    @Binding var falseColorSpan:Double
    var cleanScreen=false
    @State private var rasterID=UUID()
    @Environment(\.displayScale) private var displayScale
    var video:NativeVideoPresenter?=nil
    let solo:Bool
    let choose:()->Void
    let toggleSolo:()->Void
    @State private var scale:CGFloat=1
    @State private var offset=CGSize.zero
    @GestureState private var pinch:CGFloat=1
    @GestureState private var drag=CGSize.zero
    var body:some View {
        VStack(spacing:0) {
            if !cleanScreen {HStack {
                Button(action:choose) {HStack(spacing:7) {Image(systemName:panel.symbol).foregroundStyle(MonitorChrome.secondary);Text(panel.title).fontWeight(.medium);Image(systemName:"chevron.down").font(.system(size:8)).foregroundStyle(MonitorChrome.secondary)}.frame(minHeight:44)}
                    .accessibilityIdentifier("choose-scope-\(panel.rawValue)")
                Spacer()
                Button {scale=1;offset = .zero} label:{Image(systemName:"arrow.counterclockwise").frame(width:44,height:44)}.accessibilityLabel("확대 초기화")
                Button(action:toggleSolo) {Image(systemName:solo ? "rectangle.grid.2x2":"rectangle.expand.vertical").frame(width:44,height:44)}
                    .accessibilityLabel(solo ? "Solo 해제":"Solo").accessibilityIdentifier("solo-\(panel.rawValue)")
            }.font(.system(size:11)).foregroundStyle(MonitorChrome.text).padding(.leading,10).padding(.trailing,2).frame(height:44).background(MonitorChrome.header).buttonStyle(.plain)}
            HStack(spacing:0) {
            GeometryReader {geo in
                ZStack {
                    Color.black
                    if let video {
                        NativeVideoSurface(presenter:video)
                            .scaleEffect(min(8,max(1,scale*pinch)))
                            .offset(x:offset.width+drag.width,y:offset.height+drag.height)
                    }else if viewKinds[rasterID] == panel,let gpuImage=viewImages[rasterID] {
                        let applied=viewRequests[rasterID]?.viewport.effective ?? WaveformViewport()
                        let zoom=min(8,max(1,scale*pinch))
                        let fit=min(geo.size.width/gpuImage.size.width,geo.size.height/gpuImage.size.height)
                        Image(uiImage:gpuImage).resizable().interpolation(.high).scaledToFit()
                            .scaleEffect(x:zoom/applied.zoomX,y:zoom/applied.zoomY)
                            .offset(x:(applied.centerX-0.5)*zoom*gpuImage.size.width*fit+offset.width+drag.width,
                                    y:(0.5-applied.centerY)*zoom*gpuImage.size.height*fit+offset.height+drag.height)
                    }else if let image {
                        Image(uiImage:image).resizable().interpolation(panel == .source ? .none:.high).scaledToFit()
                            .scaleEffect(min(8,max(1,scale*pinch)))
                            .offset(x:offset.width+drag.width,y:offset.height+drag.height)
                    }else {Text("입력 또는 새 분석 대기").foregroundStyle(.secondary)}
                }.frame(width:geo.size.width,height:geo.size.height).clipped().contentShape(Rectangle())
                    .gesture(MagnificationGesture().updating($pinch){value,state,_ in state=value}.onEnded{scale=min(8,max(1,scale*$0));if scale == 1 {offset = .zero}})
                    .simultaneousGesture(DragGesture(minimumDistance:8).updating($drag){value,state,_ in if scale>1 {state=value.translation}}.onEnded{value in
                        if scale>1 {offset.width=min(geo.size.width*3,max(-geo.size.width*3,offset.width+value.translation.width));offset.height=min(geo.size.height*3,max(-geo.size.height*3,offset.height+value.translation.height))}
                    })
                    .onTapGesture(count:2){scale=1;offset = .zero}
                    .onAppear {updateRaster(geo.size)}
                    .onChange(of:geo.size) {_ in updateRaster(geo.size)}
                    .onChange(of:displayScale) {_ in updateRaster(geo.size)}
                    .onChange(of:scale) {_ in updateRaster(geo.size)}
                    .onChange(of:offset) {_ in updateRaster(geo.size)}
                    .onChange(of:panel) {_ in updateRaster(geo.size)}
            }
            if panel == .falseColor {falseColorControls}
            }
        }.background(.black).clipShape(RoundedRectangle(cornerRadius:5))
            .overlay(RoundedRectangle(cornerRadius:5).stroke(MonitorChrome.border))
            .onChange(of:panel){_ in scale=1;offset = .zero}
            .onDisappear {onRaster(rasterID,panel,nil)}
    }
    private var presentation:FalseColorPresentation {.init(mode:falseColorMode,target:falseColorCenter,span:falseColorSpan)}
    private var falseColorControls:some View {
        VStack(spacing:4) {
            Text(falseColorMode == .tvLogic ? String(format:"%.0f IRE",falseColorCenter):"Y′ IRE").font(.system(size:10,weight:.medium,design:.monospaced)).frame(height:18)
            FalseColorGrayBar(presentation:presentation) {value in
                if falseColorMode != .tvLogic {falseColorMode = .tvLogic}
                if falseColorCenter != value {falseColorCenter=value}
            }.frame(width:75)
            Menu {
                Picker("표현",selection:$falseColorMode) {ForEach(FalseColorStyle.allCases){Text($0.title).tag($0)}}
                if falseColorMode == .tvLogic {
                    Picker("색 구간 폭",selection:$falseColorSpan) {Text("5 IRE").tag(5.0);Text("10 IRE").tag(10.0);Text("25 IRE").tag(25.0)}
                }
                Divider()
                Button("55 IRE · 폭25로 초기화") {falseColorCenter=55;falseColorMode = .tvLogic;falseColorSpan=25}
            }label:{
                HStack(spacing:3) {Text(falseColorMode == .tvLogic ? String(format:"TV · %.0f",falseColorSpan):(falseColorMode == .arri ? "ARRI":"전체"));Image(systemName:"chevron.down").font(.system(size:7))}
                    .font(.system(size:9,design:.monospaced)).frame(width:75,height:32)
            }.accessibilityLabel("False Color 표현 · 색 구간 폭 · 초기화").accessibilityIdentifier("false-color-mode")
        }.padding(.vertical,6).frame(width:84).background(MonitorChrome.header)
            .overlay(alignment:.leading){Rectangle().fill(MonitorChrome.border).frame(width:0.5)}
    }
    private func updateRaster(_ size:CGSize) {
        if panel == .falseColor {onRaster(rasterID,panel,.init());return}
        guard FullRasterScopeKind(rawValue:panel.rawValue) != nil else {onRaster(rasterID,panel,nil);return}
        let width=panel == .vectorscope ? min(size.width,size.height):size.width
        let height=panel == .vectorscope ? width:size.height
        let zoom=Double(min(8,max(1,scale)))
        var view=WaveformViewport();view.zoomX=zoom;view.zoomY=zoom
        view.centerX=0.5-Double(offset.width)/max(1,Double(width)*zoom)
        view.centerY=0.5+Double(offset.height)/max(1,Double(height)*zoom)
        onRaster(rasterID,panel,.init(width:Int(max(1,width*displayScale)),height:Int(max(1,height*displayScale)),viewport:view))
    }

}

/// The legend uses the same bands as CPU and GPU classification, so it never
/// invents a second set of thresholds. White at top, black at bottom.
private struct FalseColorGrayBar:View {
    let presentation:FalseColorPresentation
    let setTarget:(Double)->Void
    var body:some View {
        GeometryReader {geometry in
        Canvas {context,size in
            let top:CGFloat=12,height=max(1,size.height-24),bar=CGRect(x:2,y:top,width:32,height:height)
            context.fill(Path(bar),with:.linearGradient(Gradient(colors:[.white,.black]),startPoint:CGPoint(x:0,y:top),endPoint:CGPoint(x:0,y:top+height)))
            for band in presentation.bands {
                let lo=max(0,band.lowerBound ?? 0),hi=min(100,band.upperBound ?? 100)
                guard hi>lo else {continue}
                let color=band.color
                let rect=CGRect(x:bar.minX,y:top+height*(1-hi/100),width:bar.width,height:height*(hi-lo)/100)
                context.fill(Path(rect),with:.color(Color(red:Double(color.red),green:Double(color.green),blue:Double(color.blue))))
            }
            // Headroom tails have no finite height on a0–100axis; explicit
            // end caps keep the green/red clipping indication visible.
            for (ire,y) in [(-1.0,top+height-2),(101.0,top)] {
                let c=presentation.color(ire:ire)
                context.fill(Path(CGRect(x:bar.minX,y:y,width:bar.width,height:2)),with:.color(Color(red:Double(c.red),green:Double(c.green),blue:Double(c.blue))))
            }
            context.stroke(Path(bar),with:.color(.white.opacity(0.3)),lineWidth:0.5)
            for value in stride(from:0,through:100,by:10) {
                let y=top+height*(1-Double(value)/100)
                var tick=Path();tick.move(to:CGPoint(x:35,y:y));tick.addLine(to:CGPoint(x:39,y:y));context.stroke(tick,with:.color(.gray),lineWidth:0.5)
                // Stagger labels on short tiles; all eleven 10-IRE marks remain readable.
                let compact=height<110
                let x:CGFloat=compact ? (value.isMultiple(of:20) ? 49:68):55
                context.draw(Text("\(value)").font(.system(size:compact ? 8:9,design:.monospaced)).foregroundColor(MonitorChrome.secondary),at:CGPoint(x:x,y:y))
            }
            if presentation.mode == .tvLogic {
                let y=top+height*(1-presentation.effectiveTarget/100)
                var marker=Path();marker.move(to:CGPoint(x:0,y:y));marker.addLine(to:CGPoint(x:38,y:y))
                context.stroke(marker,with:.color(.black),lineWidth:3)
                context.stroke(marker,with:.color(.white),lineWidth:1)
            }
        }.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged {value in
                let track=max(1,geometry.size.height-24)
                setTarget(min(100,max(0,((1-(value.location.y-12)/track)*100).rounded())))
            })
            .accessibilityElement().accessibilityLabel("False Color 그레이차트 · 터치하거나 드래그해 기준 밝기 조절")
            .accessibilityAdjustableAction {direction in
                if direction == .increment {setTarget(min(100,presentation.effectiveTarget+1))}
                else if direction == .decrement {setTarget(max(0,presentation.effectiveTarget-1))}
            }.accessibilityIdentifier("false-color-gray-control")
            .accessibilityValue("기준 \(Int(presentation.effectiveTarget)) IRE, "+presentation.bands.map {"\($0.name) \($0.lowerBound.map{String(format:"%.1f",$0)} ?? "미만")–\($0.upperBound.map{String(format:"%.1f",$0)} ?? "이상")"}.joined(separator:", "))
        }
    }
}
