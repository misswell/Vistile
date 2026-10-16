import Foundation

/// 展示模式（方案 §7）。总览与工作台是两个独立模式：
/// 不用 `focused` 这种阶段名去推断"现在是不是工作台"。
public enum PresentationMode: String, Hashable, Sendable, Codable {
    /// 全屏平铺全部窗口。第一层主入口，每次从 hidden 进入都必须先到这里（方案 §4.1、§4.5）。
    case overview
    /// 主窗口＋L 型预览栏。
    case workbench

    public var displayName: String {
        switch self {
        case .overview: return "总览"
        case .workbench: return "工作台"
        }
    }
}

/// 模式之间的过渡，独立于 L 型内部的 A/B 交换（方案 §7、§10.1、§10.2）。
public enum ModeTransition: Hashable, Sendable {
    case idle
    /// 总览卡片 → 工作台：A 展开进主区，其余卡片过渡到轨道。
    case enteringWorkbench(token: TransitionToken, target: WindowIdentity)
    /// 工作台 → 总览：主窗口回到冻结总览里的原格子。
    case returningOverview(token: TransitionToken)

    public var token: TransitionToken? {
        switch self {
        case .idle: return nil
        case let .enteringWorkbench(token, _), let .returningOverview(token): return token
        }
    }

    public var isTransitioning: Bool { token != nil }

    public var target: WindowIdentity? {
        if case let .enteringWorkbench(_, target) = self { return target }
        return nil
    }
}
