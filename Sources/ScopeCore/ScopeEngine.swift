import Foundation

private func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
private func byte(_ v: Double) -> UInt8 { UInt8((unit(v)*255).rounded()) }
private func finiteFloat(_ v: Double) -> Float { Float(min(max(v,-Double(Float.greatestFiniteMagnitude)),Double(Float.greatestFiniteMagnitude))) }

private struct DensityPlot {
    let width: Int; let height: Int
    var counts: [UInt32]
    var colors: [SIMD3<Float>]
    init(_ width: Int, _ height: Int) {
        self.width = width; self.height = height
        counts = .init(repeating: 0, count: width*height)
        colors = .init(repeating: .zero, count: width*height)
    }
    mutating func add(x: Double, y: Double, color: SIMD3<Float>) {
        guard x.isFinite && y.isFinite else { return }
        let px = Int(unit(x)*Double(width-1)), py = Int((1-unit(y))*Double(height-1)), index = py*width+px
        counts[index] += 1; colors[index] += color
    }
    func bitmap(gain: Double) -> ScopeBitmap {
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        let gain = max(0.05,min(gain.isFinite ? gain : 1, 20))
        for i in counts.indices {
            bytes[i*4+3] = 255
            guard counts[i] > 0 else { continue }
            let density = min(1, log1p(Double(counts[i])) * 0.24 * gain)
            let avg = colors[i] / Float(counts[i])
            bytes[i*4] = byte(Double(avg.x)*density)
            bytes[i*4+1] = byte(Double(avg.y)*density)
            bytes[i*4+2] = byte(Double(avg.z)*density)
        }
        return ScopeBitmap(width: width, height: height, rgba: bytes)
    }
}

/// CPU reference scope engine. Plots and reported statistics sample a grid of at
/// most the selected 320×180, 640×360, or 960×540 ROI grid. The preview/false color are capped at 960×540.
/// Waveform/histogram use encoded R'G'B'/Y'; CIE and nit statistics use the EOTF.
public enum ScopeEngine {
    /// Distribution arrays and the legacy CIE raster can be omitted by clients
    /// that never present them. Signal statistics and waveform peaks are unchanged.
    public static func analyze(frame: VideoFrame, settings: ScopeSettings = ScopeSettings(), falseColorMapping: FalseColorMapping = .defaultIRE, selectionMask: ScopeSelectionMask? = nil, waveform: WaveformSettings = .init(), renderLegacyPlots:Bool = true, cie:CIEPlotSettings = .init(), collectCIETrace:Bool = true, renderLegacyCIE:Bool = true, collectDistributions:Bool = true, rasterizeWaveforms:Bool = true,rasterizeFalseColor:Bool = true,falseColorZone:Double?=nil,presentation:FalseColorPresentation?=nil) -> ScopeResult {
        let started = ProcessInfo.processInfo.systemUptime
        var paradeOptions=WaveformSettings();paradeOptions.mode = .rgbParade;paradeOptions.trueRGBColors=true
        var wave=WaveformRenderer(settings:waveform,levels:settings.levels,rasterize:rasterizeWaveforms)
        var parade=WaveformRenderer(settings:paradeOptions,levels:settings.levels,width:1536,height:512,rasterize:rasterizeWaveforms)
        let waveFilter=waveform.signalLowPass && frame.isValid ? WaveformSignalSampler(frame:frame,levels:settings.levels):nil
        var vector = DensityPlot(renderLegacyPlots ? 320:1,renderLegacyPlots ? 320:1), legacyCIE = DensityPlot(renderLegacyCIE ? 320:1,renderLegacyCIE ? 320:1)
        var hr = [UInt32](repeating: 0, count: 256), hg = hr, hb = hr, hy = hr, hh = hr, hs = hr
        var cube = [SIMD3<Float>]()
        var traceSamples=[CIETraceSample](),traceSelected=0,traceInvalidRGB=0,traceInvalidXYZ=0
        var traceDefinition:CIEChromaticityDefinition?,traceError:String?
        if collectCIETrace {
            do { traceDefinition=try cie.sourceDefinition(measurementSpace:settings.colorSpace) }
            catch { traceError=error.localizedDescription }
        }
        var stats = ScopeStatistics()
        let preview = makePreview(frame: frame, settings: settings, mapping:falseColorMapping, selection:selectionMask,renderFalseColor:rasterizeFalseColor,zone:falseColorZone,presentation:presentation)
        var minRGB = SIMD3<Double>(repeating: .infinity), maxRGB = SIMD3<Double>(repeating: -.infinity), sumRGB = SIMD3<Double>.zero
        var minY = Double.infinity, maxY = -Double.infinity, sumY = 0.0, minNits = Double.infinity, maxNits = -Double.infinity, sumNits = 0.0
        var below = 0, above = 0, gamut = 0
        if frame.isValid {
            let roiRaster=settings.roiGeometry.raster(width:frame.width,height:frame.height)
            let bounds = roiRaster.bounds
            let targetWidth = min(960,max(160,settings.sampleWidth)), targetHeight = targetWidth*9/16
            let xStep = max(1, Int(ceil(Double(bounds.x1-bounds.x0)/Double(targetWidth)))), yStep = max(1, Int(ceil(Double(bounds.y1-bounds.y0)/Double(targetHeight))))
            if bounds.x1 > bounds.x0 && bounds.y1 > bounds.y0 {
                for y in stride(from: bounds.y0, to: bounds.y1, by: yStep) {
                    wave.beginRow()
                    var lastWaveX:Int?
                    for x in stride(from: bounds.x0, to: bounds.x1, by: xStep) {
                        guard roiRaster.contains(x:x,y:y) else { wave.breakContinuity();lastWaveX=nil;continue }
                        if let selectionMask, !selectionMask.includes(x:x,y:y,frameWidth:frame.width,frameHeight:frame.height) { wave.breakContinuity();lastWaveX=nil;continue }
                        if collectCIETrace { traceSelected += 1 }
                        let offset = (y*frame.width+x)*4
                        let raw = SIMD3(Double(frame.rgba[offset]),Double(frame.rgba[offset+1]),Double(frame.rgba[offset+2]))
                        guard raw.x.isFinite && raw.y.isFinite && raw.z.isFinite else { stats.invalidPixels += 1;if collectCIETrace { traceInvalidRGB += 1 };wave.breakContinuity();lastWaveX=nil;continue }
                        let rgb = SIMD3(ColorMath.normalize(raw.x,levels: settings.levels),ColorMath.normalize(raw.y,levels: settings.levels),ColorMath.normalize(raw.z,levels: settings.levels))
                        let luma = ColorMath.luma(rgb,space: settings.colorSpace)
                        let nits = ColorMath.luminanceNits(rgb,space: settings.colorSpace,transfer: settings.transfer)
                        stats.sampleCount += 1
                        minRGB = SIMD3(min(minRGB.x,rgb.x),min(minRGB.y,rgb.y),min(minRGB.z,rgb.z))
                        maxRGB = SIMD3(max(maxRGB.x,rgb.x),max(maxRGB.y,rgb.y),max(maxRGB.z,rgb.z))
                        sumRGB += rgb; minY = min(minY,luma); maxY = max(maxY,luma); sumY += luma
                        minNits = min(minNits,nits); maxNits = max(maxNits,nits); sumNits += nits
                        let low = min(rgb.x,min(rgb.y,rgb.z)), high = max(rgb.x,max(rgb.y,rgb.z))
                        if low < 0 { below += 1 }; if high > 1 { above += 1 }; if low < 0 || high > 1 { gamut += 1 }
                        let horizontal = Double(x-bounds.x0)/Double(max(1,bounds.x1-bounds.x0-1))
                        let waveformRGB:SIMD3<Double>?
                        if let waveFilter { waveformRGB=waveFilter.rgb(x:x,y:y) }
                        else { waveformRGB=rgb }
                        if let waveformRGB {
                            if waveform.enhancedRender,let previous=lastWaveX,x>previous+1,
                               !waveformGapIsClear(frame:frame,roi:roiRaster,selection:selectionMask,filter:waveFilter,from:previous+1,to:x,y:y) { wave.breakContinuity() }
                            wave.add(rgb:waveformRGB,space:settings.colorSpace,horizontal:horizontal)
                            lastWaveX=x
                        } else {
                            wave.breakContinuity();lastWaveX=nil
                        }
                        if rasterizeWaveforms {parade.add(rgb:rgb,space:settings.colorSpace,horizontal:horizontal)}
                        let color = SIMD3(Float(unit(rgb.x)*0.8+0.2),Float(unit(rgb.y)*0.8+0.2),Float(unit(rgb.z)*0.8+0.2))
                        if collectCIETrace,traceError == nil {
                            if let xyz=cie.sourceXYZ(encodedRGB:rgb,settings:settings) {
                                traceSamples.append(CIETraceSample(xyz:xyz,color:color))
                            } else { traceInvalidXYZ += 1 }
                        }
                        if renderLegacyPlots {
                            let chroma=ColorMath.chroma(rgb,space:settings.colorSpace)
                            let zoom=max(0.1,min(settings.vectorZoom.isFinite ? settings.vectorZoom:1,8))
                            vector.add(x:0.5+chroma.x*0.88*zoom,y:0.5+chroma.y*0.88*zoom,color:color)
                        }
                        if renderLegacyCIE,let coordinate=settings.ciePlotMode.coordinates(encodedRGB:rgb,space:settings.colorSpace,transfer:settings.transfer),
                           let position=settings.ciePlotMode.normalizedCoordinates(coordinate),
                           (0...1).contains(position.x),(0...1).contains(position.y) {
                            legacyCIE.add(x:position.x,y:position.y,color:color)
                        }
                        if collectDistributions {
                        hr[HistogramBins.index(rgb.x) ?? 0] += 1;hg[HistogramBins.index(rgb.y) ?? 0] += 1;hb[HistogramBins.index(rgb.z) ?? 0] += 1;hy[HistogramBins.index(luma) ?? 0] += 1
                        let hsv=ColorQualifier.components(normalizedRGB:rgb,mode:.hsv)
                        // Same clipped HSV definition as the histogram's drag key.
                        // Achromatic hue is undefined and omitted, not placed at red.
                        if let hueBin=HistogramBins.index(hsv.x/360) { hh[hueBin] += 1 }
                        hs[HistogramBins.index(hsv.y) ?? 0] += 1
                        if stats.sampleCount % 20 == 1 { cube.append(SIMD3(finiteFloat(rgb.x),finiteFloat(rgb.y),finiteFloat(rgb.z))) }
                        }
                    }
                }
            }
        }
        if stats.sampleCount > 0 {
            let count = Double(stats.sampleCount)
            stats.minRGB = SIMD3(finiteFloat(minRGB.x),finiteFloat(minRGB.y),finiteFloat(minRGB.z)); stats.maxRGB = SIMD3(finiteFloat(maxRGB.x),finiteFloat(maxRGB.y),finiteFloat(maxRGB.z))
            let mean = sumRGB/count; stats.meanRGB = SIMD3(finiteFloat(mean.x),finiteFloat(mean.y),finiteFloat(mean.z))
            stats.minLuma = finiteFloat(minY); stats.maxLuma = finiteFloat(maxY); stats.meanLuma = finiteFloat(sumY/count)
            stats.minNits = minNits; stats.maxNits = maxNits; stats.meanNits = sumNits/count
            stats.belowBlackPercent = Double(below)/count*100; stats.aboveWhitePercent = Double(above)/count*100; stats.outOfGamutPercent = Double(gamut)/count*100
        }
        let peaks=wave.peaks
        let trace=collectCIETrace ? CIETrace(samples:traceSamples,selectedRGBCount:traceSelected,invalidRGBCount:traceInvalidRGB,invalidXYZCount:traceInvalidXYZ,sourceName:traceDefinition?.name ?? "",sourceTriangleXY:traceDefinition?.triangleXY ?? [],sourceWhiteXY:traceDefinition?.whiteXY ?? .zero,sourceWhiteName:traceDefinition?.whiteName ?? "",error:traceError):nil
        return ScopeResult(source:preview.0,waveform:wave.bitmap(gain:settings.gain),waveformPeaks:peaks,parade:parade.bitmap(gain:settings.gain),vectorscope:vector.bitmap(gain:settings.gain),histogram:renderLegacyPlots ? histogramBitmap(r:hr,g:hg,b:hb):ScopeBitmap(width:1,height:1,rgba:[0,0,0,255]),chromaticity:legacyCIE.bitmap(gain:settings.gain),cieTrace:trace,falseColor:preview.1,histogramR:hr,histogramG:hg,histogramB:hb,histogramY:hy,hueHistogram:hh,saturationHistogram:hs,cubePoints:cube,stats:stats,sequence:frame.sequence,processingMS:(ProcessInfo.processInfo.systemUptime-started)*1000)
    }

    /// Even pixels skipped by the sampled grid can break a connected strip.
    /// This avoids bridging a thin excluded/invalid column hidden between taps.
    private static func waveformGapIsClear(frame:VideoFrame,roi:ScopeROIRasterGeometry,selection:ScopeSelectionMask?,filter:WaveformSignalSampler?,from:Int,to:Int,y:Int)->Bool {
        for x in from..<to {
            guard roi.contains(x:x,y:y),selection?.includes(x:x,y:y,frameWidth:frame.width,frameHeight:frame.height) ?? true else { return false }
            if let filter { guard filter.rgb(x:x,y:y) != nil else { return false } }
            else {
                let i=(y*frame.width+x)*4
                guard frame.rgba[i].isFinite,frame.rgba[i+1].isFinite,frame.rgba[i+2].isFinite else { return false }
            }
        }
        return true
    }

    private static func makePreview(frame: VideoFrame, settings: ScopeSettings, mapping:FalseColorMapping, selection:ScopeSelectionMask?,renderFalseColor:Bool,zone:Double?,presentation:FalseColorPresentation?) -> (ScopeBitmap,ScopeBitmap) {
        guard frame.isValid else { let empty = ScopeBitmap(width:1,height:1,rgba:[0,0,0,255]); return (empty,empty) }
        let scale = min(1,min(960/Double(frame.width),540/Double(frame.height)))
        let width = max(1,Int(Double(frame.width)*scale)), height = max(1,Int(Double(frame.height)*scale))
        var source = [UInt8](repeating:0,count:width*height*4), fc = source
        let display=presentation ?? .init(mode:zone == nil ? .original:.tvLogic,target:zone ?? 55,span:25)
        for y in 0..<height {
            let sy = min(frame.height-1,Int((Double(y)+0.5)*Double(frame.height)/Double(height)))
            for x in 0..<width {
                let sx = min(frame.width-1,Int((Double(x)+0.5)*Double(frame.width)/Double(width))), i = (sy*frame.width+sx)*4, o = (y*width+x)*4
                let r = ColorMath.normalize(Double(frame.rgba[i]),levels:settings.levels), g = ColorMath.normalize(Double(frame.rgba[i+1]),levels:settings.levels), b = ColorMath.normalize(Double(frame.rgba[i+2]),levels:settings.levels)
                source[o+3] = 255; fc[o+3] = 255
                if let selection, !selection.includes(x:sx,y:sy,frameWidth:frame.width,frameHeight:frame.height) { continue }
                if !r.isFinite || !g.isFinite || !b.isFinite { source[o]=255;source[o+2]=255;fc[o]=255;fc[o+2]=255;continue }
                source[o]=byte(r);source[o+1]=byte(g);source[o+2]=byte(b)
                guard renderFalseColor else {continue}
                let c = (display.mode == .original ? mapping.color(forRGB:SIMD3(Double(frame.rgba[i]),Double(frame.rgba[i+1]),Double(frame.rgba[i+2])),settings:settings):display.color(ire:ColorMath.luma(SIMD3(r,g,b),space:settings.colorSpace)*100)).rgba8
                fc[o]=c.x;fc[o+1]=c.y;fc[o+2]=c.z;fc[o+3]=c.w
            }
        }
        return (ScopeBitmap(width:width,height:height,rgba:source),ScopeBitmap(width:width,height:height,rgba:fc))
    }

    private static func histogramBitmap(r:[UInt32],g:[UInt32],b:[UInt32]) -> ScopeBitmap {
        let width = 512, height = 256
        var pixels = [UInt8](repeating:0,count:width*height*4)
        for i in stride(from:3,to:pixels.count,by:4) { pixels[i]=255 }
        let peak = Double(max(r.max() ?? 1,max(g.max() ?? 1,b.max() ?? 1)))
        guard peak > 0 else { return ScopeBitmap(width:width,height:height,rgba:pixels) }
        for (channel,hist) in [r,g,b].enumerated() {
            for bin in 0..<256 where hist[bin] > 0 {
                let h = max(1,Int(log1p(Double(hist[bin]))/log1p(peak)*Double(height-1)))
                for y in (height-h)..<height {
                    for x in (bin*2)...(bin*2+1) { pixels[(y*width+x)*4+channel] = y == height-h ? 255 : 110 }
                }
            }
        }
        return ScopeBitmap(width:width,height:height,rgba:pixels)
    }
}
