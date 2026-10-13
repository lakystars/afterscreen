import Foundation

public enum AfterscreenProtocol {
    public static let version = 11
    public static let bonjourType = "_afterscreen._tcp"
}

public struct PixelSize: Codable, Equatable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
}

public enum LinkKind: String, Codable {
    case thunderbolt, usb, ethernet, wifi, loopback, unsupported

    public var isWired: Bool { self != .wifi && self != .unsupported }
}

/// `tile`: BC7 tiles, moving tiles as BC1
/// `hybrid`: BC7 tiles, moving tiles from a video layer
public enum StreamPath: String, Codable { case tile, hybrid }

public enum VideoCodec: String, Codable { case hevc, h264 }

public struct Hello: Codable, Equatable {
    public var protocolVersion: Int
    public var name: String
    public var model: String
    public var osVersion: String
    /// This Mac's lasting identity, for pairing
    public var senderID: String?
    /// Fresh per connection; proofs cover it
    public var nonce: Data?
    /// The sender keeps a key for this receiver
    /// Else the receiver pairs anew, whatever it kept
    public var paired: Bool?
    /// Kept key failed its proof: pair anew with a code
    public var repair: Bool?

    public init(protocolVersion: Int, name: String, model: String, osVersion: String, senderID: String? = nil, nonce: Data? = nil,
                paired: Bool? = nil, repair: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.senderID = senderID
        self.nonce = nonce
        self.paired = paired
        self.repair = repair
    }
}

/// Receiver's demand before the stream, off a cable
public struct AuthChallenge: Codable, Equatable {
    public enum Mode: String, Codable {
        /// Known sender: prove the kept key
        case paired
        /// Unknown sender: the receiver shows a code
        case pair
    }

    public var mode: Mode
    public var nonce: Data
    /// Pairing only: the receiver's one-time X25519 key
    public var publicKey: Data?

    public init(mode: Mode, nonce: Data, publicKey: Data? = nil) {
        self.mode = mode
        self.nonce = nonce
        self.publicKey = publicKey
    }
}

/// Opens a handover, or answers one: a fresh nonce
public struct HandoverNonce: Codable, Equatable {
    public var nonce: Data

    public init(nonce: Data) {
        self.nonce = nonce
    }
}

/// An HMAC proof, either way
public struct AuthProof: Codable, Equatable {
    public var mac: Data

    public init(mac: Data) {
        self.mac = mac
    }
}

/// Sender's one-time key and its proof of the code
public struct PairConfirm: Codable, Equatable {
    public var publicKey: Data
    public var mac: Data

    public init(publicKey: Data, mac: Data) {
        self.publicKey = publicKey
        self.mac = mac
    }
}

public struct Welcome: Codable, Equatable {
    public var protocolVersion: Int
    public var name: String
    public var modelID: String
    public var marketingName: String
    public var osVersion: String
    public var gpuNames: [String]
    public var panelPixels: PixelSize
    public var panelPoints: PixelSize
    public var hevcDecode: Bool
    public var h264Decode: Bool
    public var bc7: Bool
    /// Hardware HEVC Main10 (10-bit) decode, probed with a 4K stream
    public var hevcMain10Decode: Bool
    /// Plays the sender's sound on its own speakers
    public var audioPlayback: Bool
    /// Per session; the second connection presents it
    /// That connection carries the cursor, clear of queued frames
    public var channelToken: UInt32
    /// This receiver's lasting identity, for pairing
    public var receiverID: String?
    /// Set when the link needs pairing
    public var auth: AuthChallenge?
    /// Panel's physical size in mm; the virtual display reports it
    public var panelMillimeters: PixelSize?
    /// Panel's highest refresh rate; the stream paces to it
    public var refreshHz: Double?
    /// Per session, 128 bits; set by receivers taking handovers
    /// A new connection proves it, never sends it
    public var handoverToken: Data?

    public init(protocolVersion: Int, name: String, modelID: String, marketingName: String, osVersion: String,
                gpuNames: [String], panelPixels: PixelSize, panelPoints: PixelSize,
                hevcDecode: Bool, h264Decode: Bool, bc7: Bool, hevcMain10Decode: Bool = false, audioPlayback: Bool = false,
                channelToken: UInt32 = 0, panelMillimeters: PixelSize? = nil, refreshHz: Double? = nil) {
        self.protocolVersion = protocolVersion
        self.name = name
        self.modelID = modelID
        self.marketingName = marketingName
        self.osVersion = osVersion
        self.gpuNames = gpuNames
        self.panelPixels = panelPixels
        self.panelPoints = panelPoints
        self.hevcDecode = hevcDecode
        self.h264Decode = h264Decode
        self.bc7 = bc7
        self.hevcMain10Decode = hevcMain10Decode
        self.audioPlayback = audioPlayback
        self.channelToken = channelToken
        self.panelMillimeters = panelMillimeters
        self.refreshHz = refreshHz
    }

    /// Stream rate; receivers that report none run at 60
    /// Clamped: a bad peer's 0 or 1000 stalls nothing
    public var frameRate: Double { min(240, max(24, refreshHz ?? 60)) }

    /// Retina panels are driven as HiDPI (points = pixels/2)
    public var isRetina: Bool { panelPixels.width >= panelPoints.width * 2 }
}

/// The hybrid path's video stream
public struct VideoLayer: Codable, Equatable {
    public var codec: VideoCodec
    /// Encoded size; the receiver scales it to the stream
    public var pixels: PixelSize
    public var bitrate: Int
    /// HEVC Main10 from 10-bit 4:2:0; avoids 8-bit gradient banding
    public var tenBit: Bool

    public init(codec: VideoCodec, pixels: PixelSize, bitrate: Int, tenBit: Bool = false) {
        self.codec = codec
        self.pixels = pixels
        self.bitrate = bitrate
        self.tenBit = tenBit
    }
}

public struct StreamConfig: Codable, Equatable {
    public var path: StreamPath
    public var streamPixels: PixelSize
    /// Set on the hybrid path
    public var video: VideoLayer?
    public var linkKind: LinkKind
    /// A quality test stage: generated frames, no virtual display
    public var test: Bool
    /// Frames per second: the receiver's refresh
    public var frameRate: Double

    public init(path: StreamPath, streamPixels: PixelSize, video: VideoLayer?, linkKind: LinkKind, test: Bool = false, frameRate: Double = 60) {
        self.path = path
        self.streamPixels = streamPixels
        self.video = video
        self.linkKind = linkKind
        self.test = test
        self.frameRate = frameRate
    }

}

public struct ReceiverStats: Codable, Equatable {
    public var receivedFPS: Double
    public var displayedFPS: Double
    public var uploadMs: Double
    public var decompressMs: Double
    public var lateFrames: Int
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var gpuPercent: Double
    /// Sound buffered for playback; nil while no sound arrives
    public var audioBufferMs: Double?
    /// Per session; each underrun is an audible gap
    public var audioUnderruns: Int?
    /// Receiver panel's own slider level; a set brightness starts there
    public var panelLevel: Double?
    /// Picture on screen; nil from older receivers
    public var shown: Bool?

    public init(receivedFPS: Double, displayedFPS: Double, uploadMs: Double, decompressMs: Double, lateFrames: Int,
                cpuPercent: Double, memoryBytes: UInt64, gpuPercent: Double, audioBufferMs: Double? = nil,
                audioUnderruns: Int? = nil, panelLevel: Double? = nil, shown: Bool? = nil) {
        self.receivedFPS = receivedFPS
        self.displayedFPS = displayedFPS
        self.uploadMs = uploadMs
        self.decompressMs = decompressMs
        self.lateFrames = lateFrames
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
        self.audioBufferMs = audioBufferMs
        self.audioUnderruns = audioUnderruns
        self.panelLevel = panelLevel
        self.shown = shown
    }
}

/// Sender measurements, once a second
/// Receiver HUD shows the same numbers as the popover
public struct SenderStats: Codable, Equatable {
    public var interface: String?
    public var mtu: Int?
    /// Probe result at session start
    public var capacityGbps: Double?
    public var throughputBitsPerSecond: Double
    public var latencyMs: Double?
    public var jitterMs: Double
    public var retransmitPercent: Double
    public var cableScore: Int?
    public var captureFPS: Double
    public var sentFPS: Double
    public var droppedPerMinute: Int
    public var dirtyPercent: Double
    public var compressionRatio: Double
    public var encodeMs: Double
    /// Tiles shown lossy after the latest frame
    public var lossyTiles: Int
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var gpuPercent: Double
    /// Video bitrate now; a shared link lowers it
    public var videoBitrate: Int?
    /// This second only: the receiver shows the congestion notice
    public var congestionNotice: Bool?

    public init(interface: String?, mtu: Int?, capacityGbps: Double?, throughputBitsPerSecond: Double,
                latencyMs: Double?, jitterMs: Double, retransmitPercent: Double, cableScore: Int?,
                captureFPS: Double, sentFPS: Double, droppedPerMinute: Int, dirtyPercent: Double, compressionRatio: Double,
                encodeMs: Double, lossyTiles: Int, cpuPercent: Double, memoryBytes: UInt64, gpuPercent: Double) {
        self.interface = interface
        self.mtu = mtu
        self.capacityGbps = capacityGbps
        self.throughputBitsPerSecond = throughputBitsPerSecond
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.retransmitPercent = retransmitPercent
        self.cableScore = cableScore
        self.captureFPS = captureFPS
        self.sentFPS = sentFPS
        self.droppedPerMinute = droppedPerMinute
        self.dirtyPercent = dirtyPercent
        self.compressionRatio = compressionRatio
        self.encodeMs = encodeMs
        self.lossyTiles = lossyTiles
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
    }
}

public struct Bye: Codable, Equatable {
    public var reason: String
    /// Stopped by the receiver's user: no automatic reconnect
    public var pause: Bool
    /// Sender reconnects at once over another link or size
    /// Receiver keeps its picture up
    public var relink: Bool
    /// Keys disagree: the sender drops its own, then pairs anew
    public var repair: Bool?

    public init(reason: String, pause: Bool = false, relink: Bool = false, repair: Bool? = nil) {
        self.reason = reason
        self.pause = pause
        self.relink = relink
        self.repair = repair
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decode(String.self, forKey: .reason)
        pause = try c.decodeIfPresent(Bool.self, forKey: .pause) ?? false
        relink = try c.decodeIfPresent(Bool.self, forKey: .relink) ?? false
        repair = try c.decodeIfPresent(Bool.self, forKey: .repair)
    }
}

public struct ProbeResult: Codable, Equatable {
    public var bytes: Int
    public var seconds: Double
    public init(bytes: Int, seconds: Double) {
        self.bytes = bytes
        self.seconds = seconds
    }

    public var gbps: Double { seconds > 0 ? Double(bytes) * 8 / seconds / 1e9 : 0 }
}

public enum JSONWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    public static func message<T: Encodable>(_ type: MessageType, _ value: T) throws -> Message {
        Message(type: type, payload: try encode(value))
    }
}

public struct CursorImage: Equatable {
    /// Size, hotspot: points on sender, stream pixels on wire
    public var width: Int
    public var height: Int
    public var hotX: Int
    public var hotY: Int
    public var png: Data

    public init(width: Int, height: Int, hotX: Int, hotY: Int, png: Data) {
        self.width = width
        self.height = height
        self.hotX = hotX
        self.hotY = hotY
        self.png = png
    }
}

public enum CursorWire {
    /// Normalized 0..1, top-left origin
    public static func pos(x: Float, y: Float, visible: Bool) -> Data {
        var w = ByteWriter(capacity: 9)
        w.f32(x)
        w.f32(y)
        w.u8(visible ? 1 : 0)
        return w.data
    }

    public static func parsePos(_ data: Data) throws -> (x: Float, y: Float, visible: Bool) {
        var r = ByteReader(data)
        return (try r.f32(), try r.f32(), try r.u8() != 0)
    }

    public static func image(width: Int, height: Int, hotX: Int, hotY: Int, png: Data) -> Data {
        var w = ByteWriter(capacity: 8 + png.count)
        w.u16(UInt16(clamping: width))
        w.u16(UInt16(clamping: height))
        w.u16(UInt16(clamping: hotX))
        w.u16(UInt16(clamping: hotY))
        w.bytes(png)
        return w.data
    }

    public static func parseImage(_ data: Data) throws -> CursorImage {
        var r = ByteReader(data)
        let width = Int(try r.u16()), height = Int(try r.u16())
        let hotX = Int(try r.u16()), hotY = Int(try r.u16())
        return CursorImage(width: width, height: height, hotX: hotX, hotY: hotY, png: r.rest())
    }
}

public enum PingWire {
    public static func encode(_ nanoseconds: UInt64) -> Data {
        var w = ByteWriter(capacity: 8)
        w.u64(nanoseconds)
        return w.data
    }

    public static func decode(_ data: Data) throws -> UInt64 {
        var r = ByteReader(data)
        return try r.u64()
    }
}

/// cursorChannel: u32 session token from welcome
public enum ChannelWire {
    public static func encode(_ token: UInt32) -> Data {
        var w = ByteWriter(capacity: 4)
        w.u32(token)
        return w.data
    }

    public static func decode(_ data: Data) throws -> UInt32 {
        var r = ByteReader(data)
        return try r.u32()
    }
}

/// Receiver-side smoothing of one-level steps in flat areas
/// Sources often draw dark gradients in 8-bit steps
public enum Deband: UInt8, CaseIterable, Codable {
    case off, weak, normal, strong

    /// First-pass search radius in stream pixels
    /// Third pass reaches three times this
    public var rangePixels: Float {
        switch self {
        case .off: return 0
        case .weak: return 16
        case .normal: return 32
        case .strong: return 64
        }
    }
}

/// deband: u8 level
public enum DebandWire {
    public static func encode(_ level: Deband) -> Data { Data([level.rawValue]) }

    public static func decode(_ data: Data) throws -> Deband {
        var r = ByteReader(data)
        let raw = try r.u8()
        guard let level = Deband(rawValue: raw) else { throw FramingError.invalid("deband level \(raw)") }
        return level
    }
}

/// audio: u32 sample rate, u8 channels, u8 0
/// then interleaved 16-bit PCM; about 10 ms per packet
public enum AudioWire {
    public struct Packet {
        public var sampleRate: Int
        public var channels: Int
        public var samples: [Int16]

        public init(sampleRate: Int, channels: Int, samples: [Int16]) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.samples = samples
        }
    }

    public static func encode(sampleRate: Int, channels: Int, samples: [Int16]) -> Data {
        var w = ByteWriter(capacity: 6 + samples.count * 2)
        w.u32(UInt32(sampleRate))
        w.u8(UInt8(clamping: channels))
        w.u8(0)
        samples.withUnsafeBytes { w.bytes(Data($0)) }
        return w.data
    }

    public static func decode(_ data: Data) throws -> Packet {
        var r = ByteReader(data)
        let rate = Int(try r.u32()), channels = Int(try r.u8())
        _ = try r.u8()
        let body = r.rest()
        guard (8_000...192_000).contains(rate), (1...2).contains(channels), body.count % (2 * channels) == 0 else {
            throw FramingError.invalid("audio packet")
        }
        // Copied out: the payload slice need not be 2-byte aligned
        var samples = [Int16](repeating: 0, count: body.count / 2)
        samples.withUnsafeMutableBytes { _ = body.copyBytes(to: $0) }
        return Packet(sampleRate: rate, channels: channels, samples: samples)
    }
}

/// Sender panel's light: nits when known, and the slider level
public struct PanelLight: Equatable {
    public var nits: Double?
    public var level: Double

    public init(nits: Double?, level: Double) {
        self.nits = nits
        self.level = level
    }
}

/// brightness: f32 nits (negative: unknown), f32 slider level 0…1
public enum BrightnessWire {
    static let nitsLimit = 10_000.0

    public static func encode(_ light: PanelLight) -> Data {
        var w = ByteWriter(capacity: 8)
        w.f32(Float(light.nits.map { $0.isNaN ? -1 : min(nitsLimit, max(0, $0)) } ?? -1))
        w.f32(Float(light.level.isNaN ? 0 : min(1, max(0, light.level))))
        return w.data
    }

    public static func decode(_ data: Data) throws -> PanelLight {
        var r = ByteReader(data)
        let nits = Double(try r.f32()), level = Double(try r.f32())
        return PanelLight(nits: nits >= 0 && nits.isFinite ? min(nitsLimit, nits) : nil, level: level.isNaN ? 0 : min(1, max(0, level)))
    }
}

/// volume: f32 level, u8 muted
/// Empty: receiver returns to its own level
public enum OutputLevelWire {
    public static func encode(_ level: OutputLevel?) -> Data {
        guard let level = level else { return Data() }
        var w = ByteWriter(capacity: 5)
        w.f32(Float(level.volume.isNaN ? 0 : min(1, max(0, level.volume))))
        w.u8(level.muted ? 1 : 0)
        return w.data
    }

    public static func decode(_ data: Data) throws -> OutputLevel? {
        guard !data.isEmpty else { return nil }
        var r = ByteReader(data)
        let v = Double(try r.f32()), muted = try r.u8() != 0
        return OutputLevel(volume: v.isNaN ? 0 : min(1, max(0, v)), muted: muted)
    }
}

public enum ProbeFlags {
    /// Last probe message; the receiver answers with probeResult
    public static let end: UInt8 = 1
}

/// videoParams: u8 codec (0 HEVC, 1 H.264), u8 count
/// then count × (u32 length, bytes)
/// videoFrame: u8 keyframe, AVCC sample
public enum VideoWire {
    public static func params(codec: VideoCodec, sets: [Data]) -> Data {
        var w = ByteWriter()
        w.u8(codec == .hevc ? 0 : 1)
        w.u8(UInt8(sets.count))
        for s in sets {
            w.u32(UInt32(s.count))
            w.bytes(s)
        }
        return w.data
    }

    public static func parseParams(_ data: Data) throws -> (codec: VideoCodec, sets: [Data]) {
        var r = ByteReader(data)
        let codec: VideoCodec = try r.u8() == 0 ? .hevc : .h264
        let count = Int(try r.u8())
        var sets: [Data] = []
        for _ in 0..<count { sets.append(try r.bytes(Int(try r.u32()))) }
        return (codec, sets)
    }

    /// Payload parts, sent without copying the sample
    public static func frame(keyframe: Bool, avcc: Data) -> [Data] {
        [Data([keyframe ? 1 : 0]), avcc]
    }

    public static func parseFrame(_ data: Data) throws -> (keyframe: Bool, avcc: Data) {
        var r = ByteReader(data)
        return (try r.u8() != 0, r.rest())
    }
}
