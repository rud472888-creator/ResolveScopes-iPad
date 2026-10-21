import Foundation

/// Independent CIE interpretation and rendering. These settings never change
/// the processed RGB buffer, other scopes, or raw QC.
public struct CIEPlotSettings: Codable, Equatable, Sendable {
    public var enabledGamuts: Set<ColorSpace> = [.rec709, .p3D65, .rec2020]
    public var showWhitePoints = true
    public var showBlackbody = false
    public var showDirections = false
    public var targetColorSpace: ColorSpace = .p3D65
    public var sourceOverrideEnabled=false
    public var sourceColorSpace:ColorSpace = .rec709
    public var useCustomSource=false
    public var customSource:CustomRGBPrimaries?
    public var useCustomTarget=false
    public var customTarget:CustomRGBPrimaries?
    public var gamutErrorCheck=false
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabledGamuts, showWhitePoints, showBlackbody, showDirections, targetColorSpace,sourceOverrideEnabled,sourceColorSpace,useCustomSource,customSource,useCustomTarget,customTarget,gamutErrorCheck }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledGamuts = try c.decodeIfPresent(Set<ColorSpace>.self, forKey: .enabledGamuts) ?? [.rec709, .p3D65, .rec2020]
        showWhitePoints = try c.decodeIfPresent(Bool.self, forKey: .showWhitePoints) ?? true
        showBlackbody = try c.decodeIfPresent(Bool.self, forKey: .showBlackbody) ?? false
        showDirections = try c.decodeIfPresent(Bool.self, forKey: .showDirections) ?? false
        targetColorSpace = try c.decodeIfPresent(ColorSpace.self, forKey: .targetColorSpace) ?? .p3D65
        sourceOverrideEnabled=try c.decodeIfPresent(Bool.self,forKey:.sourceOverrideEnabled) ?? false
        sourceColorSpace=try c.decodeIfPresent(ColorSpace.self,forKey:.sourceColorSpace) ?? .rec709
        useCustomSource=try c.decodeIfPresent(Bool.self,forKey:.useCustomSource) ?? false
        customSource=try c.decodeIfPresent(CustomRGBPrimaries.self,forKey:.customSource)
        useCustomTarget=try c.decodeIfPresent(Bool.self,forKey:.useCustomTarget) ?? false
        customTarget=try c.decodeIfPresent(CustomRGBPrimaries.self,forKey:.customTarget)
        gamutErrorCheck=try c.decodeIfPresent(Bool.self,forKey:.gamutErrorCheck) ?? false
    }
}

public extension CIEPlotSettings {
    func sourceDefinition(measurementSpace:ColorSpace)throws->CIEChromaticityDefinition {
        if sourceOverrideEnabled && useCustomSource {
            guard let value=customSource else { throw CIEConfigurationError.missingCustomSource }
            return .init(name:value.name,triangleXY:[value.red,value.green,value.blue],whiteXY:value.white,whiteName:value.whiteName)
        }
        return Self.definition(sourceOverrideEnabled ? sourceColorSpace:measurementSpace)
    }
    func targetDefinition()throws->CIEChromaticityDefinition {
        if useCustomTarget {
            guard let value=customTarget else { throw CIEConfigurationError.missingCustomTarget }
            return .init(name:value.name,triangleXY:[value.red,value.green,value.blue],whiteXY:value.white,whiteName:value.whiteName)
        }
        return Self.definition(targetColorSpace)
    }
    /// RGB is already level-expanded. Override changes CIE primaries only;
    /// the selected measurement transfer remains in force, without adaptation.
    func sourceXYZ(encodedRGB:SIMD3<Double>,settings:ScopeSettings)->SIMD3<Double>? {
        if sourceOverrideEnabled && useCustomSource { return customSource?.xyz(encodedRGB:encodedRGB,transfer:settings.transfer) }
        return ColorPlotCoordinates.xyz(encodedRGB:encodedRGB,space:sourceOverrideEnabled ? sourceColorSpace:settings.colorSpace,transfer:settings.transfer)
    }
    func sourceTriangleXY(source:ColorSpace)->[SIMD2<Double>]? { try? sourceDefinition(measurementSpace:source).triangleXY }
    func sourceWhiteXY(source:ColorSpace)->SIMD2<Double>? { try? sourceDefinition(measurementSpace:source).whiteXY }
    func sourceName(source:ColorSpace)->String? { try? sourceDefinition(measurementSpace:source).name }
    func targetTriangle(mode:CIEPlotMode)->[SIMD2<Double>]? { (try? targetDefinition())?.triangle(mode:mode) }
    private static func definition(_ space:ColorSpace)->CIEChromaticityDefinition {
        let p=space.primaries
        return .init(name:space.rawValue,triangleXY:[p.red,p.green,p.blue],whiteXY:p.white,whiteName:p.whiteName)
    }
}
