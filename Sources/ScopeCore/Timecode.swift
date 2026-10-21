import Foundation

public enum TimecodeMode: String, Codable, CaseIterable, Sendable {
    case nonDropFrame = "NDF"
    case dropFrame = "DF"
}

/// Exact rational rate for textual full-frame timecode arithmetic. Integer
/// rates 1...240 and 24000/1001, 30000/1001, 48000/1001, 60000/1001,
/// 120000/1001 are supported. This is a full-frame TEXTUAL convention and
/// does not decode SMPTE LTC/VITC binary frame-pair/field bits above 30 fps.
public struct FrameRate: Codable, Equatable, Hashable, Sendable {
    public let numerator: Int
    public let denominator: Int
    public var framesPerSecond: Double { Double(numerator)/Double(denominator) }
    public var nominalFPS: Int { denominator == 1 ? numerator : numerator/1000 }
    public var supportsDropFrame: Bool { denominator == 1001 && (numerator == 30000 || numerator == 60000) }
    public init?(numerator: Int, denominator: Int = 1) {
        guard numerator > 0, denominator > 0 else { return nil }
        var a=numerator, b=denominator
        while b != 0 { let remainder=a%b; a=b; b=remainder }
        let n=numerator/a, d=denominator/a
        guard (d == 1 && (1...240).contains(n)) || (d == 1001 && [24000,30000,48000,60000,120000].contains(n)) else { return nil }
        self.numerator=n; self.denominator=d
    }
    /// Number of actual full frames in a 24-hour LABEL cycle, not necessarily
    /// the number of frames in 86400 SI seconds at a fractional rate.
    public func framesPer24Hours(mode: TimecodeMode) -> Int64? {
        guard mode != .dropFrame || supportsDropFrame else { return nil }
        let nominal=Int64(nominalFPS)*86400
        return mode == .dropFrame ? nominal-Int64(dropCount)*1296 : nominal
    }
    fileprivate var dropCount: Int { nominalFPS == 60 ? 4 : 2 }

    /// Recognized Resolve display aliases are exact: 23.976/23.98 denote
    /// 24000/1001, 29.97 denotes 30000/1001, 47.952 denotes 48000/1001,
    /// 59.94 denotes 60000/1001, 119.88 denotes 120000/1001.
    /// Integer decimal forms (24.000), supported rational forms, and optional
    /// DF/NDF suffixes are accepted. No nearest-rate rounding is performed.
    /// An absent suffix stays nil: a fractional FPS alone does not imply DF.
    public static func parseResolve(_ literal: String) -> ParsedFrameRate? {
        guard literal.utf8.count <= 128 else { return nil }
        var text=literal.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        var mode: TimecodeMode?
        if text.hasSuffix("NDF") { mode = .nonDropFrame; text=String(text.dropLast(3)).trimmingCharacters(in:.whitespaces) }
        else if text.hasSuffix("DF") { mode = .dropFrame; text=String(text.dropLast(2)).trimmingCharacters(in:.whitespaces) }
        guard !text.isEmpty else { return nil }
        let rate: FrameRate?
        let fraction=text.split(separator:"/",omittingEmptySubsequences:false)
        if fraction.count == 2 {
            guard let n=decimalInteger(fraction[0]),let d=decimalInteger(fraction[1]) else { return nil }
            rate=FrameRate(numerator:n,denominator:d)
        } else if fraction.count == 1 {
            let decimal=text.split(separator:".",omittingEmptySubsequences:false)
            guard decimal.count <= 2,let whole=decimalInteger(decimal[0]) else { return nil }
            if decimal.count == 1 { rate=FrameRate(numerator:whole) }
            else {
                guard !decimal[1].isEmpty,decimal[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
                var tail=String(decimal[1]); while tail.last == "0" { tail.removeLast() }
                if tail.isEmpty { rate=FrameRate(numerator:whole) }
                else {
                    switch "\(whole).\(tail)" {
                    case "23.976", "23.98": rate=FrameRate(numerator:24000,denominator:1001)
                    case "29.97": rate=FrameRate(numerator:30000,denominator:1001)
                    case "47.952": rate=FrameRate(numerator:48000,denominator:1001)
                    case "59.94": rate=FrameRate(numerator:60000,denominator:1001)
                    case "119.88": rate=FrameRate(numerator:120000,denominator:1001)
                    default: return nil
                    }
                }
            }
        } else { return nil }
        guard let rate, mode != .dropFrame || rate.supportsDropFrame else { return nil }
        return ParsedFrameRate(rate:rate,explicitMode:mode,literal:literal)
    }
    private enum CodingKeys: String, CodingKey { case numerator,denominator }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let n=try c.decode(Int.self,forKey:.numerator),d=try c.decode(Int.self,forKey:.denominator)
        guard let value=FrameRate(numerator:n,denominator:d) else { throw DecodingError.dataCorruptedError(forKey:.numerator,in:c,debugDescription:"Unsupported or invalid rational frame rate") }
        self=value
    }
}

public struct ParsedFrameRate: Equatable, Sendable {
    public let rate: FrameRate
    public let explicitMode: TimecodeMode?
    /// Unmodified host metadata, including display precision and suffix.
    public let literal: String
}

/// Validated HH:MM:SS:FF or HH:MM:SS;FF using full frame numbers. For
/// nominal rates >=100, frames use a three-digit FFF field canonically. Labels
/// identify frames, not wall-clock seconds. At 59.94 this API uses FF=0...59;
/// it does NOT interpret binary LTC frame pairs or infer field phase.
/// Independent integer math follows SMPTE ST12-1 §5.2.2 and EG35 §2.1:
/// https://pub.smpte.org/pub/st12-1/st0012-1-2014.pdf
/// https://pub.smpte.org/latest/eg35/eg0035-2012.pdf
public struct SMPTETimecode: Equatable, Sendable {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int
    public let rate: FrameRate
    public let mode: TimecodeMode
    /// Present only when parsed; the unmodified Resolve literal remains
    /// available even when canonical formatting uses a different separator.
    public let hostLiteral: String?
    public init?(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: FrameRate, mode: TimecodeMode) {
        self.init(hours:hours,minutes:minutes,seconds:seconds,frames:frames,rate:rate,mode:mode,hostLiteral:nil)
    }
    private init?(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: FrameRate, mode: TimecodeMode, hostLiteral: String?) {
        guard (0..<24).contains(hours),(0..<60).contains(minutes),(0..<60).contains(seconds),(0..<rate.nominalFPS).contains(frames),mode != .dropFrame || rate.supportsDropFrame else { return nil }
        if mode == .dropFrame && minutes%10 != 0 && seconds == 0 && frames < rate.dropCount { return nil }
        self.hours=hours;self.minutes=minutes;self.seconds=seconds;self.frames=frames;self.rate=rate;self.mode=mode;self.hostLiteral=hostLiteral
    }
    public var formatted: String {
        String(format:"%02d:%02d:%02d%@",hours,minutes,seconds,mode == .dropFrame ? ";":":") + String(format:rate.nominalFPS >= 100 ? "%03d":"%02d",frames)
    }
    /// Actual full-frame index relative to the start of this label cycle.
    public var frameIndex: Int64 {
        let totalMinutes=hours*60+minutes
        let nominal=((Int64(hours)*3600+Int64(minutes)*60+Int64(seconds))*Int64(rate.nominalFPS))+Int64(frames)
        return mode == .dropFrame ? nominal-Int64(rate.dropCount*(totalMinutes-totalMinutes/10)) : nominal
    }
    /// Semicolon explicitly requests DF. Colon defaults to NDF only when no
    /// authoritative host mode is supplied; Resolve may use colon with its DF
    /// setting enabled. An explicit NDF mode conflicts with semicolon and fails.
    /// Syntax is 11 ASCII characters, or 11/12 at nominal rates >=100
    /// (two/three frame digits), after optional outer whitespace. High rates
    /// use full-frame textual indices, not binary SMPTE/LTC frame-pair encoding.
    public static func parse(_ literal: String, rate: FrameRate, mode: TimecodeMode? = nil) -> SMPTETimecode? {
        guard literal.utf8.count <= 128 else { return nil }
        let bytes=Array(literal.trimmingCharacters(in:.whitespacesAndNewlines).utf8)
        let allowedLength = bytes.count == 11 || (rate.nominalFPS >= 100 && bytes.count == 12)
        guard allowedLength,bytes[2] == 58,bytes[5] == 58,(bytes[8] == 58 || bytes[8] == 59) else { return nil }
        let indices=[0,1,3,4,6,7] + Array(9..<bytes.count)
        guard indices.allSatisfy({ bytes[$0] >= 48 && bytes[$0] <= 57 }) else { return nil }
        if bytes[8] == 59 && mode == .nonDropFrame { return nil }
        let resolvedMode=mode ?? (bytes[8] == 59 ? .dropFrame:.nonDropFrame)
        func pair(_ index: Int) -> Int { Int(bytes[index]-48)*10+Int(bytes[index+1]-48) }
        let frame=bytes[9...].reduce(0) { $0*10+Int($1-48) }
        return SMPTETimecode(hours:pair(0),minutes:pair(3),seconds:pair(6),frames:frame,rate:rate,mode:resolvedMode,hostLiteral:literal)
    }
    /// Negative indices always fail. Positive counts wrap only when requested;
    /// integer modulo precedes all arithmetic, so Int64.max cannot overflow.
    public static func from(frameIndex: Int64, rate: FrameRate, mode: TimecodeMode, wrap24Hours: Bool = true) -> SMPTETimecode? {
        guard frameIndex >= 0,let cycle=rate.framesPer24Hours(mode:mode),wrap24Hours || frameIndex < cycle else { return nil }
        let index=frameIndex%cycle, fps=Int64(rate.nominalFPS)
        if mode == .nonDropFrame {
            let totalSeconds=index/fps
            return SMPTETimecode(hours:Int(totalSeconds/3600),minutes:Int(totalSeconds/60%60),seconds:Int(totalSeconds%60),frames:Int(index%fps),rate:rate,mode:mode)
        }
        // Each ten-minute block starts with a full minute; the next nine
        // minutes omit two labels (four full-frame labels at 59.94).
        let drop=Int64(rate.dropCount), fullMinute=fps*60, shortMinute=fullMinute-drop
        let block=fullMinute+shortMinute*9, blockIndex=index/block, remainder=index%block
        let minuteInBlock: Int64, labelFrame: Int64
        if remainder < fullMinute { minuteInBlock=0;labelFrame=remainder }
        else { let shortOffset=remainder-fullMinute;minuteInBlock=1+shortOffset/shortMinute;labelFrame=shortOffset%shortMinute+drop }
        let totalMinutes=blockIndex*10+minuteInBlock
        return SMPTETimecode(hours:Int(totalMinutes/60),minutes:Int(totalMinutes%60),seconds:Int(labelFrame/fps),frames:Int(labelFrame%fps),rate:rate,mode:mode)
    }
    /// Accepts an explicitly documented frame-count numeric field ONLY. Never
    /// apply this to arbitrary OFX time (which may mean seconds or frames).
    /// Fractions, negative, nonfinite, and values outside Int64 are rejected.
    public static func wholeFrameIndex(_ value: Double) -> Int64? {
        guard value.isFinite,value >= 0 else { return nil }
        return Int64(exactly:value)
    }
}

private func decimalInteger(_ value: Substring) -> Int? {
    guard !value.isEmpty,value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    return Int(value)
}

/// A label associated with the pixels of one captured/rendered frame. A sender
/// mapping is an explicit operator assertion: OFX action time alone never proves
/// a Resolve timeline position. Context identifies that assertion, not a host query.
public struct FrameTimecode: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case senderMapping, verifiedStillCapture }
    public let rate: FrameRate
    public let mode: TimecodeMode
    public let frameIndex: Int64
    public let source: Source
    public let contextID: String
    public let senderID: String?
    public let hostLiteral: String?
    public let anchorEffectTime: Double?
    public let anchorFrameIndex: Int64?
    public var timecode: SMPTETimecode { SMPTETimecode.from(frameIndex:frameIndex,rate:rate,mode:mode)! }
    public var formatted: String { timecode.formatted }
    public init?(rate:FrameRate, mode:TimecodeMode, frameIndex:Int64, source:Source,
                 contextID:String, senderID:String?=nil, hostLiteral:String?=nil,
                 anchorEffectTime:Double?=nil, anchorFrameIndex:Int64?=nil) {
        func valid(_ s:String)->Bool { !s.isEmpty && s.utf8.count<=1024 && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        guard SMPTETimecode.from(frameIndex:frameIndex,rate:rate,mode:mode) != nil,
              valid(contextID),senderID.map(valid) ?? true,hostLiteral.map(valid) ?? true else { return nil }
        if let hostLiteral { guard SMPTETimecode.parse(hostLiteral,rate:rate,mode:mode)?.frameIndex == timecodeIndex(frameIndex,rate:rate,mode:mode) else { return nil } }
        if source == .senderMapping {
            guard let anchorEffectTime,anchorEffectTime.isFinite,abs(anchorEffectTime)<=9_007_199_254_740_991,
                  let anchorFrameIndex,anchorFrameIndex>=0,senderID != nil else { return nil }
        } else if anchorEffectTime != nil || anchorFrameIndex != nil { return nil }
        self.rate=rate;self.mode=mode;self.frameIndex=frameIndex;self.source=source
        self.contextID=contextID;self.senderID=senderID;self.hostLiteral=hostLiteral
        self.anchorEffectTime=anchorEffectTime;self.anchorFrameIndex=anchorFrameIndex
    }
    /// One unit of OFX action time must explicitly mean one full frame. Reject
    /// fractional/subframe actions and unsafe integer precision; never round.
    public static func mapped(effectTime:Double,rate:FrameRate,mode:TimecodeMode,
                              anchorEffectTime:Double,anchorFrameIndex:Int64,
                              contextID:String,senderID:String)->FrameTimecode? {
        guard effectTime.isFinite,anchorEffectTime.isFinite,
              abs(effectTime)<=9_007_199_254_740_991,abs(anchorEffectTime)<=9_007_199_254_740_991,
              let delta=Int64(exactly:effectTime-anchorEffectTime) else { return nil }
        let (index,overflow)=anchorFrameIndex.addingReportingOverflow(delta)
        guard !overflow else { return nil }
        return FrameTimecode(rate:rate,mode:mode,frameIndex:index,source:.senderMapping,
            contextID:contextID,senderID:senderID,anchorEffectTime:anchorEffectTime,anchorFrameIndex:anchorFrameIndex)
    }
    private enum CodingKeys:String,CodingKey { case rate,mode,frameIndex,source,contextID,senderID,hostLiteral,anchorEffectTime,anchorFrameIndex }
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        guard let value=FrameTimecode(rate:try c.decode(FrameRate.self,forKey:.rate),mode:try c.decode(TimecodeMode.self,forKey:.mode),
            frameIndex:try c.decode(Int64.self,forKey:.frameIndex),source:try c.decode(Source.self,forKey:.source),
            contextID:try c.decode(String.self,forKey:.contextID),senderID:try c.decodeIfPresent(String.self,forKey:.senderID),
            hostLiteral:try c.decodeIfPresent(String.self,forKey:.hostLiteral),anchorEffectTime:try c.decodeIfPresent(Double.self,forKey:.anchorEffectTime),
            anchorFrameIndex:try c.decodeIfPresent(Int64.self,forKey:.anchorFrameIndex)) else {
            throw DecodingError.dataCorruptedError(forKey:.frameIndex,in:c,debugDescription:"Invalid frame-associated timecode")
        }
        self=value
    }
}
private func timecodeIndex(_ index:Int64,rate:FrameRate,mode:TimecodeMode)->Int64? {
    rate.framesPer24Hours(mode:mode).map { index % $0 }
}
