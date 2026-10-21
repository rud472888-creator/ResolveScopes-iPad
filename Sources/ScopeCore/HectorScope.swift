import Foundation

public struct HectorScopeSettings: Codable, Equatable, Sendable {
    /// Display budget only, sanitized to 1...16384. Measurement sampling is
    /// controlled separately by ScopeSettings.sampleWidth, ROI and selection.
    public var maximumPoints: Int = 16_384
    public var colorize: Bool = true
    public init(maximumPoints: Int = 16_384, colorize: Bool = true) {
        self.maximumPoints = maximumPoints; self.colorize = colorize
    }
}

public struct HectorScopePoint: Equatable, Sendable {
    /// Unclamped physical encoded-signal components, in Y′, Cb, Cr order.
    /// Not image x/y/luma, not linear-light XYZ, and not absolute luminance.
    public let yCbCr: SIMD3<Double>
    /// Display tint only, in 0...1. Clipping/lifting this tint never changes
    /// physical coordinates. Neutral white tint is used when colorize is off.
    public let displayRGB: SIMD3<Float>
    public init(yCbCr: SIMD3<Double>, displayRGB: SIMD3<Float>) {
        self.yCbCr = yCbCr; self.displayRGB = displayRGB
    }
}

public struct HectorScopeResult: Sendable {
    public let points: [HectorScopePoint]
    /// Valid selected samples on the bounded measurement grid, before display
    /// thinning. This is NOT the number of all selected original-source pixels.
    public let selectedSampleCount: Int
    /// Selected measurement samples containing nonfinite RGB/coordinates.
    public let invalidSampleCount: Int
    public var measuredSampleCount: Int { selectedSampleCount + invalidSampleCount }
    public var displayPointCount: Int { points.count }
    /// True when the measurement grid skips received pixels, regardless of ROI.
    public let sampled: Bool
    public var displaySubsampled: Bool { points.count < selectedSampleCount }
    public let transportDownsampled: Bool
    public let sequence: UInt64
    public let processingMS: Double
}

/// Original Y′/Cb/Cr point cloud implementing the documented signal dimensions
/// of HectorScope. The vendor documentation does not fix the screen-axis order;
/// this implementation explicitly chooses X=Cb, Y=Y′, Z=Cr.
/// https://docs.timeinpixels.com/nobe-omniscope/scopes/hectorscope
public enum HectorScope {
    public static let maximumDisplayPoints = 16_384
    /// Plotting convention only. Excursions remain outside this view box.
    public static let displayAxes = [
        ColorPlotAxis(label: "Cb", minimum: -0.5, maximum: 0.5),
        ColorPlotAxis(label: "Y′", minimum: 0, maximum: 1),
        ColorPlotAxis(label: "Cr", minimum: -0.5, maximum: 0.5)
    ]

    /// Input is raw encoded RGB; video levels are expanded exactly once here.
    /// Y′ uses the current primaries' ColorMath weights. Transfer/EOTF does not
    /// apply to this encoded-signal projection. Rec.601 is not an input option
    /// in the current ColorSpace model and is not silently approximated by 709.
    public static func project(encodedRGB: SIMD3<Double>, settings: ScopeSettings = ScopeSettings(), colorize: Bool = true) -> HectorScopePoint? {
        guard finite(encodedRGB) else { return nil }
        let rgb = SIMD3(ColorMath.normalize(encodedRGB.x, levels: settings.levels),
                        ColorMath.normalize(encodedRGB.y, levels: settings.levels),
                        ColorMath.normalize(encodedRGB.z, levels: settings.levels))
        let y = ColorMath.luma(rgb, space: settings.colorSpace)
        let chroma = ColorMath.chroma(rgb, space: settings.colorSpace)
        let physical = SIMD3(y, chroma.x, chroma.y)
        guard finite(rgb), finite(physical) else { return nil }
        // A small common lift keeps black/neutral points visible on black.
        let tint = colorize ? SIMD3(Float(unit(rgb.x)*0.8+0.2), Float(unit(rgb.y)*0.8+0.2), Float(unit(rgb.z)*0.8+0.2)) : SIMD3(repeating: 1)
        return HectorScopePoint(yCbCr: physical, displayRGB: tint)
    }

    /// Pure affine plotting transform: X=Cb+.5, Y=Y′, Z=Cr+.5.
    /// No clipping, gamut mapping, EOTF or hidden rotation is applied.
    public static func normalizedXYZ(_ yCbCr: SIMD3<Double>) -> SIMD3<Double>? {
        guard finite(yCbCr) else { return nil }
        return SIMD3(yCbCr.y+0.5, yCbCr.x, yCbCr.z+0.5)
    }

    public static func analyze(frame: VideoFrame, settings: ScopeSettings = ScopeSettings(), hector: HectorScopeSettings = HectorScopeSettings(), selectionMask: ScopeSelectionMask? = nil) -> HectorScopeResult {
        let started = ProcessInfo.processInfo.systemUptime
        var valid = 0, invalid = 0, sampled = false
        var points = [HectorScopePoint]()
        let budget = min(maximumDisplayPoints, max(1, hector.maximumPoints))
        if frame.isValid {
            let raster = settings.roiGeometry.raster(width: frame.width, height: frame.height)
            let bounds = raster.bounds
            let width = max(16, min(960, settings.sampleWidth)), height = max(9, width*9/16)
            let xs = max(1, Int(ceil(Double(bounds.width)/Double(width))))
            let ys = max(1, Int(ceil(Double(bounds.height)/Double(height))))
            sampled = xs > 1 || ys > 1
            if bounds.width > 0 && bounds.height > 0 {
                /// Both passes visit identical geometry in deterministic row
                /// order. The second stops after the final desired valid rank.
                func visit(_ body: (HectorScopePoint?) -> Bool) {
                    for y in stride(from: bounds.y0, to: bounds.y1, by: ys) {
                        for x in stride(from: bounds.x0, to: bounds.x1, by: xs) {
                            guard raster.contains(x: x, y: y), selectionMask?.includes(x: x, y: y, frameWidth: frame.width, frameHeight: frame.height) ?? true else { continue }
                            let i = (y*frame.width+x)*4
                            let rgb = SIMD3(Double(frame.rgba[i]), Double(frame.rgba[i+1]), Double(frame.rgba[i+2]))
                            if !body(project(encodedRGB: rgb, settings: settings, colorize: hector.colorize)) { return }
                        }
                    }
                }
                visit { point in
                    if point == nil { invalid += 1 } else { valid += 1 }
                    return true
                }
                let count = min(valid, budget)
                if count > 0 {
                    points.reserveCapacity(count)
                    // Equal-population strata of VALID selected sample ranks,
                    // with one deterministic jittered rank per stratum. This
                    // avoids prefix truncation and a fixed every-N alias pattern.
                    // The seed does not depend on frame sequence, so static
                    // imagery does not flicker as frame metadata changes.
                    func chosenRank(_ stratum: Int) -> Int {
                        let low = stratum*valid/count, high = (stratum+1)*valid/count
                        return low + Int(mix(UInt64(stratum)) % UInt64(high-low))
                    }
                    var rank = 0, stratum = 0, chosen = chosenRank(0)
                    visit { point in
                        guard let point else { return true }
                        if rank == chosen {
                            points.append(point); stratum += 1
                            if stratum == count { return false }
                            chosen = chosenRank(stratum)
                        }
                        rank += 1
                        return true
                    }
                }
            }
        }
        return HectorScopeResult(points: points, selectedSampleCount: valid, invalidSampleCount: invalid, sampled: sampled,
                                 transportDownsampled: frame.width != frame.sourceWidth || frame.height != frame.sourceHeight,
                                 sequence: frame.sequence, processingMS: (ProcessInfo.processInfo.systemUptime-started)*1000)
    }

    private static func finite(_ rgb: SIMD3<Double>) -> Bool { rgb.x.isFinite && rgb.y.isFinite && rgb.z.isFinite }
    private static func unit(_ value: Double) -> Double { min(1, max(0, value)) }
    /// SplitMix64 finalizer with a fixed nonzero offset, solely for sampling.
    private static func mix(_ index: UInt64) -> UInt64 {
        var value = index &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
