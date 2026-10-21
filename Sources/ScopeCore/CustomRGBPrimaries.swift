import Foundation

public enum CustomRGBPrimariesError:Error,LocalizedError,Equatable,Sendable {
    case invalidName,nonfiniteCoordinates,unsupportedCoordinates,zeroPrimaryY,invalidWhite,unstableMatrix
    public var errorDescription:String? {
        switch self {
        case .invalidName:return "원색·백색점 이름은 제어문자 없이 1–128 UTF-8 바이트여야 합니다."
        case .nonfiniteCoordinates:return "원색·백색점 좌표는 유한한 수여야 합니다."
        case .unsupportedCoordinates:return "지원하는 사용자 원색 좌표 범위는 |x|·|y|≤16입니다. 값을 잘라서 적용하지 않습니다."
        case .zeroPrimaryY:return "원색의 y=0 정의는 지원하지 않습니다."
        case .invalidWhite:return "백색점은 x>0, y>0, x+y<1을 만족해야 합니다."
        case .unstableMatrix:return "원색으로 만든 행렬이 특이하거나 수치적으로 불안정합니다."
        }
    }
}

/// CIE-only custom source/target colorimetry. No global custom slot, preset
/// replacement, ICC profile, tone map, or assumed display luminance is created.
/// Negative/virtual primaries (including AP0 blue) remain unchanged.
public struct CustomRGBPrimaries:Codable,Equatable,Hashable,Sendable {
    public let name:String
    public let red:SIMD2<Double>
    public let green:SIMD2<Double>
    public let blue:SIMD2<Double>
    public let white:SIMD2<Double>
    public let whiteName:String
    /// Generated exactly once per validated value; excluded from JSON/hash identity.
    public let colorimetry:RGBColorimetry
    /// Engineering support limits, not claimed boundaries of visible chromaticity.
    public static let maximumCoordinateMagnitude=16.0
    public static let maximumMatrixCondition=1_000_000.0
    public var lumaWeights:SIMD3<Double> { colorimetry.matrix.r1 }

    public init(name:String,red:SIMD2<Double>,green:SIMD2<Double>,blue:SIMD2<Double>,white:SIMD2<Double>,whiteName:String)throws {
        func validName(_ value:String)->Bool {
            !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.utf8.count<=128
                && !value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})
        }
        guard validName(name),validName(whiteName) else { throw CustomRGBPrimariesError.invalidName }
        let coordinates=[red,green,blue,white]
        guard coordinates.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { throw CustomRGBPrimariesError.nonfiniteCoordinates }
        guard coordinates.allSatisfy({max(abs($0.x),abs($0.y))<=Self.maximumCoordinateMagnitude}) else { throw CustomRGBPrimariesError.unsupportedCoordinates }
        guard red.y != 0,green.y != 0,blue.y != 0 else { throw CustomRGBPrimariesError.zeroPrimaryY }
        guard white.x>0,white.y>0,white.x+white.y<1 else { throw CustomRGBPrimariesError.invalidWhite }
        let r=RGBMatrix.xyz(red),g=RGBMatrix.xyz(green),b=RGBMatrix.xyz(blue)
        let columns=RGBMatrix(r0:SIMD3(r.x,g.x,b.x),r1:SIMD3(r.y,g.y,b.y),r2:SIMD3(r.z,g.z,b.z))
        guard Self.stable(columns) else { throw CustomRGBPrimariesError.unstableMatrix }
        let generated=RGBColorimetry(name,red,green,blue,white,whiteName),m=generated.matrix
        guard Self.stable(m) else { throw CustomRGBPrimariesError.unstableMatrix }
        let actual=m.applying(SIMD3(repeating:1)),expected=generated.whiteXYZ
        guard (0..<3).allSatisfy({expected[$0].isFinite && abs(actual[$0]-expected[$0])<=1e-9*max(1,abs(expected[$0]))}) else { throw CustomRGBPrimariesError.unstableMatrix }
        self.name=name;self.red=red;self.green=green;self.blue=blue;self.white=white;self.whiteName=whiteName
        self.colorimetry=generated
    }
    public static func matching(space:ColorSpace)throws->CustomRGBPrimaries {
        let p=space.primaries
        return try CustomRGBPrimaries(name:p.name,red:p.red,green:p.green,blue:p.blue,white:p.white,whiteName:p.whiteName)
    }
    /// Input levels must already be expanded. Retains native white: CIE source
    /// plotting must not silently Bradford-adapt it to D65. Defined negative/HDR
    /// transfer branches are inherited from ColorMath; nonfinite input/output is nil.
    public func xyz(encodedRGB rgb:SIMD3<Double>,transfer:TransferFunction)->SIMD3<Double>? {
        guard let linear=ColorMath.displayLinearRGB(rgb,lumaWeights:lumaWeights,transfer:transfer) else { return nil }
        let result=colorimetry.matrix.applying(linear)
        return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result:nil
    }
    private enum CodingKeys:String,CodingKey { case name,red,green,blue,white,whiteName }
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(name:c.decode(String.self,forKey:.name),red:c.decode(SIMD2<Double>.self,forKey:.red),
            green:c.decode(SIMD2<Double>.self,forKey:.green),blue:c.decode(SIMD2<Double>.self,forKey:.blue),
            white:c.decode(SIMD2<Double>.self,forKey:.white),whiteName:c.decode(String.self,forKey:.whiteName))
    }
    public static func ==(a:Self,b:Self)->Bool {
        a.name==b.name && a.red==b.red && a.green==b.green && a.blue==b.blue && a.white==b.white && a.whiteName==b.whiteName
    }
    public func hash(into hasher:inout Hasher) {
        hasher.combine(name);hasher.combine(red);hasher.combine(green);hasher.combine(blue);hasher.combine(white);hasher.combine(whiteName)
    }
    /// Infinity-norm condition estimate and an inverse residual, after scaling
    /// the matrix to avoid determinant overflow/underflow during validation.
    private static func stable(_ m:RGBMatrix)->Bool {
        func finite(_ x:RGBMatrix)->Bool { [x.r0,x.r1,x.r2].allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}) }
        func norm(_ x:RGBMatrix)->Double { [x.r0,x.r1,x.r2].map{abs($0.x)+abs($0.y)+abs($0.z)}.max() ?? 0 }
        guard finite(m) else { return false }
        let scale=norm(m)
        guard scale.isFinite,scale>0 else { return false }
        let s=RGBMatrix(r0:m.r0/scale,r1:m.r1/scale,r2:m.r2/scale)
        let det=s.r0.x*(s.r1.y*s.r2.z-s.r1.z*s.r2.y)-s.r0.y*(s.r1.x*s.r2.z-s.r1.z*s.r2.x)+s.r0.z*(s.r1.x*s.r2.y-s.r1.y*s.r2.x)
        guard det.isFinite,abs(det)>1e-12 else { return false }
        let inverse=s.inverse
        guard finite(inverse),norm(s)*norm(inverse)<=maximumMatrixCondition else { return false }
        let product=s.multiplied(by:inverse)
        return finite(product) && zip([product.r0,product.r1,product.r2],[RGBMatrix.identity.r0,RGBMatrix.identity.r1,RGBMatrix.identity.r2]).allSatisfy { row,expected in
            (0..<3).allSatisfy { abs(row[$0]-expected[$0])<=1e-9 }
        }
    }
}
