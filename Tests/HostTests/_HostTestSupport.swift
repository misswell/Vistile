import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import XCTest
import VistileCore
@testable import Vistile

/// 宿主层测试的固定事实。
///
/// 全部面板都放在主屏之外的负坐标：测试承载进程绝不把总览窗口摆到用户桌面上
/// （R11 的键盘/鼠标测试只需要窗口存在，不需要它可见）。
enum HostFixtures {
    static let offscreenOrigin = CGPoint(x: -20_000, y: 0)
    static let offscreenSize = CGSize(width: 1_440, height: 900)
    static var visibleFrame: CGRect { CGRect(origin: offscreenOrigin, size: offscreenSize) }

    static let display = DisplayInfo(id: 4_242,
                                     frame: visibleFrame,
                                     visibleFrame: visibleFrame,
                                     backingScale: 2,
                                     isPrimary: true)

    /// 单屏 fixture 的映射表：控制器现在要求完整显示器表，测试必须显式给出基准。
    static var mapper: CoordinateMapper { CoordinateMapper(displays: [display]) }

    static func display(id: UInt32, cgFrame: CGRect, scale: CGFloat, isPrimary: Bool) -> DisplayInfo {
        DisplayInfo(id: id, frame: cgFrame, visibleFrame: cgFrame, backingScale: scale, isPrimary: isPrimary)
    }

    static func identity(_ index: Int) -> WindowIdentity {
        WindowIdentity(processID: 700 + Int32(index), processStartIdentity: 1, windowID: UInt32(9_000 + index))
    }

    static func record(_ index: Int, slot: Int, title: String? = nil) -> WindowRecord {
        WindowRecord(identity: identity(index),
                     bundleID: "com.test.app\(index)",
                     applicationName: "App\(index)",
                     title: title ?? "窗口 \(index)",
                     confidence: .unique(score: 0.9, axIndex: 0),
                     frame: CGRect(x: offscreenOrigin.x + 10,
                                   y: offscreenOrigin.y + 10,
                                   width: 1_280,
                                   height: 800),
                     displayID: display.id,
                     capture: .live,
                     slot: SlotID(index: slot),
                     sessionGeneration: 1)
    }

    /// 四张等比例卡片：与协调器使用同一个布局引擎，测试不另造一套几何。
    static func layout(count: Int = 4) -> (layout: GridLayout, records: [WindowIdentity: WindowRecord]) {
        let records = (0..<count).map { record($0, slot: $0) }
        let sources = records.map { GridSource(slot: $0.slot!, size: $0.frame.size) }
        let layout = GridLayoutEngine.layout(sources: sources, availableRect: visibleFrame, style: .standard)
        var byIdentity: [WindowIdentity: WindowRecord] = [:]
        for item in records { byIdentity[item.identity] = item }
        return (layout, byIdentity)
    }

    static func metalContext() throws -> MetalContext {
        guard let context = MetalContext.make() else {
            throw XCTSkip("本机没有可用 Metal 设备，宿主渲染测试跳过")
        }
        return context
    }

    static func renderer(metal: MetalContext) throws -> OverviewRenderer {
        guard let renderer = OverviewRenderer(metal: metal) else {
            throw XCTSkip("Metal 管线创建失败，宿主渲染测试跳过")
        }
        return renderer
    }

    /// 真实纹理：走捕获使用的同一条 CVMetalTextureCache 路径。
    /// 本机有 Metal 设备时这条链断掉就是缺陷，不能用 skip 掩盖。
    static func metalFrame(metal: MetalContext, width: Int = 320, height: Int = 200) throws -> MetalFrame {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as Any]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &buffer)
        XCTAssertEqual(status, kCVReturnSuccess, "CVPixelBufferCreate 失败：status=\(status)")
        let created = try XCTUnwrap(buffer, "CVPixelBufferCreate 未产出 pixel buffer")
        return try XCTUnwrap(metal.texture(from: created),
                             "CVMetalTextureCache 转换失败：捕获→纹理这条链在真实设备上断了")
    }

    /// CG 全局矩形 → 视图本地矩形（与 OverviewContentView.viewRect 同一换算）。
    static func viewRect(_ cg: CGRect, in view: NSView, cgOrigin: CGPoint) -> CGRect {
        CGRect(x: cg.minX - cgOrigin.x,
               y: (view.bounds.height + cgOrigin.y) - cg.maxY,
               width: cg.width,
               height: cg.height)
    }

    /// CG 全局矩形 → 视图本地点（与 OverviewContentView.viewRect 同一换算）。
    static func viewPoint(of cg: CGRect, in view: NSView, cgOrigin: CGPoint) -> CGPoint {
        CGPoint(x: cg.midX - cgOrigin.x, y: (view.bounds.height + cgOrigin.y) - cg.maxY)
    }
}

/// 工作台视图/交换测试共用的冻结投影。
struct HostWorkbenchFixture {
    let state: SessionState
    let placement: WorkbenchPlacement
    let snapshot: WorkbenchLayoutSnapshot

    var layout: WorkbenchLayout { snapshot.layout }
    var presentation: WorkbenchPresentation {
        WorkbenchPresenter.make(state: state, snapshot: snapshot, placement: placement)
    }
}

enum HostWorkbench {
    /// count 个窗口：0 号进主区，其余按 `sideFirst` 先排侧栏、再排顶栏。
    /// 几何走核心层同一条布局路径，测试不另造坐标；sideSlots 大于可见容量时得到可滚动的侧栏。
    static func fixture(count: Int = 4,
                        side: RailSide = .right,
                        sideFirst: Int = 1,
                        sideSlots: Int? = nil) -> HostWorkbenchFixture {
        var state = SessionState()
        for index in 0..<count {
            let record = HostFixtures.record(index, slot: index)
            state.records[record.identity] = record
        }
        state.catalogGeneration = 1
        state.displays = [HostFixtures.display]

        var layout = WorkbenchLayoutEngine.layout(displayID: HostFixtures.display.id,
                                                  visibleFrame: HostFixtures.visibleFrame,
                                                  side: side)
        layout = layout.extending(sideSlots: sideSlots ?? layout.sideCapacity)
        let snapshot = WorkbenchLayoutSnapshot(displayID: layout.displayID,
                                               layout: layout,
                                               topScrollOffset: 0,
                                               sideScrollOffset: 0,
                                               revision: 1)

        var placement = WorkbenchPlacement()
        if count > 0 { placement.setMain(HostFixtures.identity(0)) }
        var rail = (1..<max(1, count)).map { HostFixtures.identity($0) }
        let sideSlots = layout.slotOrder.filter { $0.rail == .side }
        let topSlots = layout.slotOrder.filter { $0.rail == .top }
        for slot in sideSlots.prefix(max(0, sideFirst)) where !rail.isEmpty {
            placement.place(rail.removeFirst(), at: slot)
        }
        for slot in topSlots where !rail.isEmpty {
            placement.place(rail.removeFirst(), at: slot)
        }
        return HostWorkbenchFixture(state: state, placement: placement, snapshot: snapshot)
    }
}

/// 手动时钟：预算、超时、期限全部由测试推进，不靠真实睡眠赌时序（方案 §14.4、§15.2）。
/// 生产调度器用 ContinuousClock，这里把"现在几点"换成一个可推进的计数。
final class HostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    var stamp: GeometryOperationScheduler.Stamp {
        lock.lock(); defer { lock.unlock() }
        return GeometryOperationScheduler.Stamp(nanoseconds: nanoseconds)
    }

    func advance(_ delta: UInt64) {
        lock.lock(); nanoseconds += delta; lock.unlock()
    }

    func advance(seconds delta: Double) {
        advance(UInt64(max(0, delta) * 1_000_000_000))
    }
}

@MainActor
enum HostScheduler {
    /// 每个用例一条写入通道：调度器带会话状态，跨用例复用会互相污染（方案 §5.1）。
    ///
    /// 建好就开会话并对齐测试自己的 sessionID：相位停在 `.closed` 时任何普通写入都拿不到准入，
    /// 那正是生产的判据，所以测试必须显式开局。
    static func make(clock: HostClock? = nil, sessionID: UUID? = nil, epoch: UInt64 = 0) -> GeometryOperationScheduler {
        let scheduler: GeometryOperationScheduler
        if let clock {
            scheduler = GeometryOperationScheduler(now: { clock.stamp })
        } else {
            scheduler = GeometryOperationScheduler()
        }
        if let sessionID {
            scheduler.adopt(sessionID: sessionID, epoch: epoch)
        } else {
            _ = scheduler.openSession()
        }
        return scheduler
    }
}

/// 方案 §5.3、§9.1 之后，过渡计划与交换意图必须自带操作上下文、操作前快照和核心层算好的放置路径。
/// 纯逻辑用例只验证动画端点，但这三份事实不许测试凭空补：上下文每次新建 operationID，
/// 放置路径走生产同一个 `MainPlacementPolicy.decide`。
enum HostPlanFacts {
    static func context(token: TransitionToken,
                        kind: GeometryOperationKind,
                        sessionID: UUID = UUID(),
                        epoch: UInt64 = 1) -> GeometryOperationContext {
        GeometryOperationContext(sessionID: sessionID,
                                 sessionEpoch: epoch,
                                 operationID: UUID(),
                                 transitionToken: token,
                                 kind: kind)
    }

    /// 把计划要写的目标矩形当作可容纳区问一次策略：可调尺寸时得到的就是 `.resizeAndMove(target)`，
    /// 与 reducer 给出的 `plan.targetFrame` 同源，测试不另写一套结论。
    static func placement(target: CGRect, currentFrame: CGRect) -> MainPlacementDecision {
        MainPlacementPolicy.decide(mainRect: target,
                                   currentFrame: currentFrame,
                                   isMovable: true,
                                   isResizable: true)
    }

    /// 用例只声明"精确占据目标矩形"这条路径时的简写：结论仍由策略算，不手搓枚举。
    static func placement(target: CGRect) -> MainPlacementDecision {
        placement(target: target, currentFrame: target)
    }

    /// 场景用例的交换意图：意图与补偿快照必须共用同一份操作上下文（方案 §5.3、§6.3），
    /// 分两处手抄就会各数一次 operationID，迟到回执就对不上账了。
    static func switchIntent(token: TransitionToken,
                             from: WindowIdentity?,
                             to: WindowIdentity,
                             source: WorkbenchSelectionSource,
                             placementRevision: UInt64,
                             targetDisplayID: UInt32,
                             kind: GeometryOperationKind = .mainSwitch,
                             before: [(identity: WindowIdentity, frame: CGRect)] = []) -> WorkbenchSwitchIntent {
        let context = context(token: token, kind: kind)
        return WorkbenchSwitchIntent(token: token,
                                     from: from,
                                     to: to,
                                     source: source,
                                     placementRevision: placementRevision,
                                     targetDisplayID: targetDisplayID,
                                     operationContext: context,
                                     beforeOperation: operationSnapshot(context: context, before))
    }

    /// 操作前快照（方案 §6.3）：补偿按它逆序回位，所以身份与写前实读帧必须真实给出。
    static func operationSnapshot(context: GeometryOperationContext,
                                  _ entries: [(identity: WindowIdentity, frame: CGRect)]) -> WorkbenchOperationSnapshot {
        var snapshot = WorkbenchOperationSnapshot(context: context)
        for entry in entries {
            snapshot.record(OperationGeometrySnapshot(identity: entry.identity,
                                                      beforeFrame: entry.frame,
                                                      beforeDisplayID: HostFixtures.display.id),
                            writtenStep: true)
        }
        return snapshot
    }
}

final class ActionRecorder {
    private(set) var actions: [OverviewContentView.Action] = []
    var onEach: ((OverviewContentView.Action) -> Void)?

    func record(_ action: OverviewContentView.Action) {
        actions.append(action)
        onEach?(action)
    }

    func count(_ match: (OverviewContentView.Action) -> Bool) -> Int {
        actions.filter(match).count
    }

    func reset() { actions.removeAll() }
}

enum HostEvents {
    /// 真实 NSEvent：与 AppKit 从 HID 得到的对象同一类型，视图收到的就是生产路径上的事件。
    static func mouse(_ type: NSEvent.EventType, in window: NSWindow?, point: CGPoint) -> NSEvent {
        let event = NSEvent.mouseEvent(with: type,
                                       location: point,
                                       modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window?.windowNumber ?? 0,
                                       context: nil,
                                       eventNumber: 0,
                                       clickCount: 1,
                                       pressure: 0.5)
        guard let event else { XCTFail("无法构造鼠标事件：\(type.rawValue)"); preconditionFailure("no event") }
        return event
    }

    static func key(_ virtualKey: Int,
                    characters: String = "",
                    flags: CGEventFlags = [],
                    type: NSEvent.EventType = .keyDown) -> NSEvent {
        let source = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(virtualKey), keyDown: type == .keyDown)
        event?.flags = flags
        let units = Array(characters.utf16)
        if !units.isEmpty {
            units.withUnsafeBufferPointer { buffer in
                _ = event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            }
        }
        guard let nsevent = event.flatMap({ NSEvent(cgEvent: $0) }) else {
            XCTFail("无法构造键盘事件：\(virtualKey)")
            preconditionFailure("no event")
        }
        return nsevent
    }

    static var command: CGEventFlags { .maskCommand }
    static var option: CGEventFlags { .maskAlternate }
}

extension XCTestCase {
    /// command buffer 完成回调在系统线程：断言 GPU 事实必须等它跑完，否则计数不可信。
    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// 面板能否成为 key 取决于应用是否激活：生产路径由菜单栏按钮调用 NSApp.activate，
    /// 测试必须先建立同一前提，否则断到的是"本机此刻谁在前台"而不是键盘归属。
    /// 新版系统里 NSApp.activate(ignoringOtherApps:) 已不再强制抢到前台，必须走运行中的应用句柄。
    func activateHostApp(timeout: TimeInterval = 2) {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        waitUntil(timeout: timeout) { NSApp.isActive }
    }
}
