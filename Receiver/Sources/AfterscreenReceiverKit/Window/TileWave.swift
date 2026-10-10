import Foundation
import QuartzCore

/// Tile wave power effect state; the renderer draws it
/// Ticks redraws while running: a still desktop sends no frames
final class TileWave {
    static let onDuration: CFTimeInterval = 0.9
    static let offDuration: CFTimeInterval = 0.75

    private let renderer: StreamRenderer
    /// Closing draws block on drawables: kept off the main queue
    private let queue = DispatchQueue(label: "afterscreen.wave", qos: .userInteractive)
    /// Main queue only
    private var timer: DispatchSourceTimer?
    /// Main queue: requests a session redraw on the decode queue
    var requestRedraw: (() -> Void)?

    init(renderer: StreamRenderer) {
        self.renderer = renderer
    }

    /// Black until `powerOn`
    func prepare() {
        stop()
        renderer.setWave(.hidden)
    }

    func powerOn() {
        renderer.setWave(.opening(start: CACurrentMediaTime(), duration: TileWave.onDuration))
        run(for: TileWave.onDuration, on: .main) { [weak self] in self?.requestRedraw?() }
    }

    /// `live`: over the running stream, redrawn as for power-on
    /// Else over the picture kept at the session's end
    func powerOff(live: Bool = false) {
        renderer.setWave(.closing(start: CACurrentMediaTime(), duration: TileWave.offDuration))
        if live { return run(for: TileWave.offDuration, on: .main) { [weak self] in self?.requestRedraw?() } }
        run(for: TileWave.offDuration, on: queue) { [renderer] in renderer.drawFarewell() }
    }

    /// Once the window has gone
    func finish() {
        stop()
        renderer.setWave(nil)
        renderer.dropFarewell()
    }

    /// Display-rate ticks for `duration`
    /// One extra tick draws the end state
    private func run(for duration: CFTimeInterval, on queue: DispatchQueue, tick: @escaping () -> Void) {
        stop()
        let t = DispatchSource.repeating(on: queue, every: 1.0 / 60, handler: tick)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.03) { [weak self, weak t] in
            guard let self = self, let t = t, self.timer === t else { return }
            self.stop()
            queue.async(execute: tick)
        }
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }
}
