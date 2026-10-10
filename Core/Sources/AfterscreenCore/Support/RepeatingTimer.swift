import Dispatch
import Foundation

public extension DispatchSource {
    /// Running timer on `queue`, first firing `delay` seconds from now
    static func repeating(on queue: DispatchQueue, every interval: TimeInterval, after delay: TimeInterval = 0,
                          leeway: DispatchTimeInterval = .nanoseconds(0), handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: leeway)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
