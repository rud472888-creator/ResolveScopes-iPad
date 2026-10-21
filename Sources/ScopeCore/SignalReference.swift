import Foundation

public extension ScopeSettings {
    /// Scene exposure cannot determine absolute display luminance without a
    /// rendering/calibration transform. Keep Y×100 as an explicit relative unit.
    var usesSceneReference:Bool {
        transfer.isSceneReferred || (transfer == .linear && (colorSpace == .acesAP0 || colorSpace == .acesAP1))
    }
    var luminanceUnitLabel:String { usesSceneReference ? "Y×100 상대값":"nits" }
    var luminanceReferenceDescription:String {
        if usesSceneReference { return "Scene 상대값: 선형 Y=1을100으로 표시합니다. 절대 nits나 ODT 결과를 나타내지 않습니다." }
        if transfer == .pq { return "PQ ST2084 · Y=1:10000 nits" }
        if transfer == .hlg { return "HLG display · Y=1:1000 nits, γ1.2" }
        return "SDR/Linear 기준 white=100 nits 환산"
    }
}
