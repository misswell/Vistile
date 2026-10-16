import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import VistileCore

/// 栏与主区之间的分隔线（方案 §5.2、§11.2）：命中区由冻结布局给出（6–8pt，居中落在区域间距里）。
/// 正常时只画一条细分隔；Hover 由窗口光标给出拖动形状。视图不认识 AX，也不改任何几何：
/// 它只报绝对屏幕点，绝对点不受面板自身随预览移动的影响（用增量会累积漂移）。
final class WorkbenchDividerView: NSView {
    let rail: RailKind
    /// 拖动开始的屏幕点（越过阈值的那一刻以按下点为准）：控制器用它做抓取锚点。
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?

    private var pressedPoint: CGPoint?
    private var startPoint: CGPoint?
    private static let dragThreshold: CGFloat = 2

    init(rail: RailKind, frame frameRect: NSRect) {
        self.rail = rail
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        rail = .top
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var isDragging: Bool { startPoint != nil }

    func cancelMouseGesture() {
        pressedPoint = nil
        startPoint = nil
    }

    // MARK: - 外观

    /// 命中区里只画一条细分隔：栏面板的底色覆盖整条空带，线落在带中央。
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.16).setFill()
        switch rail {
        case .top:
            let height: CGFloat = 1
            NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height).fill()
        case .side:
            let width: CGFloat = 1
            NSRect(x: ((bounds.width - width) / 2).rounded(), y: 0, width: width, height: bounds.height).fill()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: rail == .top ? .resizeUpDown : .resizeLeftRight)
    }

    // MARK: - 输入

    private func screenPoint(of event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func mouseDown(with event: NSEvent) {
        let point = screenPoint(of: event)
        pressedPoint = point
        startPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedPoint else { return }
        let point = screenPoint(of: event)
        if startPoint == nil {
            let distance = rail == .top ? abs(point.y - pressed.y) : abs(point.x - pressed.x)
            guard distance > Self.dragThreshold else { return }
            startPoint = pressed
            onDragBegan?(pressed)
        }
        onDragged?(point)
    }

    override func mouseUp(with event: NSEvent) {
        defer { cancelMouseGesture() }
        guard startPoint != nil else { return }
        onDragEnded?(screenPoint(of: event))
    }
}

/// 分隔线拖动期间的 AX 写入节流（方案 §11.2）：建议 15–20Hz，且同一时刻只允许一次在途写入。
/// 时间由调用方给：真实运行读系统时钟，测试用假时钟复证频率上限。
struct RailSizeWritePolicy {
    /// 相邻两次写入的最小间隔：60ms ≈ 16.7Hz，落在建议的 15–20Hz 内。
    static let minimumInterval: CFTimeInterval = 0.06

    private var lastWriteAt: CFTimeInterval = -.infinity

    func allowsWrite(now: CFTimeInterval, hasInFlightWrite: Bool) -> Bool {
        guard !hasInFlightWrite else { return false }
        return now - lastWriteAt >= Self.minimumInterval
    }

    mutating func recordWrite(at now: CFTimeInterval) {
        lastWriteAt = now
    }

    /// 新的拖动开始：第一次移动立即写入，不必等上一个拖动留下的节流窗口。
    mutating func reset() {
        lastWriteAt = -.infinity
    }
}
