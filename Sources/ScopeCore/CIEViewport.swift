import Foundation

public struct CIEViewportFitResult:Equatable,Sendable {
    public let viewport:CIEViewport?
    public let includedCount:Int
    public let excludedCount:Int
    public let error:String?
}
public struct CIEClippedSegment:Equatable,Sendable {
    /// Normalized coordinates, increasing right/up, clipped to the unit square.
    public let start:SIMD2<Double>
    public let end:SIMD2<Double>
}

/// Physical chromaticity axes. Screen Y inversion happens only in the caller.
/// Finite axes are bounded to ±1e6, with a nonzero minimum span of 1e-12.
public struct CIEViewport:Codable,Equatable,Sendable {
    public var xMin:Double
    public var xMax:Double
    public var yMin:Double
    public var yMax:Double
    public static let maximumMagnitude=1e6
    public init(xMin:Double=0,xMax:Double=0.8,yMin:Double=0,yMax:Double=0.9) {
        self.xMin=xMin;self.xMax=xMax;self.yMin=yMin;self.yMax=yMax
    }
    public static func defaults(mode:CIEPlotMode)->Self {
        Self(xMin:mode.xAxis.minimum,xMax:mode.xAxis.maximum,yMin:mode.yAxis.minimum,yMax:mode.yAxis.maximum)
    }
    public var isValid:Bool {
        [xMin,xMax,yMin,yMax].allSatisfy{$0.isFinite && abs($0)<=Self.maximumMagnitude} && xMax-xMin>=1e-12 && yMax-yMin>=1e-12
    }
    public func normalized(_ point:SIMD2<Double>)->SIMD2<Double>? {
        guard isValid,point.x.isFinite,point.y.isFinite else { return nil }
        let value=SIMD2((point.x-xMin)/(xMax-xMin),(point.y-yMin)/(yMax-yMin))
        return value.x.isFinite && value.y.isFinite ? value:nil
    }
    public func physical(_ point:SIMD2<Double>)->SIMD2<Double>? {
        guard isValid,point.x.isFinite,point.y.isFinite else { return nil }
        let value=SIMD2(xMin+point.x*(xMax-xMin),yMin+point.y*(yMax-yMin))
        return value.x.isFinite && value.y.isFinite ? value:nil
    }
    /// A factor >1 zooms in about a normalized anchor. Invalid proposals do nothing.
    @discardableResult public mutating func zoom(by factor:Double,at anchor:SIMD2<Double> = SIMD2(repeating:0.5))->Bool {
        guard factor.isFinite,factor>0,let fixed=physical(anchor) else { return false }
        let width=(xMax-xMin)/factor,height=(yMax-yMin)/factor
        let next=Self(xMin:fixed.x-anchor.x*width,xMax:fixed.x+(1-anchor.x)*width,yMin:fixed.y-anchor.y*height,yMax:fixed.y+(1-anchor.y)*height)
        guard next.isValid else { return false };self=next;return true
    }
    /// Content follows normalized pointer deltas; axes move in the opposite direction.
    @discardableResult public mutating func pan(by delta:SIMD2<Double>)->Bool {
        guard isValid,delta.x.isFinite,delta.y.isFinite else { return false }
        let dx=delta.x*(xMax-xMin),dy=delta.y*(yMax-yMin)
        let next=Self(xMin:xMin-dx,xMax:xMax-dx,yMin:yMin-dy,yMax:yMax-dy)
        guard next.isValid else { return false };self=next;return true
    }
    /// Ignores nonfinite/extreme points explicitly. Fit never fabricates an empty range.
    public static func fit(points:[SIMD2<Double>],padding:Double=0.05)->CIEViewportFitResult {
        var lo=SIMD2<Double>(repeating:.infinity),hi=SIMD2<Double>(repeating:-.infinity),included=0,excluded=0
        for p in points {
            guard p.x.isFinite,p.y.isFinite,abs(p.x)<=maximumMagnitude,abs(p.y)<=maximumMagnitude else { excluded += 1;continue }
            lo=SIMD2(min(lo.x,p.x),min(lo.y,p.y));hi=SIMD2(max(hi.x,p.x),max(hi.y,p.y));included += 1
        }
        guard included>0 else { return .init(viewport:nil,includedCount:0,excludedCount:excluded,error:"No finite chromaticities within the safe fit extent.") }
        let margin=padding.isFinite ? min(1,max(0,padding)):0.05
        let width=max(1e-4,hi.x-lo.x),height=max(1e-4,hi.y-lo.y),center=(lo+hi)/2
        let viewport=Self(xMin:max(-maximumMagnitude,center.x-width*(0.5+margin)),xMax:min(maximumMagnitude,center.x+width*(0.5+margin)),yMin:max(-maximumMagnitude,center.y-height*(0.5+margin)),yMax:min(maximumMagnitude,center.y+height*(0.5+margin)))
        return .init(viewport:viewport.isValid ? viewport:nil,includedCount:included,excludedCount:excluded,error:viewport.isValid ? nil:"Unable to construct a safe CIE range.")
    }
    /// Bounded nice ticks, including negative axes. No unbounded Int conversions.
    public func ticks(axis:Int,maximumCount:Int=12)->[Double] {
        guard isValid,(0...1).contains(axis) else { return [] }
        let lo=axis==0 ? xMin:yMin,hi=axis==0 ? xMax:yMax,count=min(64,max(2,maximumCount))
        let raw=(hi-lo)/Double(count-1),base=pow(10,floor(log10(raw))),fraction=raw/base
        let step=(fraction<=1 ? 1:(fraction<=2 ? 2:(fraction<=5 ? 5:10)))*base
        guard step.isFinite,step>0 else { return [] }
        let first=ceil(lo/step)*step
        return (0..<count).map { first+Double($0)*step }.filter { $0.isFinite && $0>=lo && $0<=hi }
    }
    /// Liang–Barsky clipping in normalized space. No endpoint clamping rails.
    public func clippedSegment(from start:SIMD2<Double>,to end:SIMD2<Double>)->CIEClippedSegment? {
        guard let a=normalized(start),let b=normalized(end),max(abs(a.x),abs(a.y),abs(b.x),abs(b.y))<=1e12 else { return nil }
        let d=b-a;var lower=0.0,upper=1.0
        for (p,q) in [(-d.x,a.x),(d.x,1-a.x),(-d.y,a.y),(d.y,1-a.y)] {
            if p==0 { if q<0 { return nil };continue }
            let r=q/p
            if p<0 { lower=max(lower,r) } else { upper=min(upper,r) }
            if lower>upper { return nil }
        }
        return .init(start:a+lower*d,end:a+upper*d)
    }
}
