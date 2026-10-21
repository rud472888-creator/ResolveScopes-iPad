import Foundation

/// Shared distribution quantization and its visual-drag inverse. Measurement
/// bins are floor(clamp(signal)*255), while 256 visible bars occupy equal widths.
/// Edge bars include under/overrange finite signals. Inclusive key endpoints may
/// also admit a sample exactly on the next bin boundary, matching key semantics.
public enum HistogramBins {
    public static let count=256
    public static func index(_ value:Double)->Int? {
        guard value.isFinite else { return nil }
        return Int(min(1,max(0,value))*255)
    }
    public static func displayRange(bin:Int)->ClosedRange<Double>? {
        guard (0..<count).contains(bin) else { return nil }
        return Double(bin)/Double(count)...Double(bin+1)/Double(count)
    }
    public static func signalRange(displaySelection:ClosedRange<Double>,includeOutOfRange:Bool=false)->ClosedRange<Double>? {
        let a=displaySelection.lowerBound,b=displaySelection.upperBound
        guard a.isFinite,b.isFinite,b>a else { return nil }
        let lower=min(1,max(0,a)),upper=min(1,max(0,b))
        guard upper>lower else { return nil }
        let first=min(255,max(0,Int(floor(lower*256))))
        let last=min(255,max(first,Int(ceil(upper*256))-1))
        let lo=includeOutOfRange && first == 0 ? -Double.greatestFiniteMagnitude:Double(first)/255
        let hi=includeOutOfRange && last == 255 ? Double.greatestFiniteMagnitude:min(1,Double(last+1)/255)
        return lo...hi
    }
}
