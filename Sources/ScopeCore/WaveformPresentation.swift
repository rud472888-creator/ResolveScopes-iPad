import Foundation

public struct WaveformTargetStyle:Codable,Equatable,Sendable {
    public var enabled=true
    public var color=FalseColorRGBA(red:1,green:0.85,blue:0.1)
    public var thickness:Double=1
    public init() {}
    public var effective:Self {
        var value=self
        if !value.color.isValid { value.color=FalseColorRGBA(red:1,green:0.85,blue:0.1) }
        value.thickness=thickness.isFinite ? min(5,max(1,thickness)):1
        return value
    }
}

/// Local display transform of the already rendered waveform raster. It does not
/// change sampling, the base signal range, measurement values or another panel.
public struct WaveformViewport:Codable,Equatable,Sendable {
    public var zoomX:Double=1
    public var zoomY:Double=1
    public var centerX:Double=0.5
    public var centerY:Double=0.5
    public init() {}
    public var effective:Self {
        var v=self
        v.zoomX=zoomX.isFinite ? min(20,max(1,zoomX)):1
        v.zoomY=zoomY.isFinite ? min(20,max(0.5,zoomY)):1
        v.centerX=centerX.isFinite ? min(1,max(0,centerX)):0.5
        v.centerY=centerY.isFinite ? min(2,max(-1,centerY)):0.5
        return v
    }
    /// Input/output normalized coordinates use the bottom-left origin.
    public func project(_ point:SIMD2<Double>)->SIMD2<Double> {
        let v=effective
        return SIMD2((point.x-v.centerX)*v.zoomX+0.5,(point.y-v.centerY)*v.zoomY+0.5)
    }
    public func unproject(_ point:SIMD2<Double>)->SIMD2<Double> {
        let v=effective
        return SIMD2((point.x-0.5)/v.zoomX+v.centerX,(point.y-0.5)/v.zoomY+v.centerY)
    }
    public mutating func zoomVertically(by factor:Double,at point:SIMD2<Double>) {
        guard factor.isFinite,factor>0,point.x.isFinite,point.y.isFinite else { return }
        let fixed=unproject(point)
        zoomY=effective.zoomY*factor;self=effective
        centerY=fixed.y-(point.y-0.5)/zoomY;self=effective
    }
    public mutating func pan(by delta:SIMD2<Double>) {
        guard delta.x.isFinite,delta.y.isFinite else { return }
        let v=effective;centerX=v.centerX-delta.x/v.zoomX;centerY=v.centerY-delta.y/v.zoomY;self=effective
    }
    public mutating func preset(zoom:Double,highlights:Bool) {
        zoomY=zoom;self=effective
        centerY=highlights ? 1-0.5/zoomY:0.5/zoomY
        self=effective
    }
    public mutating func reset() { self=Self() }
}

public extension WaveformSettings {
    /// Only the display classification tolerates Float32 code endpoints. Values
    /// and peak statistics retain their actual negative/HDR excursions.
    func displayPosition(_ signal:Double,levels:SignalLevels)->Double {
        var y=position(signal)
        let bounds=signalBounds
        let tolerance=(levels == .video ? 1e-7:1e-12)/(bounds.upperBound-bounds.lowerBound)
        if y<0,y>=(-tolerance) { y=0 }
        if y>1,y<=1+tolerance { y=1 }
        return y
    }
    func targetStyle(at index:Int)->WaveformTargetStyle {
        targetStyles.indices.contains(index) ? targetStyles[index].effective:WaveformTargetStyle()
    }
    /// Inverse of displayed units, retaining IRE as the stable saved signal unit.
    func signal(displayValue:Double,levels:SignalLevels)->Double? {
        guard displayValue.isFinite else { return nil }
        switch effectiveScale {
        case .ire,.percentage:return displayValue/100
        case .code8:return levels == .video ? (displayValue-16)/219:displayValue/255
        case .code10:return levels == .video ? (displayValue-64)/876:displayValue/1023
        case .pq,.hlg:return Self.signal(nits:displayValue,scale:effectiveScale)
        case .millivolts:return displayValue/700
        }
    }
    func targetSignal(plotY:Double,viewport:WaveformViewport)->Double? {
        guard plotY.isFinite else { return nil }
        let normalized=viewport.unproject(SIMD2(0.5,plotY)).y,bounds=signalBounds
        let signal=bounds.lowerBound+normalized*(bounds.upperBound-bounds.lowerBound)
        return signal.isFinite ? signal:nil
    }
}
