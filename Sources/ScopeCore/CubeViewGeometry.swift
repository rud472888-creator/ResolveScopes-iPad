import Foundation

/// Local display controls: these never change analyzed RGB or scope statistics.
/// Angles are radians; pan is a fraction of viewport width/height (Y down).
public struct CubeViewSettings: Codable, Equatable, Sendable {
    public var rotationX = 0.35
    public var rotationY = 0.65
    public var rotationZ = 0.0
    public var pan = SIMD2<Double>.zero
    public var zoom = 1.0
    public var pointSize = 1.6
    public var brightness = 1.0
    /// Additional thinning of the engine's ALREADY SAMPLED cube point array.
    public var downsample = 1
    public init() {}
    public var effective: CubeViewSettings {
        var value = self
        func angle(_ angle: Double, fallback: Double) -> Double { angle.isFinite ? angle.truncatingRemainder(dividingBy: 2 * .pi) : fallback }
        func bound(_ input: Double, _ minimum: Double, _ maximum: Double, fallback: Double) -> Double {
            input.isFinite ? min(maximum,max(minimum,input)) : fallback
        }
        value.rotationX = angle(rotationX,fallback:0.35)
        value.rotationY = angle(rotationY,fallback:0.65)
        value.rotationZ = angle(rotationZ,fallback:0)
        value.pan = SIMD2(bound(pan.x,-2,2,fallback:0),bound(pan.y,-2,2,fallback:0))
        value.zoom = bound(zoom,0.25,4,fallback:1)
        value.pointSize = bound(pointSize,0.5,6,fallback:1.6)
        value.brightness = bound(brightness,0,4,fallback:1)
        value.downsample = min(16,max(1,downsample))
        return value
    }
    /// Reset navigation while retaining the user's point rendering preferences.
    public mutating func resetView() {
        let initial = CubeViewSettings()
        rotationX = initial.rotationX; rotationY = initial.rotationY; rotationZ = initial.rotationZ
        pan = .zero; zoom = 1
    }
}

public struct CubeProjectedPoint: Equatable, Sendable {
    /// Screen pixels, X right/Y down, with orthographic depth for marker sorting.
    public let screen: SIMD2<Double>
    public let depth: Double
}
public struct CubeProjectedSample: Equatable, Sendable {
    public let normalizedCoordinates: SIMD3<Double>
    public let point: CubeProjectedPoint
    public var insideReferenceBox: Bool {
        (0...1).contains(normalizedCoordinates.x) && (0...1).contains(normalizedCoordinates.y) && (0...1).contains(normalizedCoordinates.z)
    }
}

/// Shared projection for the cloud, pins, cage and axes. Original independent
/// orthographic view convention: rotate Y, then X, then Z about the box center.
public enum CubeViewGeometry {
    public static let maximumDisplayPoints = 16_384
    public static func project(normalized v: SIMD3<Double>, viewport: SIMD2<Double>, view: CubeViewSettings = CubeViewSettings()) -> CubeProjectedPoint? {
        guard finite(v),viewport.x.isFinite,viewport.y.isFinite,viewport.x>0,viewport.y>0,viewport.x<=1e6,viewport.y<=1e6 else { return nil }
        let s = view.effective
        let x=v.x-0.5,y=v.y-0.5,z=v.z-0.5
        let xY=x*cos(s.rotationY)+z*sin(s.rotationY),zY = -x*sin(s.rotationY)+z*cos(s.rotationY)
        let yX=y*cos(s.rotationX)-zY*sin(s.rotationX),zX=y*sin(s.rotationX)+zY*cos(s.rotationX)
        let xZ=xY*cos(s.rotationZ)-yX*sin(s.rotationZ),yZ=xY*sin(s.rotationZ)+yX*cos(s.rotationZ)
        let scale=min(viewport.x,viewport.y)*0.65*s.zoom
        let screen=SIMD2(viewport.x/2+xZ*scale+s.pan.x*viewport.x,viewport.y/2-yZ*scale+s.pan.y*viewport.y)
        guard screen.x.isFinite,screen.y.isFinite,zX.isFinite else { return nil }
        return CubeProjectedPoint(screen:screen,depth:zX)
    }
    /// Already levels-expanded encoded RGB for BOTH cloud points and pins.
    /// Caller decides whether to omit out-of-box points; this helper never clips.
    public static func projectRGB(_ rgb: SIMD3<Double>, model: CubeColorModel, space: ColorSpace, transfer: TransferFunction, viewport: SIMD2<Double>, view: CubeViewSettings = CubeViewSettings()) -> CubeProjectedSample? {
        guard let coordinate=model.normalizedCoordinates(encodedRGB:rgb,space:space,transfer:transfer),
              let point=project(normalized:coordinate,viewport:viewport,view:view) else { return nil }
        return CubeProjectedSample(normalizedCoordinates:coordinate,point:point)
    }
    /// Video Float32 code endpoints can normalize a few ulps outside the box.
    /// Only the Encoded RGB display classification gets this tolerance; the
    /// physical/projected coordinates and measured RGB remain untouched.
    public static func isInsideReferenceBox(_ sample:CubeProjectedSample,levels:SignalLevels,model:CubeColorModel)->Bool {
        let e=levels == .video && model == .encodedRGB ? 1e-7:0
        let v=sample.normalizedCoordinates
        return v.x >= -e && v.x <= 1+e && v.y >= -e && v.y <= 1+e && v.z >= -e && v.z <= 1+e
    }
    /// Equal-population midpoint indices cover the whole existing cloud instead
    /// of truncating its prefix. This does not recover source pixels absent from
    /// ScopeEngine.cubePoints or from the Resolve frame transport.
    public static func displayIndices(totalCount: Int, downsample: Int = 1) -> [Int] {
        guard totalCount>0 else { return [] }
        let thinning=min(16,max(1,downsample))
        let requested=totalCount/thinning+(totalCount%thinning>0 ? 1:0)
        let count=min(maximumDisplayPoints,requested)
        // Quotient/remainder form avoids index*totalCount overflow even when
        // public callers supply Int.max; indices remain ordered and distinct.
        let size=totalCount/count,remainder=totalCount%count
        return (0..<count).map { index in
            let low=index*size+index*remainder/count
            let high=(index+1)*size+(index+1)*remainder/count
            return low+(high-low-1)/2
        }
    }
    public static func displayTint(_ rgb: SIMD3<Double>, brightness: Double = 1) -> SIMD3<Double>? {
        guard finite(rgb) else { return nil }
        let gain=brightness.isFinite ? min(4,max(0,brightness)):1
        // Small common lift retains visibility of black/neutral points.
        func component(_ value: Double) -> Double { min(1,(min(1,max(0,value))*0.8+0.2)*gain) }
        return SIMD3(component(rgb.x),component(rgb.y),component(rgb.z))
    }
    private static func finite(_ value: SIMD3<Double>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
}
