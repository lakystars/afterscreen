import Foundation

public enum AfterscreenProtocol {
    public static let version = 3
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
    case thunderbolt, usb, wifi, loopback, unsupported

    public var isWired: Bool { self == .thunderbolt || self == .usb || self == .loopback }
}

public enum StreamPath: String, Codable { case tile, video }

public enum VideoCodec: String, Codable { case hevc, h264 }

public struct Hello: Codable, Equatable {
    public var protocolVersion: Int
    public var name: String
    public var model: String
    public var osVersion: String

    public init(protocolVersion: Int, name: String, model: String, osVersion: String) {
        self.protocolVersion = protocolVersion
        self.name = name
        self.model = model
        self.osVersion = osVersion
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

    public init(protocolVersion: Int, name: String, modelID: String, marketingName: String, osVersion: String,
                gpuNames: [String], panelPixels: PixelSize, panelPoints: PixelSize,
                hevcDecode: Bool, h264Decode: Bool, bc7: Bool) {
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
    }

    /// Retina panels are driven as HiDPI (points = pixels / 2)
    public var isRetina: Bool { panelPixels.width >= panelPoints.width * 2 }
}

public struct StreamConfig: Codable, Equatable {
    public var path: StreamPath
    public var streamPixels: PixelSize
    public var sourcePoints: PixelSize
    public var codec: VideoCodec?
    public var linkKind: LinkKind

    public init(path: StreamPath, streamPixels: PixelSize, sourcePoints: PixelSize, codec: VideoCodec?, linkKind: LinkKind) {
        self.path = path
        self.streamPixels = streamPixels
        self.sourcePoints = sourcePoints
        self.codec = codec
        self.linkKind = linkKind
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

    public init(receivedFPS: Double, displayedFPS: Double, uploadMs: Double, decompressMs: Double, lateFrames: Int,
                cpuPercent: Double, memoryBytes: UInt64, gpuPercent: Double) {
        self.receivedFPS = receivedFPS
        self.displayedFPS = displayedFPS
        self.uploadMs = uploadMs
        self.decompressMs = decompressMs
        self.lateFrames = lateFrames
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
    }
}

public struct Bye: Codable, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
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
    /// Size and hotspot in source points
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

public enum ProbeFlags {
    /// Last probe message; the receiver answers with probeResult
    public static let end: UInt8 = 1
}

/// videoParams: u8 codec (0 HEVC, 1 H.264), u8 count, count × (u32 length, bytes)
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

    public static func frame(keyframe: Bool, avcc: Data) -> Data {
        var w = ByteWriter(capacity: avcc.count + 1)
        w.u8(keyframe ? 1 : 0)
        w.bytes(avcc)
        return w.data
    }

    public static func parseFrame(_ data: Data) throws -> (keyframe: Bool, avcc: Data) {
        var r = ByteReader(data)
        return (try r.u8() != 0, r.rest())
    }
}
