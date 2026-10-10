import Foundation
import QuartzCore

/// The tile wave power effect. The renderer draws it; this sets its state and keeps frames coming
/// while it runs, since a still desktop sends none
final class TileWave {
    static let onDuration: CFTimeInterval = 0.9
    static let offDuration: CFTimeInterval = 0.75

    private let renderer: StreamRenderer
    /// Closing draws block on drawables, so they stay off the main queue
    private let queue = DispatchQueue(label: "afterscreen.wave", qos: .userInteractive)
    /// Main queue only
    private var timer: DispatchSourceTimer?
    /// Main queue: asks the live session for a redraw on its decode queue
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

    /// Plays over the picture the renderer kept at the session's end
    func powerOff() {
        renderer.setWave(.closing(start: CACurrentMediaTime(), duration: TileWave.offDuration))
        run(for: TileWave.offDuration, on: queue) { [renderer] in renderer.drawFarewell() }
    }

    /// Once the window has gone
    func finish() {
        stop()
        renderer.setWave(nil)
        renderer.dropFarewell()
    }

    /// Display-rate ticks for `duration`, then one more so the end state is drawn
    private func run(for duration: CFTimeInterval, on queue: DispatchQueue, tick: @escaping () -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 60)
        t.setEventHandler(handler: tick)
        t.resume()
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
