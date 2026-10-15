import Foundation
import CoreGraphics
@testable import VistileCore

enum Fixtures {
    static func identity(_ pid: Int32, _ window: UInt32, puid: UInt64 = 1) -> WindowIdentity {
        WindowIdentity(processID: pid, processStartIdentity: puid, windowID: window)
    }

    static func capture(_ pid: Int32,
                        _ window: UInt32,
                        frame: CGRect,
                        title: String = "",
                        puid: UInt64 = 1,
                        layer: Int = 0,
                        alpha: Double = 1,
                        onScreen: Bool = true,
                        sharing: Int = 1,
                        owner: String = "TestApp",
                        bundle: String? = "com.test.app") -> CaptureWindowSnapshot {
        CaptureWindowSnapshot(identity: identity(pid, window, puid: puid),
                              frame: frame,
                              title: title,
                              ownerName: owner,
                              bundleID: bundle,
                              layer: layer,
                              alpha: alpha,
                              isOnScreen: onScreen,
                              sharingState: sharing)
    }

    static func ax(_ index: Int, frame: CGRect?, title: String = "", subrole: String? = "AXStandardWindow") -> AXWindowSnapshot {
        AXWindowSnapshot(index: index, frame: frame, title: title, subrole: subrole, isMovable: true, isResizable: true)
    }

    static func record(_ pid: Int32,
                       _ window: UInt32,
                       frame: CGRect = CGRect(x: 100, y: 100, width: 900, height: 600),
                       title: String = "窗口",
                       app: String = "TestApp",
                       bundle: String? = "com.test.app",
                       confidence: MatchConfidence = .unique(score: 0.9, axIndex: 0),
                       puid: UInt64 = 1,
                       generation: UInt64 = 1) -> WindowRecord {
        WindowRecord(identity: identity(pid, window, puid: puid),
                     bundleID: bundle,
                     applicationName: app,
                     title: title,
                     confidence: confidence,
                     frame: frame,
                     displayID: 1,
                     isMovable: true,
                     isResizable: true,
                     sessionGeneration: generation)
    }

    static func records(_ count: Int, size: CGSize = CGSize(width: 1_280, height: 800)) -> [WindowRecord] {
        // 显式拆出每个中间值：一条嵌着 CGRect/CGPoint 与整型除法的表达式，
        // 在较旧的工具链（Xcode 16.2 / Swift 6.0）上会卡在类型推断超时，本机新编译器却无感。
        (0..<count).map { index in
            let pid = 400 + Int32(index / 4)
            let window = UInt32(1_000 + index)
            let x = CGFloat(40 + (index % 4) * 300)
            let y = CGFloat(40 + (index / 4) * 200)
            let app = "App\(index / 4)"
            return record(pid, window,
                          frame: CGRect(x: x, y: y, width: size.width, height: size.height),
                          title: "窗口 \(index)",
                          app: app)
        }
    }

    static func sizes(_ count: Int, aspect: Double = 1.6) -> [CGSize] {
        (0..<count).map { _ in CGSize(width: 1_280 * aspect / 1.6, height: 800) }
    }

    static let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    static let displays = [
        DisplayInfo(id: 1,
                    frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 64, width: 1_512, height: 918),
                    backingScale: 2,
                    isPrimary: true)
    ]

    static func mapper() -> CoordinateMapper { CoordinateMapper(displays: displays) }

    static func state(withCount count: Int = 4, policy: SessionPolicy = SessionPolicy()) -> SessionState {
        var state = SessionState()
        state.policy = policy
        state.slots.capacity = max(count, 48)
        let list = records(count)
        for item in list { state.records[item.identity] = item }
        for item in list { state.slots.assign(item.identity, memoryKey: item.memoryKey) }
        state.catalogGeneration = 1
        return state
    }

    static func dispatch(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect] {
        SessionReducer.reduce(&state, event)
    }
}

extension WindowIdentity {
    static func test(_ pid: Int32, _ window: UInt32, puid: UInt64 = 1) -> WindowIdentity {
        Fixtures.identity(pid, window, puid: puid)
    }
}
