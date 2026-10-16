import AppKit
import Foundation
import Metal
import VistileCore

/// 卡片的无障碍元素：应用、窗口名、状态都能被 VoiceOver 读到（方案 §13）。
/// 位置与可操作性由所在界面给出：总览是「总览卡片 N / 展开窗口」，
/// 工作台两栏是「顶栏/侧栏卡片 N / 切换到主工作区」。
final class CardAccessibilityElement: NSAccessibilityElement {
    private let onActivate: () -> Void

    init(frameInScreen: CGRect,
         applicationName: String,
         title: String,
         status: String,
         roleDescription: String,
         actionName: String,
         onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init()
        setAccessibilityFrame(frameInScreen)
        setAccessibilityLabel("\(applicationName)，\(title)，\(status)")
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription(roleDescription)
        // 带名字的自定义动作让 VoiceOver 读出"能做什么"；返回 Bool 是系统约定的签名。
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: actionName,
                                                                   target: self,
                                                                   selector: #selector(activateFromAccessibility))])
    }

    @objc func activateFromAccessibility() -> Bool {
        onActivate()
        return true
    }

    /// 按钮角色的标准激活（VO-Space）：与自定义动作走同一条路径，不做"看得见按不动"的假按钮。
    override func accessibilityPerformPress() -> Bool {
        onActivate()
        return true
    }
}

/// 总览视图侧的无障碍桥接：只在总览可见时暴露卡片。
extension OverviewContentView {
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Vistile 窗口总览" }

    override func accessibilityChildren() -> [Any]? {
        CardAccessibilityBuilder.children(of: self)
    }
}

/// 工作台每一条栏的视图侧桥接：一张卡片一个按钮，动作走与点击完全相同的路径。
extension WorkbenchRailView {
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        rail == .top ? "工作台顶栏" : "工作台侧栏"
    }

    override func accessibilityChildren() -> [Any]? {
        CardAccessibilityBuilder.children(of: self)
    }
}

enum CardAccessibilityBuilder {
    /// 由视图提供当前卡片事实；不在这里发明状态。
    static func children(of view: OverviewContentView) -> [Any] {
        view.accessibilityCardDescriptors.map { element(for: $0, parent: view) }
    }

    static func children(of view: WorkbenchRailView) -> [Any] {
        view.accessibilityCardDescriptors.map { element(for: $0, parent: view) }
    }

    private static func element(for descriptor: CardAccessibilityDescriptor,
                                parent: NSView) -> CardAccessibilityElement {
        let element = CardAccessibilityElement(frameInScreen: descriptor.screenRect,
                                               applicationName: descriptor.applicationName,
                                               title: descriptor.title,
                                               status: descriptor.statusText,
                                               roleDescription: descriptor.roleDescription,
                                               actionName: descriptor.actionName,
                                               onActivate: descriptor.activate)
        element.setAccessibilityParent(parent)
        return element
    }

    /// 状态描述必须与实际能力一致：轮询、最小化、无权限都不能说成实时。
    static func statusText(_ capture: CapturePhase?) -> String {
        switch capture {
        case .live: return "实时画面"
        case .starting: return "正在启动实时画面"
        case let .lowFrequency(interval): return "低频更新，间隔 \(interval) 毫秒"
        case .pausedMinimized: return "已最小化，画面暂停"
        case .permissionMissing: return "缺少屏幕录制权限，无画面"
        case .notCapturable: return "该窗口不允许捕获"
        case .idle, .none: return "尚未取得画面"
        }
    }
}

struct CardAccessibilityDescriptor {
    let screenRect: CGRect
    let applicationName: String
    let title: String
    let statusText: String
    /// 位置说明（朗读给用户的"这一张在哪"）。
    let roleDescription: String
    /// 这个卡片此刻能做什么（朗读出的可操作性）。
    let actionName: String
    let activate: () -> Void
}
