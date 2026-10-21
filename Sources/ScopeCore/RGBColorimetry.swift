import Foundation

/// CIE 1931 xy primaries and the native reference white. Chromaticities may
/// lie outside the visible locus (AP0 blue has negative y); do not clamp them.
public struct RGBColorimetry: Equatable, Sendable {
    public let red: SIMD2<Double>
    public let green: SIMD2<Double>
    public let blue: SIMD2<Double>
    public let white: SIMD2<Double>
    public let whiteName: String
    public let name: String
    public var whiteXYZ: SIMD3<Double> { RGBMatrix.xyz(white) }
    let matrix: RGBMatrix
    // Internal preset constructor. Public custom definitions must pass the
    // validating CustomRGBPrimaries initializer before reaching this path.
    init(_ name: String, _ r: SIMD2<Double>, _ g: SIMD2<Double>, _ b: SIMD2<Double>, _ w: SIMD2<Double>, _ whiteName: String) {
        self.name=name; red=r; green=g; blue=b; white=w; self.whiteName=whiteName
        let rp=RGBMatrix.xyz(r), gp=RGBMatrix.xyz(g), bp=RGBMatrix.xyz(b)
        let columns=RGBMatrix(r0:SIMD3(rp.x,gp.x,bp.x),r1:SIMD3(rp.y,gp.y,bp.y),r2:SIMD3(rp.z,gp.z,bp.z))
        let scale=columns.inverse.applying(RGBMatrix.xyz(w))
        matrix=RGBMatrix(r0:columns.r0*scale,r1:columns.r1*scale,r2:columns.r2*scale)
    }
}

extension ColorSpace {
    public var primaries: RGBColorimetry { Self.colorimetries[self]! }
    private static let colorimetries: [ColorSpace: RGBColorimetry] = {
        let d65=SIMD2<Double>(0.3127,0.3290), d50=SIMD2<Double>(0.3457,0.3585), aces=SIMD2<Double>(0.32168,0.33767)
        return [
            .rec709: RGBColorimetry("Rec.709",SIMD2(0.64,0.33),SIMD2(0.30,0.60),SIMD2(0.15,0.06),d65,"D65"),
            .p3D65: RGBColorimetry("P3-D65",SIMD2(0.68,0.32),SIMD2(0.265,0.69),SIMD2(0.15,0.06),d65,"D65"),
            .rec2020: RGBColorimetry("Rec.2020",SIMD2(0.708,0.292),SIMD2(0.17,0.797),SIMD2(0.131,0.046),d65,"D65"),
            .acesAP0: RGBColorimetry("ACES AP0",SIMD2(0.7347,0.2653),SIMD2(0,1),SIMD2(0.0001,-0.077),aces,"ACES white (D60)"),
            .acesAP1: RGBColorimetry("ACES AP1",SIMD2(0.713,0.293),SIMD2(0.165,0.830),SIMD2(0.128,0.044),aces,"ACES white (D60)"),
            .adobeRGB: RGBColorimetry("Adobe RGB (1998)",SIMD2(0.64,0.33),SIMD2(0.21,0.71),SIMD2(0.15,0.06),d65,"D65"),
            // CSS Color 4 §10.7 precise ProPhoto primaries, rather than the
            // four-decimal ROMM registry summary (notably blue y=.000105).
            .proPhoto: RGBColorimetry("ProPhoto RGB",SIMD2(0.734699,0.265301),SIMD2(0.159597,0.840403),SIMD2(0.036598,0.000105),d50,"D50"),
            .p3DCI: RGBColorimetry("P3-DCI",SIMD2(0.68,0.32),SIMD2(0.265,0.69),SIMD2(0.15,0.06),SIMD2(0.314,0.351),"DCI")
        ]
    }()
}

/// Row-major shared matrix arithmetic. Known colorimetry is generated once;
/// no per-pixel inversion or matrix generation is needed by gamut analysis.
struct RGBMatrix: Equatable, Sendable {
    let r0: SIMD3<Double>; let r1: SIMD3<Double>; let r2: SIMD3<Double>
    static let identity=RGBMatrix(r0:SIMD3(1,0,0),r1:SIMD3(0,1,0),r2:SIMD3(0,0,1))
    static func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> { SIMD3(xy.x/xy.y,1,(1-xy.x-xy.y)/xy.y) }
    func applying(_ v: SIMD3<Double>) -> SIMD3<Double> {
        func dot(_ r: SIMD3<Double>) -> Double { r.x*v.x+r.y*v.y+r.z*v.z }
        return SIMD3(dot(r0),dot(r1),dot(r2))
    }
    func multiplied(by other: RGBMatrix) -> RGBMatrix {
        let a=applying(SIMD3(other.r0.x,other.r1.x,other.r2.x)), b=applying(SIMD3(other.r0.y,other.r1.y,other.r2.y)), c=applying(SIMD3(other.r0.z,other.r1.z,other.r2.z))
        return RGBMatrix(r0:SIMD3(a.x,b.x,c.x),r1:SIMD3(a.y,b.y,c.y),r2:SIMD3(a.z,b.z,c.z))
    }
    var inverse: RGBMatrix {
        let a=r0.x,b=r0.y,c=r0.z,d=r1.x,e=r1.y,f=r1.z,g=r2.x,h=r2.y,i=r2.z
        let det=a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
        return RGBMatrix(r0:SIMD3(e*i-f*h,c*h-b*i,b*f-c*e)/det,r1:SIMD3(f*g-d*i,a*i-c*g,c*d-a*f)/det,r2:SIMD3(d*h-e*g,b*g-a*h,a*e-b*d)/det)
    }
    static func adaptation(from source: SIMD2<Double>, to target: SIMD2<Double>) -> RGBMatrix {
        if source == target { return .identity }
        let bradford=RGBMatrix(r0:SIMD3(0.8951,0.2664,-0.1614),r1:SIMD3(-0.7502,1.7135,0.0367),r2:SIMD3(0.0389,-0.0685,1.0296))
        let ratio=bradford.applying(xyz(target))/bradford.applying(xyz(source))
        let scaled=RGBMatrix(r0:bradford.r0*ratio.x,r1:bradford.r1*ratio.y,r2:bradford.r2*ratio.z)
        return bradford.inverse.multiplied(by:scaled)
    }
    static let d65Adaptations: [ColorSpace: RGBMatrix] = {
        var result: [ColorSpace: RGBMatrix] = [:]
        for space in ColorSpace.allCases { result[space]=adaptation(from:space.primaries.white,to:SIMD2(0.3127,0.3290)) }
        return result
    }()
    static func conversion(from source: ColorSpace, to target: ColorSpace) -> RGBMatrix {
        if source == target { return .identity }
        let src=source.primaries, dst=target.primaries
        return dst.matrix.inverse.multiplied(by:adaptation(from:src.white,to:dst.white)).multiplied(by:src.matrix)
    }
}
