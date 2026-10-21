import Foundation

/// Values supplied to a mapping's bands. Hue and saturation use percent (0…100).
/// IRE is encoded Y′×100; nits uses the selected transfer function and primaries.
public enum FalseColorMeasurement: String, Codable, CaseIterable, Sendable {
    case encodedIRE, nits, hue, saturation
}

public struct FalseColorRGBA: Codable, Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float
    public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public init(rgb8: SIMD3<UInt8>, alpha: Float = 1) {
        self.init(red: Float(rgb8.x)/255, green: Float(rgb8.y)/255, blue: Float(rgb8.z)/255, alpha: alpha)
    }
    public var isValid: Bool {
        [red,green,blue,alpha].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
    public var rgba8: SIMD4<UInt8> {
        func byte(_ v: Float) -> UInt8 { UInt8((min(max(v.isFinite ? v : 0,0),1)*255).rounded()) }
        return SIMD4(byte(red),byte(green),byte(blue),byte(alpha))
    }
}

/// A lower-inclusive, upper-exclusive band. Nil lower/upper means unbounded.
public struct FalseColorRange: Codable, Equatable, Sendable {
    public var name: String
    public var lowerBound: Double?
    public var upperBound: Double?
    public var color: FalseColorRGBA
    public init(name: String, lowerBound: Double?, upperBound: Double?, color: FalseColorRGBA) {
        self.name = name; self.lowerBound = lowerBound; self.upperBound = upperBound; self.color = color
    }
    public func contains(_ value: Double) -> Bool {
        value.isFinite && (lowerBound == nil || value >= lowerBound!) && (upperBound == nil || value < upperBound!)
    }
}

public enum FalseColorValidationError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidName
    case invalidFallback
    case invalidRange(Int)
    case invalidRangeColor(Int)
    case unorderedOrOverlappingRange(Int)
    case tooManyRanges
    case unsupportedLUTSize(Int)
    case invalidLUTSettings
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let value): return "지원하지 않는 False Color 프리셋 버전: \(value)"
        case .invalidName: return "프리셋 이름은 1–128자여야 합니다."
        case .invalidFallback: return "기본 색상은 유한한 0–1 RGBA 값이어야 합니다."
        case .invalidRange(let index): return "구간 \(index + 1)의 이름 또는 경계값이 유효하지 않습니다."
        case .invalidRangeColor(let index): return "구간 \(index + 1)의 색상은 유한한 0–1 RGBA 값이어야 합니다."
        case .unorderedOrOverlappingRange(let index): return "구간 \(index + 1)은 앞 구간 이후에 위치해야 하며 겹칠 수 없습니다."
        case .tooManyRanges: return "프리셋 구간은 최대 256개입니다."
        case .unsupportedLUTSize(let size): return "3D LUT 크기는 17 또는 33이어야 합니다 (입력: \(size))."
        case .invalidLUTSettings: return "3D LUT 설정이 유효하지 않습니다."
        }
    }
}

/// A portable, original false-color preset. Gaps deliberately use `fallback`;
/// malformed presets fail validation rather than silently sorting their bands.
/// Call validate after editing public fields and before applying a preset.
public struct FalseColorMapping: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var name: String
    public var measurement: FalseColorMeasurement
    public var ranges: [FalseColorRange]
    public var fallback: FalseColorRGBA

    public init(name: String, measurement: FalseColorMeasurement = .encodedIRE,
                ranges: [FalseColorRange], fallback: FalseColorRGBA) throws {
        schemaVersion = 1
        self.name = name; self.measurement = measurement; self.ranges = ranges; self.fallback = fallback
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, name, measurement, ranges, fallback }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decode(Int.self, forKey: .schemaVersion)
        name = try box.decode(String.self, forKey: .name)
        measurement = try box.decode(FalseColorMeasurement.self, forKey: .measurement)
        ranges = try box.decode([FalseColorRange].self, forKey: .ranges)
        fallback = try box.decode(FalseColorRGBA.self, forKey: .fallback)
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw FalseColorValidationError.unsupportedSchema(schemaVersion) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128 else { throw FalseColorValidationError.invalidName }
        guard fallback.isValid else { throw FalseColorValidationError.invalidFallback }
        guard ranges.count <= 256 else { throw FalseColorValidationError.tooManyRanges }
        for (index, range) in ranges.enumerated() {
            guard !range.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  range.name.count <= 128,
                  range.lowerBound?.isFinite ?? true, range.upperBound?.isFinite ?? true else {
                throw FalseColorValidationError.invalidRange(index)
            }
            if let lower = range.lowerBound, let upper = range.upperBound, lower >= upper {
                throw FalseColorValidationError.invalidRange(index)
            }
            guard range.color.isValid else { throw FalseColorValidationError.invalidRangeColor(index) }
            if index > 0 {
                guard let previousUpper = ranges[index-1].upperBound, let lower = range.lowerBound,
                      lower >= previousUpper else { throw FalseColorValidationError.unorderedOrOverlappingRange(index) }
            }
        }
    }

    /// Nonfinite values and values outside all explicitly configured bands use
    /// fallback. The built-in mapping therefore paints invalid pixels magenta.
    public func color(for value: Double) -> FalseColorRGBA {
        guard value.isFinite else { return fallback }
        return ranges.first(where: { $0.contains(value) })?.color ?? fallback
    }

    /// Input RGB uses the same normalized/raw conventions as VideoFrame.
    /// Alpha is supplied by the selected band, rather than by the input image.
    public func color(forRGB raw: SIMD3<Double>, settings: ScopeSettings = ScopeSettings()) -> FalseColorRGBA {
        guard raw.x.isFinite, raw.y.isFinite, raw.z.isFinite else { return fallback }
        let rgb = SIMD3(ColorMath.normalize(raw.x,levels:settings.levels),
                        ColorMath.normalize(raw.y,levels:settings.levels),
                        ColorMath.normalize(raw.z,levels:settings.levels))
        let value: Double
        switch measurement {
        case .encodedIRE: value = ColorMath.luma(rgb,space:settings.colorSpace)*100
        case .nits: value = ColorMath.luminanceNits(rgb,space:settings.colorSpace,transfer:settings.transfer)
        case .hue:
            let hsv = ColorMath.hsv(rgb)
            guard hsv.y > 0.0001 else { return fallback } // Achromatic hue is undefined.
            value = hsv.x*100
        case .saturation: value = ColorMath.hsv(rgb).y*100
        }
        return color(for:value)
    }

    /// Full-frame false-color preview, capped at 960×540 like ScopeEngine.
    /// ROI selects measurements in other scopes; it does not crop this viewer.
    public func render(frame: VideoFrame, settings: ScopeSettings = ScopeSettings()) -> ScopeBitmap {
        guard frame.isValid else { return ScopeBitmap(width:1,height:1,rgba:[0,0,0,255]) }
        let scale = min(1,min(960/Double(frame.width),540/Double(frame.height)))
        let width = max(1,Int(Double(frame.width)*scale)), height = max(1,Int(Double(frame.height)*scale))
        var pixels = [UInt8](repeating:0,count:width*height*4)
        for y in 0..<height {
            let sourceY = min(frame.height-1,Int(Double(y)/scale))
            for x in 0..<width {
                let sourceX = min(frame.width-1,Int(Double(x)/scale))
                let input = (sourceY*frame.width+sourceX)*4, output = (y*width+x)*4
                let rgb = SIMD3(Double(frame.rgba[input]),Double(frame.rgba[input+1]),Double(frame.rgba[input+2]))
                let color = color(forRGB:rgb,settings:settings).rgba8
                pixels[output] = color.x; pixels[output+1] = color.y
                pixels[output+2] = color.z; pixels[output+3] = color.w
            }
        }
        return ScopeBitmap(width:width,height:height,rgba:pixels)
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted,.sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
    public static func fromJSON(_ data: Data) throws -> FalseColorMapping {
        try JSONDecoder().decode(FalseColorMapping.self,from:data)
    }

    /// .cube samples are emitted in standard red-fastest order, over raw input
    /// domain 0…1. Every lattice point matches color(forRGB:settings:).
    /// Host interpolation blends discontinuous band boundaries between samples;
    /// a finite 3D LUT cannot reproduce arbitrary hard thresholds exactly.
    public func cubeLUT(size: Int = 33, settings: ScopeSettings = ScopeSettings()) throws -> String {
        try validate()
        guard size == 17 || size == 33 else { throw FalseColorValidationError.unsupportedLUTSize(size) }
        let safeTitle = name.replacingOccurrences(of:"\"",with:"'").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")
        var lines = [
            "# ResolveScopes original false-color mapping, schema 1",
            "# Measurement: \(measurement.rawValue); primaries: \(settings.colorSpace.rawValue); transfer: \(settings.transfer.rawValue); input levels: \(settings.levels.rawValue)",
            "# Hard bands are exact at grid points. Host LUT interpolation blends band edges.",
            "# Luminance reference: \(settings.luminanceUnitLabel); \(settings.luminanceReferenceDescription)",
            "# Alpha is not represented in the .cube format; exported values are RGB only.",
            "TITLE \"\(safeTitle)\"", "LUT_3D_SIZE \(size)",
            "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"
        ]
        lines.reserveCapacity(size*size*size+lines.count)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let rgb = SIMD3(Double(red)/Double(size-1),Double(green)/Double(size-1),Double(blue)/Double(size-1))
                    let value = color(forRGB:rgb,settings:settings)
                    lines.append(String(format:"%.9f %.9f %.9f",locale:Locale(identifier:"en_US_POSIX"),Double(value.red),Double(value.green),Double(value.blue)))
                }
            }
        }
        return lines.joined(separator:"\n")+"\n"
    }

    /// Matches ColorMath.falseColor at every finite IRE value, including both
    /// extended-range tails. Colors are original, not camera exposure presets.
    public static let defaultIRE: FalseColorMapping = {
        let limits: [Double?] = [nil,0,3,10,38,42,52,56,95,100,nil]
        let names = ["Below black","Deep shadows","Shadows","Low mids","Reference 40 IRE","Midtones","Reference 54 IRE","High mids","Highlights","Above white"]
        let colors: [SIMD3<UInt8>] = [SIMD3(150,0,220),SIMD3(28,32,105),SIMD3(35,86,235),SIMD3(75,81,90),SIMD3(40,210,100),SIMD3(130,137,143),SIMD3(235,135,180),SIMD3(190,195,201),SIMD3(255,215,40),SIMD3(255,48,40)]
        let bands = colors.indices.map { FalseColorRange(name:names[$0],lowerBound:limits[$0],upperBound:limits[$0+1],color:FalseColorRGBA(rgb8:colors[$0])) }
        return try! FalseColorMapping(name:"Original IRE",ranges:bands,fallback:FalseColorRGBA(red:1,green:0,blue:1))
    }()
}

/// Encoded-signal display references. ARRI mode follows the published classic
/// signal-level guide; it is not a LogC4/EI-dependent sensor exposure transform.
public enum FalseColorStyle:String,Codable,CaseIterable,Sendable,Identifiable {
    case original,tvLogic,arri
    public var id:String {rawValue}
    public var title:String {switch self {case .original:return "기존 전체";case .tvLogic:return "TVLogic식 구간";case .arri:return "ARRI 참고"}}
}
public struct FalseColorPresentation:Codable,Equatable,Sendable {
    public var mode:FalseColorStyle
    public var target:Double
    /// Total cyan+pink+yellow span. 10 IRE is a narrow, app-specific option;
    /// 25 IRE retains the illustrated field-monitor zone proportions.
    public var span:Double
    public init(mode:FalseColorStyle = .original,target:Double=55,span:Double=25) {self.mode=mode;self.target=target;self.span=span}
    public var effectiveTarget:Double {target.isFinite ? min(100,max(0,target)):55}
    public var effectiveSpan:Double {span.isFinite ? min(25,max(5,span)):25}
    public var bands:[FalseColorRange] {
        func band(_ name:String,_ lo:Double?,_ hi:Double?,_ c:SIMD3<Float>)->FalseColorRange {
            .init(name:name,lowerBound:lo,upperBound:hi,color:.init(red:c.x,green:c.y,blue:c.z))
        }
        if mode == .arri {
            return [band("Black",nil,2.5,.init(0.6,0,0.85)),band("Shadow",2.5,4,.init(0.05,0.2,1)),
                    band("Gray reference",38,42,.init(0,1,0)),band("Pink reference",52,56,.init(1,0.6,0.8)),
                    band("White shoulder",97,99,.init(1,0.9,0)),band("White clip",99,nil,.init(1,0,0))]
        }
        if mode == .original {return FalseColorMapping.defaultIRE.ranges}
        let t=effectiveTarget,k=effectiveSpan/25
        var result=[band("Below black",nil,0,.init(0,1,0))]
        for (name,lo,hi,c) in [("Cyan",t-15*k,t-5*k,SIMD3<Float>(0,0.8,0.85)),("Pink",t-5*k,t,SIMD3<Float>(1,0.6,0.75)),("Yellow",t,t+10*k,SIMD3<Float>(1,0.9,0))] {
            let a=max(0,lo),b=min(100,hi)
            if a<b {result.append(band(name,a,b,c))}
        }
        result.append(band("Above white",100,nil,.init(1,0,0)))
        return result
    }
    public func color(ire:Double)->FalseColorRGBA {
        guard ire.isFinite else {return .init(red:1,green:0,blue:1)}
        if let band=bands.first(where:{$0.contains(ire)}) {return band.color}
        let gray=Float(min(1,max(0,ire/100)))
        return .init(red:gray,green:gray,blue:gray)
    }
    public var legendMapping:FalseColorMapping {try! .init(name:mode.title,ranges:bands,fallback:.init(red:0.5,green:0.5,blue:0.5))}
}
public extension FalseColorMapping {
    static func zoneColor(ire:Double,center:Double)->FalseColorRGBA {
        FalseColorPresentation(mode:.tvLogic,target:center,span:25).color(ire:ire)
    }
}
