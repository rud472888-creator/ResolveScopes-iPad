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
    struct Line {var a:CGPoint;var b:CGPoint;var color:[CGFloat]=[0.5,0.5,0.5,0.35]}
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
                overlay.lines.append(.init(a:CGPoint(x:0,y:y),b:CGPoint(x:1,y:y)))
                overlay.labels.append(.init(text:tick.label,point:CGPoint(x:0.01,y:min(0.97,max(0.015,y)))))
            }
            for i in 0...4 {let x=Double(i)/4;overlay.lines.append(.init(a:CGPoint(x:x,y:0),b:CGPoint(x:x,y:1)))}
            for (index,ire) in wave.targetsIRE.prefix(4).enumerated() {
                let style=wave.targetStyle(at:index),y=wave.displayPosition(ire/100,levels:settings.levels)
                if style.enabled,ire.isFinite,(0...1).contains(y) {
                    overlay.lines.append(.init(a:CGPoint(x:0,y:y),b:CGPoint(x:1,y:y),color:[CGFloat(style.color.red),CGFloat(style.color.green),CGFloat(style.color.blue),0.8]))
                }
            }
            if wave.mode.isParade {
                for (i,name) in wave.mode.channels.enumerated() {
                    overlay.labels.append(.init(text:name,point:CGPoint(x:(Double(i)+0.5)/Double(wave.mode.channels.count)-0.015,y:0.02)))
                }
            }
        }else if panel == .vectorscope {
            overlay.rings=[0.25,0.5,0.88]
            overlay.lines=[.init(a:CGPoint(x:0.5,y:0),b:CGPoint(x:0.5,y:1)),.init(a:CGPoint(x:0,y:0.5),b:CGPoint(x:1,y:0.5))]
            let options=vector.effective
            if options.showSkinLine {
                let angle=123.0*Double.pi/180
                overlay.lines.append(.init(a:CGPoint(x:0.5,y:0.5),b:CGPoint(x:0.5+cos(angle)*0.46,y:0.5+sin(angle)*0.46),color:[1,0.5,0,0.7]))
            }
            for target in VectorScope.targetPositions(space:settings.colorSpace,vector:options,zoom:settings.vectorZoom) {
                let p=target.position
                if (0...1).contains(p.x),(0...1).contains(p.y) {
                    let color:[CGFloat]=[CGFloat(target.rgb.x),CGFloat(target.rgb.y),CGFloat(target.rgb.z),1]
                    overlay.labels.append(.init(text:"□ "+target.name,point:CGPoint(x:p.x-0.015,y:1-p.y),color:color))
                }
            }
            overlay.labels.append(.init(text:"\(options.mode.rawValue) · \(options.targetScale.rawValue) · Combined",point:CGPoint(x:0.02,y:0.015)))
        }
        return overlay
    }
    func draw(in context:CGContext,width:Int,height:Int) {
        let w=CGFloat(width),h=CGFloat(height)
        let guideScale=max(1,min(w,h)/256)
        let view=viewport.effective
        func point(_ p:CGPoint)->CGPoint {CGPoint(x:((p.x-view.centerX)*view.zoomX+0.5)*w,y:((p.y-view.centerY)*view.zoomY+0.5)*h)}
        context.setLineWidth(0.7*guideScale)
        for line in lines {
            context.setStrokeColor(CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:line.color)!)
            context.move(to:point(line.a));context.addLine(to:point(line.b));context.strokePath()
        }
        context.setStrokeColor(CGColor(gray:0.5,alpha:0.35))
        for ring in rings {let origin=point(CGPoint(x:(1-ring)/2,y:(1-ring)/2));context.strokeEllipse(in:CGRect(x:origin.x,y:origin.y,width:ring*w*view.zoomX,height:ring*h*view.zoomY))}
        for label in labels {
            let font=CTFontCreateWithName("Menlo" as CFString,10*guideScale,nil)
            let string=NSAttributedString(string:label.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:label.color)!])
            context.textPosition=point(label.point);CTLineDraw(CTLineCreateWithAttributedString(string),context)
        }
    }
}
