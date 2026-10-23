import AppKit
import QuartzCore

/// One-shot visual work on the next display cycle. Safety events never use this scheduler.
@MainActor
final class VisualSyncScheduler: NSObject {
    private var link: CADisplayLink?
    private var callback: (() -> Void)?
    private var generation: UInt64 = 0
    var isScheduled: Bool { callback != nil }

    func schedule(on screen: NSScreen?, _ callback: @escaping () -> Void) {
        self.callback = callback
        guard link == nil else { return }
        generation &+= 1
        if let screen = screen ?? NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(handleTick(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        } else {
            let expected = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.fire()
            }
        }
    }

    @objc private func handleTick(_ link: CADisplayLink) { fire() }

    func fire() {
        let action = callback
        cancel()
        action?()
    }

    func cancel() {
        generation &+= 1
        link?.invalidate()
        link = nil
        callback = nil
    }
}
