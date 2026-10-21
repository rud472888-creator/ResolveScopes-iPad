import Foundation

/// Geometry in the selected physical xy or u′v′ plane, without display clipping.
/// Nearest-edge pin arrows are an independent visualization, not vendor mathematics.
public enum CIEOverlayGeometry {
    public struct OutsideDirection: Equatable, Sendable {
        public let point: SIMD2<Double>
        public let boundary: SIMD2<Double>
        public let outward: SIMD2<Double>
    }
    public static func triangle(space: ColorSpace, mode: CIEPlotMode) -> [SIMD2<Double>]? {
        let p = space.primaries
        let points = [p.red, p.green, p.blue].compactMap { mode.coordinates(fromXY: $0) }
        return points.count == 3 ? points : nil
    }
    public static func whitePoint(space: ColorSpace, mode: CIEPlotMode) -> SIMD2<Double>? {
        mode.coordinates(fromXY: space.primaries.white)
    }
    public static func outsideDirection(fromXY xy: SIMD2<Double>, target: ColorSpace, mode: CIEPlotMode) -> OutsideDirection? {
        guard let point = mode.coordinates(fromXY: xy), let vertices = triangle(space: target, mode: mode) else { return nil }
        return outsideDirection(point: point, triangle: vertices)
    }
    /// Euclidean nearest edge in the selected chromaticity plane. Boundary points
    /// are inside. Invalid, degenerate and impractically large geometry is omitted.
    public static func outsideDirection(point: SIMD2<Double>, triangle: [SIMD2<Double>]) -> OutsideDirection? {
        func valid(_ p: SIMD2<Double>) -> Bool { p.x.isFinite && p.y.isFinite && max(abs(p.x),abs(p.y)) < 1e6 }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x*b.y-a.y*b.x }
        guard triangle.count == 3, valid(point), triangle.allSatisfy(valid) else { return nil }
        let area = cross(triangle[1]-triangle[0], triangle[2]-triangle[0])
        guard abs(area) > 1e-14 else { return nil }
        let sign = area > 0 ? 1.0 : -1.0
        var inside = true
        var nearest = triangle[0], distance = Double.infinity
        for i in 0..<3 {
            let a = triangle[i], b = triangle[(i+1)%3], edge = b-a
            if sign*cross(edge,point-a) < -1e-12 { inside = false }
            let length2 = edge.x*edge.x+edge.y*edge.y
            guard length2 > 1e-20 else { return nil }
            let delta = point-a
            let t = max(0,min(1,(delta.x*edge.x+delta.y*edge.y)/length2))
            let candidate = a+t*edge, d = point-candidate
            let squared = d.x*d.x+d.y*d.y
            if squared < distance { distance = squared; nearest = candidate }
        }
        guard !inside, distance > 1e-24, distance.isFinite else { return nil }
        return OutsideDirection(point: point, boundary: nearest, outward: (point-nearest)/sqrt(distance))
    }

    /// Published cubic Planckian approximation, NOT a daylight locus or CCT estimator.
    /// Genovés Guzmán & Dowhuszko (2024), DOI 10.1109/JLT.2024.3394788,
    /// equations 45–46. We expose only their fully specified 2222–25000 K interval.
    public static let blackbodyTemperatureRange: ClosedRange<Double> = 2222...25000
    public static func blackbodyXY(kelvin t: Double) -> SIMD2<Double>? {
        guard t.isFinite, blackbodyTemperatureRange.contains(t) else { return nil }
        let q = 1000/t
        let x: Double
        if t <= 4000 { x = -0.2661239*q*q*q-0.2343589*q*q+0.8776956*q+0.179910 }
        else { x = -3.0258469*q*q*q+2.1070379*q*q+0.2226347*q+0.240390 }
        let y: Double
        if t <= 4000 { y = -0.9549476*x*x*x-1.37418593*x*x+2.09137015*x-0.16748867 }
        else { y = 3.0817580*x*x*x-5.87338670*x*x+3.75112997*x-0.37001483 }
        return SIMD2(x,y)
    }
    /// Fixed bounded cache; reciprocal-temperature spacing resolves the warm end.
    public static let blackbodyLocus: [SIMD2<Double>] = (0...96).compactMap { i in
        let fraction = Double(i)/96
        let reciprocal = (1-fraction)/blackbodyTemperatureRange.lowerBound+fraction/blackbodyTemperatureRange.upperBound
        return blackbodyXY(kelvin: 1/reciprocal)
    }
}
