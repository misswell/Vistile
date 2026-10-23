import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import VistileCore

final class WorkbenchDividerView: NSView {
    let rail: RailKind
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onDragCancelled: (() -> Void)?
    var onReset: (() -> Void)?
    var onAdjust: ((CGFloat) -> Void)?

    // Injectable so offscreen tests never need to post keys to another application.
    struct EventMonitoring {
        var addLocal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any? = {
            NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1)
        }
        var addGlobal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any? = {
            NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1)
        }
        var remove: (Any) -> Void = { NSEvent.removeMonitor($0) }
    }
    var eventMonitoring = EventMonitoring()

    private var pressedPoint: CGPoint?
    private var startPoint: CGPoint?
    private(set) var dragStartValue: CGFloat?
    private(set) var displayedValue: CGFloat = 0
    private var valueRange: ClosedRange<CGFloat> = 0...0
    private var side: RailSide = .right
    private var reduceMotion = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private let line = CALayer()
    private let highlight = CALayer()
    private let handle = CALayer()
    private let sizeLabel = DividerSizeLabel(labelWithString: "")
    private static let dragThreshold: CGFloat = 2
    private static let adjustmentStep: CGFloat = 8

    init(rail: RailKind, frame frameRect: NSRect) {
        self.rail = rail
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        rail = .top
        super.init(coder: coder)
        configure()
    }

    deinit {
        // Like the NSView lifecycle, monitor cleanup is confined to the main thread.
        MainActor.assumeIsolated {
            if let escapeMonitor { eventMonitoring.remove(escapeMonitor) }
            if let globalEscapeMonitor { eventMonitoring.remove(globalEscapeMonitor) }
        }
    }

    private func configure() {
        wantsLayer = true
        for decoration in [line, highlight, handle] { layer?.addSublayer(decoration) }
        highlight.opacity = 0
        handle.cornerRadius = 1.5
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.alignment = .center
        sizeLabel.drawsBackground = true
        sizeLabel.wantsLayer = true
        sizeLabel.layer?.cornerRadius = 5
        sizeLabel.layer?.masksToBounds = true
        sizeLabel.isHidden = true
        sizeLabel.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(rail == .top ? "Top rail height" : "Side rail width")
        setAccessibilityIdentifier(rail == .top ? "workbench.topRailDivider" : "workbench.sideRailDivider")
        setAccessibilityHelp("Use arrow keys to resize. Double-click to reset.")
        setAccessibilityOrientation(rail == .top ? .vertical : .horizontal)
        updateColors()
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var isDragging: Bool { startPoint != nil }
    var hasEscapeMonitor: Bool { escapeMonitor != nil || globalEscapeMonitor != nil }
    var isSizeLabelVisible: Bool { !sizeLabel.isHidden }
    var sizeLabelText: String { sizeLabel.stringValue }

    func updatePresentation(value: CGFloat, range: ClosedRange<CGFloat>, side: RailSide, reduceMotion: Bool) {
        displayedValue = value
        valueRange = range
        self.side = side
        self.reduceMotion = reduceMotion
        let text = "\(rail == .top ? "Height" : "Width") \(Int(value.rounded())) pt"
        if sizeLabel.stringValue != text { sizeLabel.stringValue = text }
        setAccessibilityValue(NSNumber(value: Double(value)))
        setAccessibilityMinValue(NSNumber(value: Double(range.lowerBound)))
        setAccessibilityMaxValue(NSNumber(value: Double(range.upperBound)))
        setAccessibilityValueDescription(text)
        if reduceMotion {
            highlight.removeAllAnimations()
            sizeLabel.layer?.removeAllAnimations()
        }
        layoutSizeLabel()
    }

    func cancelMouseGesture() {
        pressedPoint = nil
        startPoint = nil
        dragStartValue = nil
        if let escapeMonitor { eventMonitoring.remove(escapeMonitor) }
        escapeMonitor = nil
        if let globalEscapeMonitor { eventMonitoring.remove(globalEscapeMonitor) }
        globalEscapeMonitor = nil
        updateFeedback()
    }

    func cancelDragging() {
        let wasDragging = isDragging
        cancelMouseGesture()
        if wasDragging { onDragCancelled?() }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        hovered = false
        cancelMouseGesture()
        sizeLabel.removeFromSuperview()
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        superview?.addSubview(sizeLabel, positioned: .above, relativeTo: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelMouseGesture() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            line.backgroundColor = NSColor.separatorColor.cgColor
            highlight.backgroundColor = NSColor.controlAccentColor.cgColor
            handle.backgroundColor = (hovered || isDragging ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
            CATransaction.commit()
            sizeLabel.textColor = .labelColor
            sizeLabel.backgroundColor = .controlBackgroundColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rail == .top {
            line.frame = CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
            handle.frame = CGRect(x: bounds.midX - min(14, bounds.width / 2), y: bounds.midY - 1.5,
                                  width: min(28, bounds.width), height: 3)
        } else {
            line.frame = CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            handle.frame = CGRect(x: bounds.midX - 1.5, y: bounds.midY - min(14, bounds.height / 2),
                                  width: 3, height: min(28, bounds.height))
        }
        highlight.frame = line.frame
        CATransaction.commit()
        layoutSizeLabel()
    }

    private func layoutSizeLabel() {
        guard let parent = superview else { return }
        let width = min(112, max(0, parent.bounds.width - 8))
        let height = min(22, max(0, parent.bounds.height - 8))
        let origin: CGPoint
        if rail == .top {
            origin = CGPoint(x: frame.midX - width / 2, y: frame.maxY + 6)
        } else {
            origin = CGPoint(x: side == .right ? frame.maxX + 6 : frame.minX - width - 6,
                             y: frame.midY - height / 2)
        }
        sizeLabel.frame = CGRect(x: min(max(parent.bounds.minX + 4, origin.x), parent.bounds.maxX - width - 4),
                                 y: min(max(parent.bounds.minY + 4, origin.y), parent.bounds.maxY - height - 4),
                                 width: width, height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateFeedback()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateFeedback()
    }

    private func updateFeedback() {
        let opacity: Float = hovered || isDragging ? 1 : 0
        if highlight.opacity != opacity {
            let previous = highlight.presentation()?.opacity ?? highlight.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.opacity = opacity
            effectiveAppearance.performAsCurrentDrawingAppearance {
                handle.backgroundColor = (opacity > 0 ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
            }
            CATransaction.commit()
            if !reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = previous
                fade.toValue = opacity
                fade.duration = 0.12
                highlight.add(fade, forKey: "hover")
            } else {
                highlight.removeAnimation(forKey: "hover")
            }
        }
        if isDragging && sizeLabel.isHidden {
            layoutSizeLabel()
            sizeLabel.isHidden = false
            sizeLabel.alphaValue = reduceMotion ? 1 : 0
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    sizeLabel.animator().alphaValue = 1
                }
            }
        } else if !isDragging {
            sizeLabel.layer?.removeAllAnimations()
            sizeLabel.isHidden = true
            sizeLabel.alphaValue = 1
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: rail == .top ? .resizeUpDown : .resizeLeftRight)
    }

    private func screenPoint(of event: NSEvent) -> CGPoint {
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func mouseDown(with event: NSEvent) {
        cancelMouseGesture()
        if event.clickCount == 2 {
            onReset?()
            return
        }
        pressedPoint = screenPoint(of: event)
        dragStartValue = displayedValue
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedPoint else { return }
        let point = screenPoint(of: event)
        if startPoint == nil {
            let distance = rail == .top ? abs(point.y - pressed.y) : abs(point.x - pressed.x)
            guard distance > Self.dragThreshold else { return }
            startPoint = pressed
            escapeMonitor = eventMonitoring.addLocal(.keyDown) { [weak self] event in
                guard let self, self.isDragging, event.keyCode == 53 else { return event }
                self.cancelDragging()
                return nil
            }
            globalEscapeMonitor = eventMonitoring.addGlobal(.keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                // AppKit delivers on main; cancel synchronously before mouseUp can commit.
                MainActor.assumeIsolated { self?.cancelDragging() }
            }
            updateFeedback()
            onDragBegan?(pressed)
        }
        guard isDragging else { return }
        onDragged?(point)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        let point = screenPoint(of: event)
        cancelMouseGesture()
        if wasDragging { onDragEnded?(point) }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelDragging()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isDragging {
            cancelDragging()
            return
        }
        let direction: CGFloat
        switch (rail, event.keyCode) {
        case (.top, 125): direction = 1
        case (.top, 126): direction = -1
        case (.side, 123): direction = side == .right ? 1 : -1
        case (.side, 124): direction = side == .right ? -1 : 1
        default: super.keyDown(with: event); return
        }
        let step: CGFloat = event.modifierFlags.contains(.option) ? 1 : Self.adjustmentStep
        _ = adjust(by: direction * step)
    }

    override func accessibilityPerformIncrement() -> Bool { adjust(by: Self.adjustmentStep) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -Self.adjustmentStep) }

    private func adjust(by delta: CGFloat) -> Bool {
        guard !isDragging, let onAdjust else { return false }
        let next = min(max(displayedValue + delta, valueRange.lowerBound), valueRange.upperBound)
        guard next != displayedValue else { return false }
        onAdjust(next - displayedValue)
        return true
    }
}

private final class DividerSizeLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
