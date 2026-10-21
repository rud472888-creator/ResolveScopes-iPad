import Foundation

public struct CIETraceSample:Equatable,Sendable {
    public let xyz:SIMD3<Double>
    public let color:SIMD3<Float>
    public init(xyz:SIMD3<Double>,color:SIMD3<Float>) { self.xyz=xyz;self.color=color }
}

/// Native XYZ before chromaticity/view clipping. selectedRGBCount includes
/// nonfinite selected RGB; invalid RGB is excluded from samples, never black.
public struct CIETrace:Sendable {
    public static let maximumSamples=960*540
    public let samples:[CIETraceSample]
    public let selectedRGBCount:Int
    public let invalidRGBCount:Int
    public let invalidXYZCount:Int
    public let sourceName:String
    public let sourceTriangleXY:[SIMD2<Double>]
    public let sourceWhiteXY:SIMD2<Double>
    public let sourceWhiteName:String
    public let error:String?
    public init(samples:[CIETraceSample],selectedRGBCount:Int=0,invalidRGBCount:Int=0,invalidXYZCount:Int=0,sourceName:String="",sourceTriangleXY:[SIMD2<Double>]=[],sourceWhiteXY:SIMD2<Double> = .zero,sourceWhiteName:String="",error:String?=nil) {
        self.samples=samples.count<=Self.maximumSamples ? samples:Array(samples.prefix(Self.maximumSamples))
        self.selectedRGBCount=max(0,selectedRGBCount);self.invalidRGBCount=max(0,invalidRGBCount);self.invalidXYZCount=max(0,invalidXYZCount)
        self.sourceName=sourceName;self.sourceTriangleXY=sourceTriangleXY;self.sourceWhiteXY=sourceWhiteXY;self.sourceWhiteName=sourceWhiteName
        self.error=error ?? (samples.count>Self.maximumSamples ? "CIE trace exceeds the received-raster sample limit.":nil)
    }
}

public struct CIEChromaticityDefinition:Equatable,Sendable {
    public let name:String
    public let triangleXY:[SIMD2<Double>]
    public let whiteXY:SIMD2<Double>
    public let whiteName:String
    public init(name:String,triangleXY:[SIMD2<Double>],whiteXY:SIMD2<Double>,whiteName:String) {
        self.name=name;self.triangleXY=triangleXY;self.whiteXY=whiteXY;self.whiteName=whiteName
    }
    public func triangle(mode:CIEPlotMode)->[SIMD2<Double>]? {
        guard triangleXY.count==3 else { return nil }
        // A projective map preserves a triangle only when its denominator does
        // not cross zero anywhere inside it. Mixed signs cross the u′v′ pole;
        // connecting only the transformed vertices would invert gamut tests.
        if mode == .uv1976 {
            let denominators=triangleXY.map { -2*$0.x+12*$0.y+3 }
            guard denominators.allSatisfy({$0.isFinite && $0>0}) || denominators.allSatisfy({$0.isFinite && $0<0}) else { return nil }
        }
        let values=triangleXY.compactMap { mode.coordinates(fromXY:$0) }
        return values.count==3 ? values:nil
    }
}

public enum CIEConfigurationError:Error,LocalizedError {
    case missingCustomSource,missingCustomTarget
    public var errorDescription:String? {
        switch self {
        case .missingCustomSource:return "CIE custom source primaries are enabled but unavailable."
        case .missingCustomTarget:return "CIE custom target primaries are enabled but unavailable."
        }
    }
}
