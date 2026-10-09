import CoreGraphics
import CoreText
import Foundation
import Metal
import AfterscreenCore
import AfterscreenReceiverKit
import AfterscreenSenderKit

// Tile pipeline benchmark: sender encode/pack → framing → receiver parse/upload, per scenario.
// Run: swift run -c release --package-path Bench AfterscreenBench [WxH] [--link Gbps]

// MARK: - Measurement

struct Usage {
    var cpu: Double
    var faults: Int
    var wall: Double

    static func now() -> Usage {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return Usage(cpu: s(u.ru_utime) + s(u.ru_stime), faults: u.ru_minflt, wall: ProcessInfo.processInfo.systemUptime)
    }
}

final class Stage {
    var cpu = 0.0, wall = 0.0, gpu = 0.0, faults = 0, count = 0

    func measure<T>(_ body: () throws -> T) rethrows -> T {
        let a = Usage.now()
        let result = try body()
        let b = Usage.now()
        cpu += b.cpu - a.cpu
        wall += b.wall - a.wall
        faults += b.faults - a.faults
        count += 1
        return result
    }

    func ms(_ v: Double) -> String { String(format: "%6.2f", count > 0 ? v / Double(count) * 1000 : 0) }
    var cpuMs: String { ms(cpu) }
    var wallMs: String { ms(wall) }
    var gpuMs: String { ms(gpu) }
    var faultsPerFrame: String { String(format: "%5.0f", count > 0 ? Double(faults) / Double(count) : 0) }
}

// MARK: - Scenes (BGRA8)

struct Scene {
    let width: Int
    let height: Int
    var pixels: [UInt32]

    init(width: Int, height: Int, fill: UInt32 = 0xFFFF_FFFF) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: fill, count: width * height)
    }

    /// Video-like: smooth gradients with sensor-style noise
    static func photo(width: Int, height: Int, seed: UInt32) -> Scene {
        var s = Scene(width: width, height: height)
        var state = seed &* 2_654_435_761 | 1
        let phase = Double(seed) * 0.7
        s.pixels.withUnsafeMutableBufferPointer { p in
            for y in 0..<height {
                let fy = Double(y) / Double(height)
                for x in 0..<width {
                    let fx = Double(x) / Double(width)
                    state ^= state << 13; state ^= state >> 17; state ^= state << 5
                    let n = Int(state & 31) - 16
                    let r = Int(127 + 100 * sin(fx * 6 + phase)) + n
                    let g = Int(127 + 100 * sin(fy * 5 + fx * 3 + phase)) + n
                    let b = Int(127 + 100 * cos(fx * 4 - fy * 7 + phase)) + n
                    func c(_ v: Int) -> UInt32 { UInt32(max(0, min(255, v))) }
                    p[y * width + x] = 0xFF00_0000 | c(r) << 16 | c(g) << 8 | c(b)
                }
            }
        }
        return s
    }

    /// Desktop-like: dark text lines on white with a few coloured panels
    static func ui(width: Int, height: Int, scroll: Int) -> Scene {
        var s = Scene(width: width, height: height)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        s.pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width / 6, height: height))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: width / 6 + 40, y: height - 120, width: 400, height: 60))
            let font = CTFontCreateWithName("Menlo" as CFString, 26, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ]
            let words = ["frame", "tile", "panel", "render", "queue", "buffer", "metal", "stream", "socket", "pixel",
                         "display", "encode", "decode", "latency", "cursor", "window", "theme", "layout", "swift", "core"]
            var line = 0
            var y = height - 200 + scroll
            while y > -40 {
                var text = String(format: "%5d  ", line + 1)
                for k in 0..<18 { text += words[(line * 7 + k * 3) % words.count] + ((k % 5 == 4) ? "(); " : " ") }
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                ctx.textPosition = CGPoint(x: Double(width / 6 + 40), y: Double(y))
                CTLineDraw(ctLine, ctx)
                line += 1
                y -= 36
            }
        }
        return s
    }

    mutating func paste(_ other: Scene, rect: CGRect) {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        for y in y0..<min(height, y0 + h) {
            for x in x0..<min(width, x0 + w) { pixels[y * width + x] = other.pixels[y * width + x] }
        }
    }

    func texture(_ device: MTLDevice) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let t = device.makeTexture(descriptor: desc)!
        pixels.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return t
    }
}

// MARK: - Pipeline

let device = MTLCreateSystemDefaultDevice()!
let sizeArg = CommandLine.arguments.dropFirst().first { $0.contains("x") }?.split(separator: "x").compactMap { Int($0) }
let width = sizeArg?.first ?? 5120, height = sizeArg?.last ?? 2880
let geometry = TileGeometry(width: width, height: height)
let frames = 120, warmup = 20
/// Link capacity the compression policy assumes: --link <Gbps>, default Thunderbolt 3 class
let linkGbps = CommandLine.arguments.firstIndex(of: "--link")
    .flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 40

print("Afterscreen tile pipeline bench — \(width)×\(height), \(geometry.tileCount) tiles, \(frames - warmup) frames/scenario, link \(linkGbps) Gbps, \(device.name)")
print("Building scenes…")
let photoA = Scene.photo(width: width, height: height, seed: 1)
let photoB = Scene.photo(width: width, height: height, seed: 2)
let uiA = Scene.ui(width: width, height: height, scroll: 0)
let uiB = Scene.ui(width: width, height: height, scroll: 36)
let videoRect = CGRect(x: width / 3, y: height / 3, width: 1280, height: 720)
var windowA = uiA, windowB = uiA
windowA.paste(photoA, rect: videoRect)
windowB.paste(photoB, rect: videoRect)
var typing = uiA
let typingRect = CGRect(x: width / 2, y: height / 2, width: 180, height: 28)
typing.paste(photoA, rect: typingRect)
let everything = CGRect(x: 0, y: 0, width: width, height: height)

/// Scenes alternate; `dirty` is what ScreenCaptureKit reports as changed between them
let scenarios: [(String, [Scene], dirty: [CGRect])] = [
    ("full-motion video", [photoA, photoB], [everything]),
    ("video in a window", [windowA, windowB], [videoRect]),
    ("scrolling text", [uiA, uiB], [everything]),
    ("typing", [uiA, typing], [typingRect]),
    ("idle", [uiA], []),
]

func readBack(_ texture: MTLTexture, queue: MTLCommandQueue) -> [UInt8] {
    let bytesPerRow = geometry.blocksX * BC7.blockBytes
    let buffer = device.makeBuffer(length: bytesPerRow * geometry.blocksY, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
              destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * geometry.blocksY)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    return [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length))
}

print("")
print("| scenario | dirty | raw MB | wire MB | S encode GPU | S encode CPU | S pack CPU | S faults | R framing CPU | R parse CPU | R upload CPU | R GPU | R faults | S CPU/frame | R CPU/frame | match |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for (name, scenes, dirty) in scenarios {
    let textures = scenes.map { $0.texture(device) }
    let encoder = try! TileEncoder(device: device, geometry: geometry)
    let receiverQueue = device.makeCommandQueue()!
    let tileTexture = TileTexture(device: device)
    tileTexture.ensure(geometry: geometry)
    let sEncode = Stage(), sPack = Stage(), rFrame = Stage(), rParse = Stage(), rUpload = Stage()
    var dirtyTotal = 0, rawTotal = 0, wireTotal = 0, measured = 0
    // Socket stand-in: each read copies at most one 4 MiB socket buffer, like the kernel
    let wire = UnsafeMutableRawPointer.allocate(byteCount: 64 << 20, alignment: 16)
    var wireCount = 0, wireOffset = 0
    let reader = FrameReader { dst, count in
        let n = min(count, 4 << 20, wireCount - wireOffset)
        dst.copyMemory(from: wire + wireOffset, byteCount: n)
        wireOffset += n
        return n
    }

    let packer = TilePacker()
    var policy = CompressionPolicy(capacityGbps: linkGbps)
    for i in 0..<frames {
        let measuring = i >= warmup
        let texture = textures[i % textures.count]
        let encodeStage = measuring ? sEncode : Stage()
        let encoded = encodeStage.measure { encoder.encode(texture: texture, forceAll: i == 0, dirty: dirty, now: Double(i) / 60) }
        encodeStage.gpu += encoder.lastGPUSeconds
        guard let frame = encoded else { continue }
        let packed = (measuring ? sPack : Stage()).measure { () -> (parts: [Data], wireBytes: Int, lz4In: Int, lz4Out: Int) in
            let p = packer.pack(frame, geometry: geometry, compression: policy.next(rawBytes: frame.data.count, queueWasFull: false))
            policy.record(rawBytes: p.lz4In, wireBytes: p.lz4Out)
            return p
        }
        wireCount = 0
        wireOffset = 0
        for part in [Framing.header(type: .tileFrame, length: packed.wireBytes)] + packed.parts {
            part.withUnsafeBytes { (wire + wireCount).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            wireCount += part.count
        }
        let message = try! (measuring ? rFrame : Stage()).measure { try reader.next() }!
        let parsed = try! (measuring ? rParse : Stage()).measure { try TileFrame(payload: message.payload, expecting: geometry) }
        let cb = receiverQueue.makeCommandBuffer()!
        try! (measuring ? rUpload : Stage()).measure {
            try tileTexture.encodeUpload(parsed, into: cb)
            cb.commit()
        }
        cb.waitUntilCompleted()
        if measuring {
            rUpload.gpu += cb.gpuEndTime - cb.gpuStartTime
            dirtyTotal += frame.tileCount
            rawTotal += frame.data.count
            wireTotal += packed.wireBytes
            measured += 1
        }
    }

    // Once the picture settles, the BC7 reference follows the BC1 sent during motion
    if let settled = encoder.refine(now: Double(frames) / 60 + 1) {
        let packed = packer.pack(settled, geometry: geometry, compression: .none)
        let payload = packed.parts.reduce(Data(), +)
        let cb = receiverQueue.makeCommandBuffer()!
        try! tileTexture.encodeUpload(try! TileFrame(payload: payload, expecting: geometry), into: cb)
        cb.commit()
        cb.waitUntilCompleted()
    }

    // Receiver picture must equal the sender's reference block for block
    let got = readBack(tileTexture.texture!, queue: receiverQueue)
    let ref = encoder.reference
    var match = true
    outer: for by in 0..<geometry.blocksY {
        for bx in 0..<geometry.blocksX {
            let a = (by * geometry.blocksX + bx) * BC7.blockBytes
            let b = TileEncoder.blockOffset(bx: bx, by: by, geometry: geometry)
            if memcmp(Array(got[a..<(a + 16)]), ref.baseAddress! + b, 16) != 0 { match = false; break outer }
        }
    }

    if ProcessInfo.processInfo.environment["BENCH_FAULTS"] != nil {
        print("faults:", name, "encode", sEncode.faults, "pack", sPack.faults, "framing", rFrame.faults, "parse", rParse.faults, "upload", rUpload.faults)
    }
    let n = Double(max(1, sEncode.count))
    let m = Double(max(1, measured))
    let sCPU = (sEncode.cpu + sPack.cpu) / n * 1000
    let rCPU = (rFrame.cpu + rParse.cpu + rUpload.cpu) / m * 1000
    print(String(format: "| %@ | %.1f%% | %.2f | %.2f | %@ | %@ | %@ | %@ | %@ | %@ | %@ | %@ | %@ | %.2f | %.2f | %@ |",
                 name, Double(dirtyTotal) / n / Double(geometry.tileCount) * 100,
                 Double(rawTotal) / n / 1e6, Double(wireTotal) / n / 1e6,
                 sEncode.gpuMs, sEncode.cpuMs, sPack.cpuMs, String(format: "%.0f", Double(sEncode.faults + sPack.faults) / n),
                 rFrame.cpuMs, rParse.cpuMs, rUpload.cpuMs, rUpload.gpuMs,
                 String(format: "%.0f", Double(rFrame.faults + rParse.faults + rUpload.faults) / m),
                 sCPU, rCPU, match ? "yes" : "NO"))
}
print("")
print("ms per frame. S = sender, per captured frame (pack amortised); R = receiver, per received frame. CPU = all threads; faults = minor page faults.")
