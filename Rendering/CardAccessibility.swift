import AppKit
import Foundation
import Metal
import VistileCore

/// 总览卡片的无障碍元素：应用、窗口名、状态都能被 VoiceOver 读到（方案 §13）。
final class CardAccessibilityElement: NSAccessibilityElement {
    private let onActivate: () -> Void

    init(frameInScreen: CGRect,
         applicationName: String,
         title: String,
         status: String,
         slotIndex: Int,
         onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init()
        setAccessibilityFrame(frameInScreen)
        setAccessibilityLabel("\(applicationName)，\(title)，\(status)")
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription("总览卡片 \(slotIndex + 1)")
        // NSAccessibilityElement 已自带 accessibilityPerformPress 选择器，直接声明会撞；
        // 用公开自定义动作暴露"展开这个窗口"。
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "展开窗口",
                                                                   target: self,
                                                                   selector: #selector(activateFromAccessibility))])
    }

    @objc func activateFromAccessibility() {
        onActivate()
    }
}

/// 视图侧的无障碍桥接：只在总览可见时暴露卡片。
extension OverviewContentView {
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Vistile 窗口总览" }

    override func accessibilityChildren() -> [Any]? {
        CardAccessibilityBuilder.children(of: self)
    }
}

enum CardAccessibilityBuilder {
    /// 由视图提供当前卡片事实；不在这里发明状态。
    static func children(of view: OverviewContentView) -> [Any] {
        view.accessibilityCardDescriptors.map { descriptor in
            let element = CardAccessibilityElement(frameInScreen: descriptor.screenRect,
                                                   applicationName: descriptor.applicationName,
                                                   title: descriptor.title,
                                                   status: descriptor.statusText,
                                                   slotIndex: descriptor.slotIndex,
                                                   onActivate: descriptor.activate)
            element.setAccessibilityParent(view)
            return element
        }
    }
}

struct CardAccessibilityDescriptor {
    let screenRect: CGRect
    let applicationName: String
    let title: String
    let statusText: String
    let slotIndex: Int
    let activate: () -> Void
}
