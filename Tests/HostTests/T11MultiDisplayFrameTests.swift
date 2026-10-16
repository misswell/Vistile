import AppKit
import VistileCore
import XCTest
@testable import Vistile

/// T11 多屏入口坐标（方案 §9.1、§9.2）。
///
/// 断言全部打在"控制器最终 frame 计算入口"上：`appKitFrame(for:mapper:)` 与真实面板 frame，
/// 不是只对 mapper 做往返测试——控制器偷偷用单屏 mapper 时往返测试照样绿。
/// 面板只构造、从不上屏，用户桌面上不会出现总览窗口。
final class T11MultiDisplayFrameTests: XCTestCase {
    private var metal: MetalContext!
    private var controllers: [OverviewWindowController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        metal = try HostFixtures.metalContext()
    }

    override func tearDown() {
        for controller in controllers { controller.hide() }
        controllers = []
        metal = nil
        super.tearDown()
    }

    private func makeController(display: DisplayInfo, mapper: CoordinateMapper) -> OverviewWindowController {
        let controller = OverviewWindowController(display: display, mapper: mapper, metal: metal)
        controllers.append(controller)
        return controller
    }

    // MARK: - §9.2 固定数据：主 (0,0,1440,900)、副 (1440,0,1920,1080) → 副屏 y = -180

    private let primary = HostFixtures.display(id: 1,
                                               cgFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                                               scale: 2,
                                               isPrimary: true)

    func testSecondaryOnRightIsMinus180() {
        let secondary = HostFixtures.display(id: 2,
                                             cgFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                                             scale: 1,
                                             isPrimary: false)
        let mapper = CoordinateMapper(displays: [primary, secondary])
        let expected = CGRect(x: 1_440, y: -180, width: 1_920, height: 1_080)

        XCTAssertEqual(OverviewWindowController.appKitFrame(for: secondary, mapper: mapper), expected)

        let controller = makeController(display: secondary, mapper: mapper)
        XCTAssertEqual(controller.appKitPanelFrame, expected, "面板必须落在按主屏高度翻转的位置")
        XCTAssertEqual(controller.contentView.frame.size, secondary.visibleFrame.size)
        XCTAssertFalse(controller.isVisible, "测试面板不得上屏")
    }

    /// 只把副屏交给 mapper（§9.1 明令禁止的写法）会得到 y = 0：这条断言保证上面的夹具真的能区分两种基准。
    func testSingleDisplayMapperWouldBeWrong() {
        let secondary = HostFixtures.display(id: 2,
                                             cgFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                                             scale: 1,
                                             isPrimary: false)
        let wrong = CoordinateMapper(displays: [secondary])
        XCTAssertEqual(OverviewWindowController.appKitFrame(for: secondary, mapper: wrong).origin.y, 0)
        XCTAssertNotEqual(OverviewWindowController.appKitFrame(for: secondary, mapper: wrong),
                          OverviewWindowController.appKitFrame(for: secondary,
                                                               mapper: CoordinateMapper(displays: [primary, secondary])))
    }

    func testSecondaryOnLeftTopAndBottom() {
        let cases: [(name: String, cg: CGRect, expected: CGRect)] = [
            ("左侧更高", CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080), CGRect(x: -1_920, y: -180, width: 1_920, height: 1_080)),
            ("左侧等高", CGRect(x: -1_440, y: 0, width: 1_440, height: 900), CGRect(x: -1_440, y: 0, width: 1_440, height: 900)),
            ("上方", CGRect(x: 0, y: -900, width: 1_440, height: 900), CGRect(x: 0, y: 900, width: 1_440, height: 900)),
            ("下方", CGRect(x: 0, y: 900, width: 1_440, height: 900), CGRect(x: 0, y: -900, width: 1_440, height: 900)),
            // 主屏在右下、副屏更矮：翻转基准仍是主屏高度 900。
            ("右下副屏较矮", CGRect(x: 1_440, y: 200, width: 1_280, height: 720), CGRect(x: 1_440, y: -20, width: 1_280, height: 720))
        ]
        for item in cases {
            let secondary = HostFixtures.display(id: 2, cgFrame: item.cg, scale: 2, isPrimary: false)
            let mapper = CoordinateMapper(displays: [primary, secondary])
            let controller = makeController(display: secondary, mapper: mapper)
            XCTAssertEqual(controller.appKitPanelFrame, item.expected, item.name)
            XCTAssertEqual(controller.contentView.frame.origin, .zero, item.name)
            XCTAssertEqual(controller.appKitPanelFrame.origin.y,
                           OverviewWindowController.appKitFrame(for: secondary, mapper: mapper).origin.y,
                           item.name)
        }
    }

    // MARK: - 1x / 2x 混合：倍率改变画面基准，不改变面板位置

    func testMixedBackingScaleKeepsFrameAndAppliesScale() {
        let secondary = HostFixtures.display(id: 2,
                                             cgFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                                             scale: 1,
                                             isPrimary: false)
        let mapper = CoordinateMapper(displays: [primary, secondary])
        let controller = makeController(display: secondary, mapper: mapper)
        let frame = controller.appKitPanelFrame
        XCTAssertEqual(controller.contentView.metalLayer.contentsScale, 1)
        XCTAssertEqual(controller.contentView.metalLayer.drawableSize, CGSize(width: 1_920, height: 1_080))

        // 同一块屏改成 2x：位置不动，倍率与 drawableSize 必须一起改。
        let retina = HostFixtures.display(id: 2,
                                          cgFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                                          scale: 2,
                                          isPrimary: false)
        controller.updateDisplay(retina, mapper: CoordinateMapper(displays: [primary, retina]))
        XCTAssertEqual(controller.appKitPanelFrame, frame, "倍率变化不该移动面板")
        XCTAssertEqual(controller.contentView.metalLayer.contentsScale, 2)
        XCTAssertEqual(controller.contentView.metalLayer.drawableSize, CGSize(width: 3_840, height: 2_160))
    }

    // MARK: - §9.1 同一块屏的几何变化要走更新路径，不能停在初始化时的值

    func testUpdateDisplayAppliesNewGeometryAndIgnoresOtherDisplay() {
        let secondary = HostFixtures.display(id: 2,
                                             cgFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                                             scale: 2,
                                             isPrimary: false)
        let controller = makeController(display: secondary, mapper: CoordinateMapper(displays: [primary, secondary]))
        let before = controller.appKitPanelFrame
        XCTAssertEqual(before.origin.y, -180)

        // 副屏换成更矮的分辨率：翻转基准仍是主屏 900，于是 y = 900 - 0 - 700 = 200。
        let resized = HostFixtures.display(id: 2,
                                           cgFrame: CGRect(x: 1_440, y: 0, width: 1_600, height: 700),
                                           scale: 2,
                                           isPrimary: false)
        controller.updateDisplay(resized, mapper: CoordinateMapper(displays: [primary, resized]))
        XCTAssertEqual(controller.appKitPanelFrame, CGRect(x: 1_440, y: 200, width: 1_600, height: 700))
        XCTAssertEqual(controller.contentView.frame.size, resized.visibleFrame.size)
        XCTAssertEqual(controller.contentView.metalLayer.drawableSize, CGSize(width: 3_200, height: 1_400))
        XCTAssertEqual(controller.frameInCG, resized.visibleFrame)

        // 别的显示器的信息不能改掉这块面板的基准（新增/移除由调用方重建控制器）。
        let other = HostFixtures.display(id: 3,
                                         cgFrame: CGRect(x: 0, y: 900, width: 1_440, height: 900),
                                         scale: 1,
                                         isPrimary: false)
        controller.updateDisplay(other, mapper: CoordinateMapper(displays: [primary, other]))
        XCTAssertEqual(controller.appKitPanelFrame, CGRect(x: 1_440, y: 200, width: 1_600, height: 700))

        // 完全相同的几何再传一次不该产生任何副作用。
        controller.updateDisplay(resized, mapper: CoordinateMapper(displays: [primary, resized]))
        XCTAssertEqual(controller.appKitPanelFrame, CGRect(x: 1_440, y: 200, width: 1_600, height: 700))
        XCTAssertNotEqual(before, controller.appKitPanelFrame)
    }

    /// 主屏自己：翻转后 y = 0，且带菜单栏的可见区高度按 visibleFrame 计算。
    func testPrimaryPanelSitsAtOrigin() {
        let withMenu = DisplayInfo(id: 1,
                                   frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                                   visibleFrame: CGRect(x: 0, y: 37, width: 1_440, height: 863),
                                   backingScale: 2,
                                   isPrimary: true)
        let mapper = CoordinateMapper(displays: [withMenu])
        let controller = makeController(display: withMenu, mapper: mapper)
        XCTAssertEqual(controller.appKitPanelFrame, CGRect(x: 0, y: 0, width: 1_440, height: 863))
        XCTAssertEqual(controller.contentView.frame.size, CGSize(width: 1_440, height: 863))
    }
}
