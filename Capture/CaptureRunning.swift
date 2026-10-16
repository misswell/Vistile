import Foundation
import VistileCore

/// 一次捕获运行的帧计数。分开计数才能区分"画面静止"与"捕获失败"（方案 §9.8）。
struct CaptureFrameCounts: Hashable {
    var published = 0
    /// status 为 idle/blank/suspended：保留最后一帧，不算新画面也不算失败。
    var keptLastFrame = 0
    /// 明确 .started 的帧：只计数，用于实机判断这一帧到底带不带图像。
    var startedFrames = 0
    /// 附件缺失或没有 status：绝不发布伪完整帧（方案 §10.1）。
    var rejectedByMetadata = 0
    var dropped = 0
    /// 代次不匹配的晚到帧。
    var stale = 0
}

/// 一次捕获运行对协调层暴露的全部动作（方案 §7.1/§7.2）。
///
/// 协调层只认 runID 与这三个异步动作，start/stop 交错与旧回调污染因此可以在
/// 宿主测试里用假驱动确定复现，而不是依赖真实 ScreenCaptureKit 的时序。
protocol CaptureRunning: AnyObject {
    var identity: WindowIdentity { get }
    var runID: CaptureRunID { get }
    var phase: CaptureRunPhase { get }
    var config: StreamConfig { get }
    var lastError: String? { get }
    var frameCounts: CaptureFrameCounts { get }

    /// 回调一律带 runID：接收方必须核对它是不是当前那一轮。
    var onFirstFrame: ((CaptureRunID, Date) -> Void)? { get set }
    var onFailure: ((CaptureRunID, String) -> Void)? { get set }
    /// 新帧落地。画面更新由它驱动，静止时不该再有 60Hz 空转（方案 §7.5）。
    var onFramePublished: ((CaptureRunID, MetalFrame) -> Void)? { get set }

    /// 启动。返回 false 表示这一轮不会进入 running（含"启动期间被取消"）。
    @discardableResult func start() async -> Bool
    /// 停止。即使 start 仍挂起也必须可调用；真正执行 stopCapture 的只有一条路径。
    func stop() async
    @discardableResult func update(configuration: StreamConfig) async -> Bool
}
