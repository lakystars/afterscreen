import QuartzCore

/// Picture-tube power transitions as keyframes over normalized time
/// Off: picture, white line, dot, fade out
/// On: dot, full-width line, picture opens vertically; no wash
enum CRTEffect {
    /// Beam line thickness, in points
    static let line: CGFloat = 3
    /// Beam dot diameter, in points
    static let dot: CGFloat = 8
    static let offDuration: CFTimeInterval = 0.85
    static let onDuration: CFTimeInterval = 1.0

    enum Curve {
        case linear, easeIn, easeOut

        var function: CAMediaTimingFunction {
            switch self {
            case .linear: return CAMediaTimingFunction(name: .linear)
            case .easeIn: return CAMediaTimingFunction(name: .easeIn)
            case .easeOut: return CAMediaTimingFunction(name: .easeOut)
            }
        }
    }

    struct Key {
        var time: Double
        var value: CGFloat
        /// Timing curve of the segment ending here
        var curve = Curve.linear
    }

    struct Track {
        var keyPath: String
        var keys: [Key]
    }

    struct Timeline {
        var duration: CFTimeInterval
        /// The picture group: stream and cursor
        var picture: [Track]
        /// White overlay: a collapsing raster gets brighter
        var wash: [Track]
        /// Beam line and dot
        var beam: [Track]
        /// Phosphor bloom around the dot
        var halo: [Track]
        /// Off: the picture is a line
        var collapsed = 0.0
        /// On: the line spans the width
        var line = 0.0
        /// Off: the line is a dot
        var dot = 0.0
    }

    private static func k(_ time: Double, _ value: CGFloat, _ curve: Curve = .linear) -> Key {
        Key(time: time, value: value, curve: curve)
    }

    static func off(size: CGSize) -> Timeline {
        let w = size.width, flat = line / max(1, size.height)
        let collapsed = 0.22, dotAt = 0.48
        return Timeline(
            duration: offDuration,
            picture: [
                Track(keyPath: "transform.scale.y", keys: [k(0, 1), k(collapsed, flat, .easeIn)]),
                Track(keyPath: "opacity", keys: [k(0, 1), k(0.2, 1), k(0.27, 0)]),
            ],
            wash: [Track(keyPath: "opacity", keys: [k(0, 0), k(collapsed, 1, .easeIn)])],
            beam: [
                Track(keyPath: "opacity", keys: [k(0, 0), k(0.17, 0), k(collapsed, 1), k(dotAt, 1), k(1, 0, .easeOut)]),
                Track(keyPath: "bounds.size.width", keys: [k(0, w), k(collapsed, w), k(dotAt, dot, .easeIn), k(1, dot * 0.6)]),
                Track(keyPath: "bounds.size.height", keys: [k(0, line), k(collapsed, line), k(dotAt, dot), k(1, dot * 0.6)]),
                Track(keyPath: "shadowRadius", keys: [k(0, 8), k(collapsed, 8), k(dotAt, 14), k(1, 8)]),
            ],
            halo: [Track(keyPath: "opacity", keys: [k(0, 0), k(0.38, 0), k(0.5, 0.7, .easeOut), k(1, 0, .easeOut)])],
            collapsed: collapsed, dot: dotAt)
    }

    static func on(size: CGSize) -> Timeline {
        let w = size.width, flat = line / max(1, size.height)
        let lineAt = 0.3
        return Timeline(
            duration: onDuration,
            picture: [
                Track(keyPath: "transform.scale.y", keys: [k(0, flat), k(lineAt, flat), k(0.6, 1, .easeOut)]),
                Track(keyPath: "opacity", keys: [k(0, 0), k(0.28, 0), k(0.32, 1)]),
            ],
            wash: [Track(keyPath: "opacity", keys: [k(0, 0)])],
            beam: [
                Track(keyPath: "opacity", keys: [k(0, 0), k(0.05, 1), k(lineAt, 1), k(0.38, 0)]),
                Track(keyPath: "bounds.size.width", keys: [k(0, dot), k(0.1, dot), k(lineAt, w, .easeOut)]),
                Track(keyPath: "bounds.size.height", keys: [k(0, dot), k(0.1, line), k(1, line)]),
                Track(keyPath: "shadowRadius", keys: [k(0, 14), k(0.1, 10), k(lineAt, 8)]),
            ],
            halo: [Track(keyPath: "opacity", keys: [k(0, 0), k(0.05, 0.7), k(0.14, 0.5), k(lineAt, 0)])],
            line: lineAt)
    }

    static func animation(_ tracks: [Track], duration: CFTimeInterval) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.duration = duration
        group.animations = tracks.map { track in
            let a = CAKeyframeAnimation(keyPath: track.keyPath)
            a.keyTimes = track.keys.map { NSNumber(value: $0.time) }
            a.values = track.keys.map { NSNumber(value: Double($0.value)) }
            a.timingFunctions = track.keys.dropFirst().map(\.curve.function)
            a.duration = duration
            return a
        }
        return group
    }
}

/// Tube layers: picture group with its white wash
/// Beam and bloom drawn over the black
final class CRTTube {
    let picture = CALayer()
    private let wash = CALayer()
    private let beam = CALayer()
    private let halo = CAGradientLayer()
    private var size = CGSize.zero
    private static let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
                                                    "opacity": NSNull(), "shadowRadius": NSNull(), "hidden": NSNull()]

    /// Adds picture holding `content` to `root`; beam and bloom above
    func install(in root: CALayer, holding content: [CALayer]) {
        picture.actions = CRTTube.still
        root.addSublayer(picture)
        content.forEach(picture.addSublayer)
        wash.actions = CRTTube.still
        wash.backgroundColor = CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1)
        wash.opacity = 0
        picture.addSublayer(wash)

        halo.actions = CRTTube.still
        halo.type = .radial
        halo.colors = [CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 0.9), CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 0)]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.bounds = CGRect(x: 0, y: 0, width: 140, height: 140)
        halo.opacity = 0
        root.addSublayer(halo)

        beam.actions = CRTTube.still
        beam.backgroundColor = CGColor(red: 0.94, green: 0.97, blue: 1, alpha: 1)
        beam.cornerRadius = CRTEffect.dot / 2
        beam.shadowColor = CGColor(red: 0.7, green: 0.84, blue: 1, alpha: 1)
        beam.shadowOpacity = 1
        beam.shadowOffset = .zero
        beam.shadowRadius = 8
        beam.opacity = 0
        root.addSublayer(beam)
    }

    func layout(bounds: CGRect) {
        size = bounds.size
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        picture.bounds = CGRect(origin: .zero, size: bounds.size)
        picture.position = centre
        wash.frame = picture.bounds
        beam.position = centre
        halo.position = centre
    }

    /// Black until the power-on plays
    func darken() {
        [picture, wash, beam, halo].forEach { $0.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.transform = CATransform3DIdentity
        picture.opacity = 0
        wash.opacity = 0
        beam.opacity = 0
        halo.opacity = 0
        CATransaction.commit()
    }

    /// The picture as is, for the other effects
    func restore() {
        [picture, wash, beam, halo].forEach { $0.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.transform = CATransform3DIdentity
        picture.opacity = 1
        wash.opacity = 0
        beam.opacity = 0
        halo.opacity = 0
        CATransaction.commit()
    }

    func powerOn() {
        play(CRTEffect.on(size: size))
    }

    func powerOff() {
        play(CRTEffect.off(size: size))
    }

    private func play(_ t: CRTEffect.Timeline) {
        for (layer, tracks) in [(picture, t.picture), (wash, t.wash), (beam, t.beam), (halo as CALayer, t.halo)] {
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Model holds the end state; the animation plays over it
            // and is removed when done
            for track in tracks { layer.setValue(track.keys.last?.value, forKeyPath: track.keyPath) }
            CATransaction.commit()
            layer.add(CRTEffect.animation(tracks, duration: t.duration), forKey: "crt")
        }
    }
}
