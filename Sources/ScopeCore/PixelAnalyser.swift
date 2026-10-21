import Foundation

public enum PixelAnalyserFormat:String,Codable,CaseIterable,Sendable {
    case eightBit="8-bit",tenBit="10-bit",twelveBit="12-bit",float32="Float32",nits="Nits",nitsPerChannel="Nits / channel"
    public var isNits:Bool { self == .nits || self == .nitsPerChannel }
    public var componentLabels:[String] { self == .nits ? ["Y"]:(self == .nitsPerChannel ? ["R","G","B"]:["R′","G′","B′"]) }
    public var integerMaximum:Double? {
        switch self { case .eightBit:return 255;case .tenBit:return 1023;case .twelveBit:return 4095;default:return nil }
    }
}
public enum PixelAnalyserReadoutRange:String,Codable,CaseIterable,Sendable {
    case frameValues="작업 프레임 값",decodedRGB="Levels 확장 RGB",video="Video 코드 범위",full="Full 코드 범위"
}
public enum PixelAnalyserCellState:String,Sendable {
    case valid,outsideFrame,invalidRGB,invalidMeasurement,unavailableFrame,invalidCenter
}
public struct PixelAnalyserCell:Sendable {
    public let column:Int
    public let row:Int
    /// Zero-based RECEIVED raster location; may be negative/outside for an edge
    /// cell. Nil when the frame or requested center cannot be inspected.
    public let coordinate:SIMD2<Int>?
    public let state:PixelAnalyserCellState
    /// Actual floats supplied by the caller, typically after the input LUT.
    /// Nonfinite components are preserved for diagnosis, never replaced by 0.
    public let frameRGB:SIMD3<Double>?
    /// Three channel values, or one Y value for scalar Nits. Integer formats
    /// round to the nearest integer (ties away from zero) WITHOUT code clipping.
    /// Doubles avoid trapping or overflowing Int for finite HDR excursions.
    public let values:[Double]
    /// Only Nits formats: negative RGB is clipped by the existing EOTF; PQ and
    /// HLG also clip above 1. This flags such display-transform clipping.
    public let eotfClamped:Bool
}
public struct PixelAnalyserResult:Sendable {
    public let cells:[PixelAnalyserCell]
    public let center:SIMD2<Int>?
    public let centerWasClamped:Bool
    public let frameValid:Bool
    public let centerValid:Bool
    public let receivedSize:SIMD2<Int>
    /// Metadata only: these dimensions do not provide original pixel samples.
    public let declaredSourceSize:SIMD2<Int>?
    public var receivedSizeDiffersFromSource:Bool {
        declaredSourceSize.map { $0 != receivedSize } ?? false
    }
    public let validCellCount:Int
    public let outsideCellCount:Int
    public let invalidRGBCellCount:Int
    public let invalidMeasurementCellCount:Int
    public let eotfClampedCellCount:Int
    public let sequence:UInt64
    public let format:PixelAnalyserFormat
    public let readoutRange:PixelAnalyserReadoutRange
    public subscript(column:Int,row:Int)->PixelAnalyserCell? {
        guard (0..<PixelAnalyser.columns).contains(column),(0..<PixelAnalyser.rows).contains(row) else { return nil }
        return cells[row*PixelAnalyser.columns+column]
    }
}

/// An original fixed 17×11 inspection of the supplied RGB Float32 raster.
/// This neither retrieves native capture pixels/YCbCr nor reconstructs pixels
/// missing from transport downsampling. No ROI/key/preview effect is applied.
public enum PixelAnalyser {
    public static let columns=17,rows=11,centerColumn=8,centerRow=5
    /// Normalized center uses the same floor(x*width) convention as source
    /// pins. Finite out-of-range centers clamp to the edge; 1 selects the last
    /// pixel. Nonfinite centers produce unavailable cells instead of a fake 0,0.
    /// The grid stays centered: off-frame cells remain empty, never duplicates.
    public static func analyze(frame:VideoFrame,settings:ScopeSettings=ScopeSettings(),center normalizedCenter:SIMD2<Double>,format:PixelAnalyserFormat = .tenBit,readoutRange:PixelAnalyserReadoutRange = .decodedRGB)->PixelAnalyserResult {
        let frameValid=frame.isValid,centerValid=normalizedCenter.x.isFinite && normalizedCenter.y.isFinite
        let center:SIMD2<Int>? = frameValid && centerValid
            ? SIMD2(min(frame.width-1,Int(unit(normalizedCenter.x)*Double(frame.width))),min(frame.height-1,Int(unit(normalizedCenter.y)*Double(frame.height)))):nil
        let clamped=centerValid && (normalizedCenter.x<0 || normalizedCenter.x>1 || normalizedCenter.y<0 || normalizedCenter.y>1)
        var cells=[PixelAnalyserCell]();cells.reserveCapacity(columns*rows)
        var valid=0,outside=0,invalidRGB=0,invalidMeasurement=0,eotfClamped=0
        for row in 0..<rows { for column in 0..<columns {
            guard let center else {
                cells.append(PixelAnalyserCell(column:column,row:row,coordinate:nil,state:frameValid ? .invalidCenter:.unavailableFrame,frameRGB:nil,values:[],eotfClamped:false));continue
            }
            let coordinate=SIMD2(center.x+column-centerColumn,center.y+row-centerRow)
            guard coordinate.x>=0,coordinate.x<frame.width,coordinate.y>=0,coordinate.y<frame.height else {
                outside+=1
                cells.append(PixelAnalyserCell(column:column,row:row,coordinate:coordinate,state:.outsideFrame,frameRGB:nil,values:[],eotfClamped:false));continue
            }
            let i=(coordinate.y*frame.width+coordinate.x)*4
            let raw=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
            let rgb=SIMD3(ColorMath.normalize(raw.x,levels:settings.levels),ColorMath.normalize(raw.y,levels:settings.levels),ColorMath.normalize(raw.z,levels:settings.levels))
            let inputFinite=finite(raw)
            let values:[Double]
            var clipped=false
            if format.isNits {
                if inputFinite {
                    let tolerance=settings.levels == .video ? 1e-7:0
                    clipped=(settings.transfer.clampsNegativeInput && min(rgb.x,min(rgb.y,rgb.z)) < -tolerance) || ((settings.transfer == .pq || settings.transfer == .hlg) && max(rgb.x,max(rgb.y,rgb.z))>1+tolerance)
                    let linear=ColorMath.displayLinearRGB(rgb,space:settings.colorSpace,transfer:settings.transfer)
                    let scale=settings.transfer == .pq ? 10_000.0:(settings.transfer == .hlg ? 1_000.0:100.0)
                    if format == .nits { values=[ColorMath.luma(linear,space:settings.colorSpace)*scale] }
                    else { values=[linear.x*scale,linear.y*scale,linear.z*scale] }
                } else { values=[Double](repeating:.nan,count:format == .nits ? 1:3) }
            } else {
                let displayed=readoutRange == .frameValues ? raw:rgb
                values=[displayed.x,displayed.y,displayed.z].map { value in
                    let mapped:Double
                    if readoutRange == .video {
                        if let maximum=format.integerMaximum {
                            let scale=(maximum+1)/256 // 16/235, 64/940, 256/3760.
                            mapped=(16+219*value)*scale
                        } else {
                            // Float Video is the 10-bit legal fraction, so its
                            // endpoints are 64/1023 and 940/1023, not 64 and 940.
                            mapped=(64+876*value)/1023
                        }
                    } else { mapped=value*(format.integerMaximum ?? 1) }
                    return format.integerMaximum == nil ? mapped:mapped.rounded(.toNearestOrAwayFromZero)
                }
            }
            let state:PixelAnalyserCellState
            if !inputFinite { state = .invalidRGB;invalidRGB+=1 }
            else if !values.allSatisfy(\.isFinite) { state = .invalidMeasurement;invalidMeasurement+=1 }
            else { state = .valid;valid+=1 }
            if clipped { eotfClamped+=1 }
            cells.append(PixelAnalyserCell(column:column,row:row,coordinate:coordinate,state:state,frameRGB:raw,values:values,eotfClamped:clipped))
        }}
        let declared=frame.sourceWidth>0 && frame.sourceHeight>0 ? SIMD2(frame.sourceWidth,frame.sourceHeight):nil
        return PixelAnalyserResult(cells:cells,center:center,centerWasClamped:clamped,frameValid:frameValid,centerValid:centerValid,receivedSize:SIMD2(frame.width,frame.height),declaredSourceSize:declared,validCellCount:valid,outsideCellCount:outside,invalidRGBCellCount:invalidRGB,invalidMeasurementCellCount:invalidMeasurement,eotfClampedCellCount:eotfClamped,sequence:frame.sequence,format:format,readoutRange:readoutRange)
    }
    /// Stable compact text for UI/clipboard. Nonfinite values are explicit;
    /// large excursions use scientific notation instead of overflowing Int or
    /// generating arbitrarily wide integer strings.
    public static func formatted(_ value:Double,format:PixelAnalyserFormat)->String {
        if value.isNaN { return "NaN" }
        if value == .infinity { return "+Inf" }
        if value == -.infinity { return "−Inf" }
        let magnitude=abs(value),locale=Locale(identifier:"en_US_POSIX")
        if magnitude>=1e7 || (magnitude>0 && magnitude<1e-5) {
            // Foundation's localized formatter may emit E even for a lowercase
            // printf specifier. Normalize the ASCII exponent marker explicitly.
            return String(format:"%.3e",locale:locale,value).lowercased()
        }
        if format.integerMaximum != nil { return value == 0 ? "0":String(format:"%.0f",locale:locale,value) }
        if format.isNits { return String(format:"%.3f",locale:locale,value) }
        return String(format:"%.6f",locale:locale,value)
    }
    private static func unit(_ v:Double)->Double { min(1,max(0,v)) }
    private static func finite(_ rgb:SIMD3<Double>)->Bool { rgb.x.isFinite && rgb.y.isFinite && rgb.z.isFinite }
}
