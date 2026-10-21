import Foundation

public struct CIERenderStatistics:Equatable,Sendable {
    public var selectedRGBCount=0,invalidRGBCount=0,invalidXYZCount=0,storedSampleCount=0
    public var validChromaticityCount=0,blackCount=0,singularCount=0,invalidChromaticityCount=0
    public var negativeXYZCount=0,extremeCoordinateCount=0,insideViewportCount=0,outsideViewportCount=0
    public var outsideTargetCount=0,unclassifiedTargetCount=0
    public var targetClassifiedCount:Int { max(0,validChromaticityCount-unclassifiedTargetCount) }
    public var outsideTargetPercent:Double { targetClassifiedCount>0 ? Double(outsideTargetCount)/Double(targetClassifiedCount)*100:0 }
    public init() {}
}
public struct CIEDirectionGlyph:Equatable,Sendable {
    /// Physical xy/u′v′. A deterministic representative of one 12×8 viewport
    /// cell; count includes all outside-target samples assigned to that cell.
    public let point:SIMD2<Double>
    public let boundary:SIMD2<Double>
    public let outward:SIMD2<Double>
    public let count:Int
}
public struct CIERenderResult:Sendable {
    public let bitmap:ScopeBitmap
    public let statistics:CIERenderStatistics
    public let directions:[CIEDirectionGlyph]
    public let error:String?
}

/// Original density renderer. All stored chromaticities contribute to counts;
/// every visible sample contributes to its pixel, with no additional thinning.
/// Direction glyphs aggregate by a fixed 12×8 viewport grid, not one arrow/pixel.
public enum CIERenderer {
    public static func render(trace:CIETrace,mode:CIEPlotMode,viewport:CIEViewport,settings:CIEPlotSettings=CIEPlotSettings(),gain:Double=1,width:Int=320,height:Int=320)->CIERenderResult {
        let sizeValid=(1...1024).contains(width) && (1...1024).contains(height)
        let w=sizeValid ? width:1,h=sizeValid ? height:1
        var bytes=[UInt8](repeating:0,count:w*h*4)
        for i in stride(from:3,to:bytes.count,by:4) { bytes[i]=255 }
        var stats=CIERenderStatistics()
        stats.selectedRGBCount=trace.selectedRGBCount;stats.invalidRGBCount=trace.invalidRGBCount
        stats.invalidXYZCount=trace.invalidXYZCount;stats.storedSampleCount=trace.samples.count
        func result(_ error:String?,_ directions:[CIEDirectionGlyph]=[])->CIERenderResult {
            .init(bitmap:ScopeBitmap(width:w,height:h,rgba:bytes),statistics:stats,directions:directions,error:error)
        }
        guard sizeValid else { return result("CIE raster dimensions must be within 1...1024.") }
        guard viewport.isValid else { return result("Invalid CIE viewport range.") }
        if let error=trace.error { return result(error) }
        if !trace.sourceTriangleXY.isEmpty {
            let source=CIEChromaticityDefinition(name:trace.sourceName,triangleXY:trace.sourceTriangleXY,whiteXY:trace.sourceWhiteXY,whiteName:trace.sourceWhiteName)
            guard source.triangle(mode:mode) != nil else { return result("소스 gamut이 선택 좌표의 특이점을 지나거나 정의되지 않습니다. xy 좌표를 사용하세요.") }
        }
        let target:[SIMD2<Double>]
        do {
            let definition=try settings.targetDefinition()
            guard let triangle=definition.triangle(mode:mode),validTriangle(triangle) else { return result("목표 gamut이 선택 좌표의 특이점을 지나거나 정의되지 않습니다. xy 좌표를 사용하세요.") }
            target=triangle
        } catch { return result(error.localizedDescription) }
        let orientation=(target[1].x-target[0].x)*(target[2].y-target[0].y)-(target[1].y-target[0].y)*(target[2].x-target[0].x)
        let sign=orientation>0 ? 1.0:-1.0
        let edges=(0..<3).map { i->(start:SIMD2<Double>,normal:SIMD2<Double>) in
            let edge=target[(i+1)%3]-target[i],length=hypot(edge.x,edge.y)
            return (target[i],sign*SIMD2(-edge.y/length,edge.x/length))
        }
        var counts=[UInt32](repeating:0,count:w*h),colors=[SIMD3<Double>](repeating:.zero,count:w*h)
        var cells:[Int:(point:SIMD2<Double>,boundary:SIMD2<Double>,outward:SIMD2<Double>,count:Int)]=[:]
        for sample in trace.samples {
            let xyz=sample.xyz
            guard finite(xyz) else { stats.invalidXYZCount += 1;continue }
            if xyz.x<0 || xyz.y<0 || xyz.z<0 { stats.negativeXYZCount += 1 }
            if xyz == .zero { stats.blackCount += 1;continue }
            let scale=max(abs(xyz.x),max(abs(xyz.y),abs(xyz.z))),s=xyz/scale
            let denominator=mode == .xy1931 ? s.x+s.y+s.z:s.x+15*s.y+3*s.z
            if denominator==0 { stats.singularCount += 1;continue }
            guard let point=mode.coordinates(fromXYZ:xyz) else { stats.invalidChromaticityCount += 1;continue }
            stats.validChromaticityCount += 1
            let outside=isOutside(point,edges:edges)
            if let outside { if outside { stats.outsideTargetCount += 1 } }
            else { stats.unclassifiedTargetCount += 1 }
            let extreme=max(abs(point.x),abs(point.y))>CIEViewport.maximumMagnitude
            if extreme { stats.extremeCoordinateCount += 1 }
            guard !extreme,let p=viewport.normalized(point),(0...1).contains(p.x),(0...1).contains(p.y) else { stats.outsideViewportCount += 1;continue }
            stats.insideViewportCount += 1
            let x=Int(p.x*Double(w-1)),y=Int((1-p.y)*Double(h-1)),index=y*w+x
            var tint=SIMD3(safeColor(sample.color.x),safeColor(sample.color.y),safeColor(sample.color.z))
            if settings.gamutErrorCheck,outside == true { tint=SIMD3(repeating:1)-tint }
            counts[index] += 1;colors[index] += tint
            if settings.showDirections,outside == true {
                let key=min(7,Int(p.y*8))*12+min(11,Int(p.x*12))
                if let old=cells[key] { cells[key]=(old.point,old.boundary,old.outward,old.count+1) }
                else if let direction=nearestDirection(point,triangle:target) { cells[key]=(point,direction.boundary,direction.outward,1) }
            }
        }
        let g=gain.isFinite ? min(20,max(0.05,gain)):1
        for i in counts.indices where counts[i]>0 {
            let density=min(1,log1p(Double(counts[i]))*0.24*g),color=colors[i]/Double(counts[i])
            for c in 0..<3 { bytes[i*4+c]=UInt8((min(1,max(0,color[c]*density))*255).rounded()) }
        }
        let glyphs=cells.keys.sorted().compactMap { key->CIEDirectionGlyph? in
            guard let cell=cells[key] else { return nil }
            return .init(point:cell.point,boundary:cell.boundary,outward:cell.outward,count:cell.count)
        }
        return result(nil,glyphs)
    }
    private static func safeColor(_ value:Float)->Double { value.isFinite ? min(1,max(0,Double(value))):0 }
    private static func finite(_ value:SIMD3<Double>)->Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
    private static func validTriangle(_ t:[SIMD2<Double>])->Bool {
        guard t.count==3,t.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=1e6 && abs($0.y)<=1e6}) else { return false }
        let a=t[1]-t[0],b=t[2]-t[0],scale=max(abs(a.x),abs(a.y),abs(b.x),abs(b.y))
        guard scale>0 else { return false };let u=a/scale,v=b/scale
        return abs(u.x*v.y-u.y*v.x)>1e-14
    }
    /// Scale the point before half-plane tests, so huge finite coordinates are
    /// classified rather than misreported as inside when direction math omits them.
    private static func isOutside(_ point:SIMD2<Double>,edges:[(start:SIMD2<Double>,normal:SIMD2<Double>)])->Bool? {
        guard point.x.isFinite,point.y.isFinite else { return nil }
        let scale=max(1,abs(point.x),abs(point.y))
        for edge in edges {
            let delta=point/scale-edge.start/scale
            let signed=edge.normal.x*delta.x+edge.normal.y*delta.y
            if signed < -1e-12/scale { return true }
        }
        return false
    }
    private static func nearestDirection(_ point:SIMD2<Double>,triangle:[SIMD2<Double>])->(boundary:SIMD2<Double>,outward:SIMD2<Double>)? {
        var nearest=triangle[0],distance=Double.infinity
        for i in 0..<3 {
            let a=triangle[i],edge=triangle[(i+1)%3]-a,length2=edge.x*edge.x+edge.y*edge.y
            guard length2>0 else { return nil }
            let delta=point-a,t=min(1,max(0,(delta.x*edge.x+delta.y*edge.y)/length2)),candidate=a+t*edge
            let d=hypot(point.x-candidate.x,point.y-candidate.y)
            if d<distance { distance=d;nearest=candidate }
        }
        guard distance.isFinite,distance>0 else { return nil }
        return (nearest,(point-nearest)/distance)
    }
}
