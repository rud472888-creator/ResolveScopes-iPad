import Foundation

/// EBU R103 v3 Annex 1 (p5) coefficients, used only as a progressive received-
/// raster inspection filter. This is not native-resolution/interlaced EBU QC.
public enum WaveformSignalFilter {
    public static let horizontalCoefficients:[Double]=[1,2,3,4,3,2,1].map { Double($0)/16 }
    public static let verticalCoefficients:[Double]=[0.25,0.5,0.25]
    public static func sample(frame:VideoFrame,x:Int,y:Int,levels:SignalLevels = .full)->SIMD3<Double>? {
        sampleRGB(frame:frame,levels:levels,x:x,y:y)
    }
    /// Whole-raster neighbors, before ROI/key. Frame borders replicate. If ANY
    /// RGB component in the 7×3 support is nonfinite, the entire result is nil:
    /// no black replacement, omitted-tap renormalization, or invented validity.
    /// Levels expand exactly once; finite negative/HDR RGB remains unclamped.
    public static func sampleRGB(frame:VideoFrame,levels:SignalLevels = .full,x:Int,y:Int)->SIMD3<Double>? {
        guard frame.isValid,x>=0,x<frame.width,y>=0,y<frame.height else { return nil }
        var result=SIMD3<Double>.zero
        for dy in -1...1 { for dx in -3...3 {
            let sx=min(frame.width-1,max(0,x+dx)),sy=min(frame.height-1,max(0,y+dy)),i=(sy*frame.width+sx)*4
            let raw=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
            guard raw.x.isFinite,raw.y.isFinite,raw.z.isFinite else { return nil }
            let rgb=SIMD3(ColorMath.normalize(raw.x,levels:levels),ColorMath.normalize(raw.y,levels:levels),ColorMath.normalize(raw.z,levels:levels))
            result+=rgb*(horizontalCoefficients[dx+3]*verticalCoefficients[dy+1])
        }}
        return result
    }
}

/// Engine implementation: only three horizontal rows are cached, plus one
/// temporary normalized row. Memory scales with received width, not frame area.
final class WaveformSignalSampler {
    private struct Row { var rgb:[SIMD3<Double>];var valid:[Bool] }
    private let frame:VideoFrame
    private let levels:SignalLevels
    private var rows:[Int:Row]=[:]
    private var currentY:Int?
    init(frame:VideoFrame,levels:SignalLevels) { self.frame=frame;self.levels=levels }
    func beginRow(_ y:Int) {
        guard frame.isValid,y>=0,y<frame.height,currentY != y else { return }
        currentY=y
        let needed=Set((-1...1).map { min(frame.height-1,max(0,y+$0)) })
        rows=rows.filter { needed.contains($0.key) }
        for row in needed where rows[row] == nil { rows[row]=horizontalRow(row) }
    }
    func rgb(x:Int,y:Int)->SIMD3<Double>? {
        guard frame.isValid,x>=0,x<frame.width,y>=0,y<frame.height else { return nil }
        beginRow(y)
        var result=SIMD3<Double>.zero
        for dy in -1...1 {
            let row=min(frame.height-1,max(0,y+dy))
            guard let data=rows[row],data.valid[x] else { return nil }
            result+=data.rgb[x]*WaveformSignalFilter.verticalCoefficients[dy+1]
        }
        return result
    }
    private func horizontalRow(_ y:Int)->Row {
        var normalized=[SIMD3<Double>](repeating:.zero,count:frame.width),valid=[Bool](repeating:false,count:frame.width)
        for x in 0..<frame.width {
            let i=(y*frame.width+x)*4,raw=SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2]))
            guard raw.x.isFinite,raw.y.isFinite,raw.z.isFinite else { continue }
            normalized[x]=SIMD3(ColorMath.normalize(raw.x,levels:levels),ColorMath.normalize(raw.y,levels:levels),ColorMath.normalize(raw.z,levels:levels));valid[x]=true
        }
        var output=Row(rgb:[SIMD3<Double>](repeating:.zero,count:frame.width),valid:[Bool](repeating:false,count:frame.width))
        for x in 0..<frame.width {
            var rgb=SIMD3<Double>.zero,admitted=true
            for dx in -3...3 {
                let sx=min(frame.width-1,max(0,x+dx))
                if !valid[sx] { admitted=false;break }
                rgb+=normalized[sx]*WaveformSignalFilter.horizontalCoefficients[dx+3]
            }
            if admitted { output.rgb[x]=rgb;output.valid[x]=true }
        }
        return output
    }
}
