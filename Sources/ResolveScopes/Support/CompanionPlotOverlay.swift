import Foundation
import CoreGraphics
import CoreText
#if canImport(ScopeCore)
import ScopeCore
#endif
#if canImport(CompanionKit)
import CompanionKit
#endif

/// Normalized plot guides are captured with the same applied settings as the raster.
struct CompanionPlotOverlay {
    struct Line {var a:CGPoint;var b:CGPoint;var color:[CGFloat]=[1,1,1,0.24];var width:CGFloat=0.7;var dash:[CGFloat]=[]}
    struct Label {var text:String;var point:CGPoint;var color:[CGFloat]=[0.7,0.7,0.7,1]}
    var lines:[Line]=[]
    var labels:[Label]=[]
    var rings:[CGFloat]=[]
    var viewport=WaveformViewport()
    static func make(panel:CompanionPanel,settings:ScopeSettings,waveform:WaveformSettings,vector:VectorScopeSettings)->Self {
        var overlay=Self()
        if panel == .waveform || panel == .parade {
            var wave=waveform
            if panel == .parade {wave=WaveformSettings();wave.mode = .rgbParade}
            for tick in wave.ticks(levels:settings.levels) {
                let y=wave.displayPosition(tick.signal,levels:settings.levels)
                guard (0...1).contains(y) else {continue}
                let major=abs(tick.signal)<1e-8 || abs(tick.signal-0.5)<1e-8 || abs(tick.signal-1)<1e-8
                overlay.lines.append(.init(a:CGPoint(x:0,y:y),b:CGPoint(x:1,y:y),color:[1,1,1,major ? 0.45:0.24],width:major ? 1.1:0.7))
                overlay.labels.append(.init(text:tick.label,point:CGPoint(x:0.01,y:min(0.97,max(0.015,y)))))
            }
            for i in 0...4 {let x=Double(i)/4;overlay.lines.append(.init(a:CGPoint(x:x,y:0),b:CGPoint(x:x,y:1),color:[1,1,1,0.12]))}
            for (index,ire) in wave.targetsIRE.prefix(4).enumerated() {
                let style=wave.targetStyle(at:index),y=wave.displayPosition(ire/100,levels:settings.levels)
                if style.enabled,ire.isFinite,(0...1).contains(y) {
                    overlay.lines.append(.init(a:CGPoint(x:0,y:y),b:CGPoint(x:1,y:y),color:[CGFloat(style.color.red),CGFloat(style.color.green),CGFloat(style.color.blue),0.8]))
                }
            }
            if wave.mode.isParade {
                for i in 1..<wave.mode.channels.count {
                    let x=Double(i)/Double(wave.mode.channels.count)
                    overlay.lines.append(.init(a:CGPoint(x:x,y:0),b:CGPoint(x:x,y:1),color:[1,1,1,0.65],width:1.2))
                }
                for (i,name) in wave.mode.channels.enumerated() {
                    overlay.labels.append(.init(text:name,point:CGPoint(x:(Double(i)+0.5)/Double(wave.mode.channels.count)-0.015,y:0.02)))
                }
            }
        }else if panel == .vectorscope {
            let options=vector.effective,zoom=min(8,max(0.1,settings.vectorZoom))
            overlay.rings=[0.22,0.44,0.66,0.88].map{CGFloat($0*zoom)}
            overlay.lines=[.init(a:CGPoint(x:0.5,y:0),b:CGPoint(x:0.5,y:1),color:[1,1,1,0.32]),.init(a:CGPoint(x:0,y:0.5),b:CGPoint(x:1,y:0.5),color:[1,1,1,0.32])]
            for degrees in stride(from:0,to:360,by:10) {
                let angle=Double(degrees)*Double.pi/180,major=degrees%30==0,r0=major ? 0.455:0.463
                overlay.lines.append(.init(a:CGPoint(x:0.5+cos(angle)*r0,y:0.5+sin(angle)*r0),b:CGPoint(x:0.5+cos(angle)*0.477,y:0.5+sin(angle)*0.477),color:[1,1,1,major ? 0.5:0.25],width:major ? 1:0.7))
            }
            for (index,ring) in overlay.rings.enumerated() where ring<0.9 {
                let r=Double(ring)*0.5*0.707
                overlay.labels.append(.init(text:"\((index+1)*25)",point:CGPoint(x:0.5+r,y:0.5-r)))
            }
            if options.showSkinLine {
                let angle=123.0*Double.pi/180,end=CGPoint(x:0.5+cos(angle)*0.46,y:0.5+sin(angle)*0.46)
                overlay.lines.append(.init(a:CGPoint(x:0.5,y:0.5),b:end,color:[1,0.72,0.25,0.85],width:1,dash:[6,3]))
                overlay.labels.append(.init(text:"SKIN",point:CGPoint(x:end.x-0.04,y:end.y+0.01),color:[1,0.75,0.35,1]))
            }
            func tint(_ name:String)->[CGFloat] {
                switch name {case "R":return [1,0.32,0.3,1];case "Y":return [1,1,0,1];case "G":return [0.3,1,0.4,1];case "C":return [0,1,1,1];case "B":return [0.45,0.62,1,1];default:return [1,0.4,0.85,1]}
            }
            for scale in [VectorTargetScale.percent100,.percent75] {
                var reference=options;reference.targetScale=scale
                for target in VectorScope.targetPositions(space:settings.colorSpace,vector:reference,zoom:zoom) {
                    let p=CGPoint(x:target.position.x,y:1-target.position.y),selected=scale==options.targetScale
                    guard (0.01...0.99).contains(p.x),(0.01...0.99).contains(p.y) else {continue}
                    var color=tint(target.name);if !selected {color[3]=0.45}
                    let r=selected ? 0.008:0.005
                    let corners=[CGPoint(x:p.x-r,y:p.y-r),CGPoint(x:p.x+r,y:p.y-r),CGPoint(x:p.x+r,y:p.y+r),CGPoint(x:p.x-r,y:p.y+r)]
                    for i in 0..<4 {overlay.lines.append(.init(a:corners[i],b:corners[(i+1)%4],color:color,width:selected ? 1.2:0.8))}
                    if scale == .percent100 {var guide=color;guide[3]=0.16;overlay.lines.append(.init(a:CGPoint(x:0.5,y:0.5),b:p,color:guide,dash:[3,5]))}
                    if selected {overlay.labels.append(.init(text:target.name,point:CGPoint(x:p.x-0.008,y:p.y+0.015),color:color))}
                }
            }
            overlay.labels.append(.init(text:"\(options.mode.rawValue) · \(options.targetScale.rawValue) · \(String(format:"%.1f",zoom))×",point:CGPoint(x:0.02,y:0.015)))
        }
        return overlay
    }
    func draw(in context:CGContext,width:Int,height:Int) {
        let w=CGFloat(width),h=CGFloat(height)
        let guideScale=max(1,min(w,h)/256)
        let view=viewport.effective
        func point(_ p:CGPoint)->CGPoint {CGPoint(x:((p.x-view.centerX)*view.zoomX+0.5)*w,y:((p.y-view.centerY)*view.zoomY+0.5)*h)}
        for line in lines {
            context.setLineWidth(line.width*guideScale)
            context.setLineDash(phase:0,lengths:line.dash.map{$0*guideScale})
            context.setStrokeColor(CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:line.color)!)
            context.move(to:point(line.a));context.addLine(to:point(line.b));context.strokePath()
        }
        context.setLineDash(phase:0,lengths:[])
        context.setLineWidth(0.8*guideScale)
        context.setStrokeColor(CGColor(gray:1,alpha:0.28))
        for ring in rings {let origin=point(CGPoint(x:(1-ring)/2,y:(1-ring)/2));context.strokeEllipse(in:CGRect(x:origin.x,y:origin.y,width:ring*w*view.zoomX,height:ring*h*view.zoomY))}
        for label in labels {
            let font=CTFontCreateWithName("Menlo" as CFString,10*guideScale,nil)
            let string=NSAttributedString(string:label.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:label.color)!])
            let text=CTLineCreateWithAttributedString(string),p=point(label.point)
            guard p.x>=0,p.x<=w,p.y>=0,p.y<=h else {continue}
            let bounds=CTLineGetBoundsWithOptions(text,[])
            let origin=CGPoint(x:min(max(2*guideScale,p.x),max(2*guideScale,w-bounds.width-2*guideScale)),y:min(max(2*guideScale,p.y),h-bounds.height-2*guideScale))
            context.setFillColor(CGColor(gray:0,alpha:0.84))
            context.fill(CGRect(x:origin.x-2*guideScale,y:origin.y+bounds.minY-guideScale,width:bounds.width+4*guideScale,height:bounds.height+2*guideScale))
            context.textPosition=origin;CTLineDraw(text,context)
        }
    }
}
