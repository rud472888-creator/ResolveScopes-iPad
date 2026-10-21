import Foundation

public enum CompanionPanel: String, Codable, CaseIterable, Sendable, Identifiable {
    case source, waveform, parade, vectorscope, falseColor
    public var id:String { rawValue }
    public var title:String {
        switch self {case .source:return "Source";case .waveform:return "Waveform";case .parade:return "RGB Parade";case .vectorscope:return "Vectorscope";case .falseColor:return "False Color"}
    }
}
public struct CompanionImage: Codable, Sendable {
    public var panel:CompanionPanel
    public var png:Data
    public init(panel:CompanionPanel,png:Data) {self.panel=panel;self.png=png}
}
/// One immutable analysis result. Images, measurements, and TC always travel together.
/// Status-only packets invalidate live display; they must never replace a held frame.
public struct CompanionPacket: Codable, Sendable {
    public var version=1
    public var session:UUID
    public var generation:UInt64
    public var sequence:UInt64
    public var source:String
    public var status:String
    public var isTest:Bool
    public var macHeld:Bool
    public var timecode:String?
    public var timecodeOrigin:String?
    public var dimensions:String
    public var conditions:String
    public var metrics:[String:Double]
    public var images:[CompanionImage]
    public init(session:UUID,generation:UInt64,sequence:UInt64,source:String,status:String,isTest:Bool,macHeld:Bool,timecode:String?=nil,timecodeOrigin:String?=nil,dimensions:String="",conditions:String="",metrics:[String:Double]=[:],images:[CompanionImage]=[]) {
        self.session=session;self.generation=generation;self.sequence=sequence;self.source=source;self.status=status;self.isTest=isTest;self.macHeld=macHeld;self.timecode=timecode;self.timecodeOrigin=timecodeOrigin;self.dimensions=dimensions;self.conditions=conditions;self.metrics=metrics;self.images=images
    }
    public func validate() throws {
        guard version == 1, images.count<=CompanionPanel.allCases.count,
              Set(images.map(\.panel)).count == images.count,
              images.allSatisfy({ !$0.png.isEmpty && $0.png.count<=3_000_000 }),
              metrics.count<=32,metrics.allSatisfy({ $0.key.utf8.count<=64 && $0.value.isFinite }),
              [source,status,dimensions,conditions,timecode ?? "",timecodeOrigin ?? ""].allSatisfy({$0.utf8.count<=2048}) else {throw CompanionError.invalidPacket}
        guard images.isEmpty || Set(images.map(\.panel)) == Set(CompanionPanel.allCases) else {throw CompanionError.invalidPacket}
    }
}
public enum CompanionError: Error, LocalizedError {
    case invalidPacket, invalidKey, oversized, truncated
    public var errorDescription:String? {
        switch self {case .invalidPacket:return "지원하지 않거나 잘못된 프레임입니다.";case .invalidKey:return "연결 키는 32자리 16진수여야 합니다.";case .oversized:return "프레임 크기 제한을 초과했습니다.";case .truncated:return "프레임 전송이 중단되었습니다."}
    }
}
public enum CompanionCodec {
    public static let maximumBytes=16_000_000
    public static func encode(_ packet:CompanionPacket) throws -> Data {
        try packet.validate()
        let body=try JSONEncoder().encode(packet)
        guard body.count<=maximumBytes else {throw CompanionError.oversized}
        var size=UInt32(body.count).bigEndian
        return withUnsafeBytes(of:&size) {Data($0)} + body
    }
    public static func length(_ header:Data) throws -> Int {
        guard header.count == 4 else {throw CompanionError.truncated}
        let length=header.reduce(0) {($0<<8)|Int($1)}
        guard length>0,length<=maximumBytes else {throw CompanionError.oversized}
        return length
    }
    public static func decode(_ body:Data) throws -> CompanionPacket {
        guard body.count<=maximumBytes else {throw CompanionError.oversized}
        let packet=try JSONDecoder().decode(CompanionPacket.self,from:body)
        try packet.validate();return packet
    }
}
/// Used on the iPad; a local Hold never sends control messages to the Mac.
public struct CompanionDisplayBuffer<Value> {
    public private(set) var latest:Value?
    public private(set) var displayed:Value?
    public private(set) var held=false
    public init() {}
    public mutating func receive(_ packet:Value) {latest=packet;if !held {displayed=packet}}
    public mutating func setHeld(_ value:Bool) {held=value;if !value {displayed=latest}}
    public mutating func disconnect() {latest=nil;if !held {displayed=nil}}
}

public typealias CompanionDisplayState = CompanionDisplayBuffer<CompanionPacket>
