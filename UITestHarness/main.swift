import AppKit
import CoreGraphics
import Foundation

/// P0 可控测试窗口（方案 §4）。这些窗口的标题、尺寸、是否弹面板都是人为可控的，
/// 用来把"跨应用交互"的不确定性拆开：先用已知行为的原生窗口验证，再上真实应用。
///
/// 环境变量：
///   HARNESS_WINDOWS=6          打开几个窗口（含一个重复标题窗口与一个计数窗口）
///   HARNESS_SECOND_ON_OTHER=1  把最后一个窗口放到另一块显示器的负坐标区域
enum Harness {
    static let windowCount = max(1, Int(ProcessInfo.processInfo.environment["HARNESS_WINDOWS"] ?? "") ?? 6)
    static let spreadToOtherDisplay = ProcessInfo.processInfo.environment["HARNESS_SECOND_ON_OTHER"] == "1"

    private static let cascadeWindowLimit = 12
    private static let cascadeMinimumSize = CGSize(width: 220, height: 160)
    private static let gridGap: CGFloat = 12

    /// Keep the familiar cascade for the small fixture and use a visible-screen grid for larger runs.
    static func windowFrames(count: Int, visibleFrame: CGRect) -> [CGRect] {
        guard count > 0, visibleFrame.width > 0, visibleFrame.height > 0 else { return [] }
        if count <= cascadeWindowLimit {
            return cascadeFrames(count: count, visibleFrame: visibleFrame)
        }
        return gridFrames(count: count, visibleFrame: visibleFrame)
    }

    private static func cascadeFrames(count: Int, visibleFrame: CGRect) -> [CGRect] {
        let widthLimit = visibleFrame.width
        let heightLimit = visibleFrame.height
        let minimumWidth = min(cascadeMinimumSize.width, widthLimit)
        let minimumHeight = min(cascadeMinimumSize.height, heightLimit)
        let widths = (0..<count).map { index in
            min(widthLimit, max(minimumWidth, CGFloat(620 - index * 24)))
        }
        let heights = (0..<count).map { index in
            min(heightLimit, max(minimumHeight, CGFloat(420 - index * 18)))
        }
        let maximumWidth = widths.max() ?? widthLimit
        let maximumHeight = heights.max() ?? heightLimit
        let leftInset = min(120, max(0, widthLimit - maximumWidth))
        let topInset = min(100, max(0, heightLimit - maximumHeight))
        let stepX = count > 1
            ? min(46, max(0, (widthLimit - leftInset - maximumWidth) / CGFloat(count - 1)))
            : 0
        let stepY = count > 1
            ? min(34, max(0, (heightLimit - topInset - maximumHeight) / CGFloat(count - 1)))
            : 0

        return (0..<count).map { index in
            clampedFrame(
                CGRect(x: visibleFrame.minX + leftInset + stepX * CGFloat(index),
                       y: visibleFrame.maxY - topInset - heights[0] - stepY * CGFloat(index),
                       width: widths[index],
                       height: heights[index]),
                to: visibleFrame
            )
        }
    }

    private static func gridFrames(count: Int, visibleFrame: CGRect) -> [CGRect] {
        let aspectRatio = visibleFrame.width / visibleFrame.height
        let columns = min(count, max(1, Int(ceil(sqrt(Double(count) * Double(aspectRatio) / 1.5)))))
        let rows = (count + columns - 1) / columns
        let gap = min(gridGap,
                      min(visibleFrame.width / CGFloat(columns + 1),
                          visibleFrame.height / CGFloat(rows + 1)))
        let cellWidth = max(1, (visibleFrame.width - gap * CGFloat(columns + 1)) / CGFloat(columns))
        let cellHeight = max(1, (visibleFrame.height - gap * CGFloat(rows + 1)) / CGFloat(rows))

        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            return clampedFrame(
                CGRect(x: visibleFrame.minX + gap + CGFloat(column) * (cellWidth + gap),
                       y: visibleFrame.maxY - gap - CGFloat(row + 1) * cellHeight - CGFloat(row) * gap,
                       width: cellWidth,
                       height: cellHeight),
                to: visibleFrame
            )
        }
    }

    private static func clampedFrame(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let x = width == bounds.width
            ? bounds.minX
            : min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let y = height == bounds.height
            ? bounds.minY
            : min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    #if DEBUG
    /// Regression guard for the 12-window legacy cascade and the 30-window pressure fixture.
    static func assertFixtureLayoutRegressionCases() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: -1024, y: 20, width: 1024, height: 720),
        ]
        for screen in screens {
            for count in [12, 30] {
                let frames = windowFrames(count: count, visibleFrame: screen)
                assert(frames.count == count, "Harness must create one frame for each requested window")
                assert(frames.allSatisfy { frame in
                    frame.width.isFinite && frame.height.isFinite
                        && frame.width > 0 && frame.height > 0 && screen.contains(frame)
                }, "Harness window frames must be positive and stay inside visibleFrame")

                if count > cascadeWindowLimit {
                    for first in frames.indices {
                        for second in frames.indices where second > first {
                            assert(!frames[first].intersects(frames[second]),
                                   "Large Harness fixtures must use separate grid cells")
                        }
                    }
                }
            }
        }
    }
    #endif
}

final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        #if DEBUG
        Harness.assertFixtureLayoutRegressionCases()
        #endif
        let frames = Harness.windowFrames(count: Harness.windowCount, visibleFrame: primary.visibleFrame)

        for index in frames.indices {
            // 第 3 与第 4 个窗口故意用同一个标题，验证"标题相同不代表同一个窗口"。
            let duplicateTitle = index == 2 || index == 3
            let title = duplicateTitle ? "无标题副本" : "Harness 窗口 \(index + 1)"
            // 第 2 个窗口每 200ms 变一次内容，验证遮挡下画面仍实时。
            let isCounter = index == 1
            let frame = frames[index]
            var size = frame.size
            var point = frame.origin
            if Harness.spreadToOtherDisplay, index == Harness.windowCount - 1, screens.count > 1 {
                let other = screens[1].visibleFrame
                size = CGSize(width: min(size.width, other.width), height: min(size.height, other.height))
                point = CGPoint(x: other.minX + min(40, max(0, other.width - size.width)),
                                y: other.maxY - size.height - min(40, max(0, other.height - size.height)))
            }
            let window = makeWindow(title: title,
                                    contentSize: size,
                                    origin: point,
                                    isCounter: isCounter,
                                    index: index)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        #if DEBUG
        let windowNumbers = Set(windows.map(\.windowNumber))
        assert(windows.count == Harness.windowCount, "Harness must create every requested window")
        assert(windowNumbers.count == windows.count, "Harness windows must have independent window numbers")
        assert(windows.allSatisfy(\.isVisible), "Every Harness window must be visible")
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(title: String,
                            contentSize: CGSize,
                            origin: CGPoint,
                            isCounter: Bool,
                            index: Int) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: origin, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        let label = NSTextField(labelWithString: isCounter ? "计数 0" : title)
        label.font = .monospacedDigitSystemFont(ofSize: isCounter ? 42 : 16, weight: isCounter ? .regular : .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        // 中文输入框：验收输入法候选窗是否落在真实窗口里。
        let field = NSTextField(string: "")
        field.placeholderString = "在这里打中文，例如：测试"
        field.translatesAutoresizingMaskIntoConstraints = false

        let sheetButton = NSButton(title: "打开保存面板", target: nil, action: nil)
        sheetButton.bezelStyle = .rounded
        let miniaturize = NSButton(title: "最小化我", target: nil, action: nil)
        miniaturize.bezelStyle = .rounded
        let stack = NSStackView(views: [sheetButton, miniaturize])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        container.addSubview(field)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            field.bottomAnchor.constraint(equalTo: stack.topAnchor, constant: -12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        window.contentView = container

        if isCounter {
            let controller = CounterController(label: label)
            controllers[window.windowNumber] = controller
            retain.append(controller)
        }
        let actions = HarnessActions(window: window, index: index)
        sheetButton.target = actions
        sheetButton.action = #selector(HarnessActions.openSavePanel)
        miniaturize.target = actions
        miniaturize.action = #selector(HarnessActions.minimize)
        retain.append(actions)
        // 位置由参数决定，不能 center()：负坐标屏与上下排列必须按原样摆放。
        window.setFrame(CGRect(origin: origin, size: contentSize), display: true)
        return window
    }

    private var controllers: [Int: CounterController] = [:]
    private var retain: [AnyObject] = []
}

/// 每 200ms 变一次文本，制造持续画面变化。
private final class CounterController {
    private let label: NSTextField
    private var value = 0
    private var timer: Timer?

    init(label: NSTextField) {
        self.label = label
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        value += 1
        label.stringValue = "计数 \(value)"
    }
}

private final class HarnessActions: NSObject {
    private weak var window: NSWindow?
    private let index: Int

    init(window: NSWindow, index: Int) {
        self.window = window
        self.index = index
    }

    @objc func openSavePanel() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "harness-\(index).txt"
        panel.beginSheetModal(for: window) { _ in }
    }

    @objc func minimize() { window?.miniaturize(nil) }
}

let application = NSApplication.shared
let delegate = HarnessAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
