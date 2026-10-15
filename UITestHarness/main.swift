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
}

final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let step = CGSize(width: 46, height: 34)
        var origin = CGPoint(x: primary.frame.minX + 120, y: primary.frame.maxY - 520)

        for index in 0..<Harness.windowCount {
            // 第 3 与第 4 个窗口故意用同一个标题，验证"标题相同不代表同一个窗口"。
            let duplicateTitle = index == 2 || index == 3
            let title = duplicateTitle ? "无标题副本" : "Harness 窗口 \(index + 1)"
            // 第 2 个窗口每 200ms 变一次内容，验证遮挡下画面仍实时。
            let isCounter = index == 1
            let size = CGSize(width: 620 - CGFloat(index) * 24, height: 420 - CGFloat(index) * 18)
            var point = origin
            if Harness.spreadToOtherDisplay, index == Harness.windowCount - 1, screens.count > 1 {
                let other = screens[1]
                point = CGPoint(x: other.frame.minX + 40, y: other.frame.maxY - size.height - 40)
            }
            let window = makeWindow(title: title,
                                    contentSize: size,
                                    origin: point,
                                    isCounter: isCounter,
                                    index: index)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            origin = CGPoint(x: origin.x + step.width, y: origin.y - step.height)
        }
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
