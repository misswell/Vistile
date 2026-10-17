import Foundation
import Testing
@testable import VistileCore

/// 方案 §20.2「60Hz/120Hz、reduceMotion、冷启动/热路径分别分组」＋同节样本闸门。
/// 这里全是纯逻辑：不需要真机、不依赖桌面，判定的是"分组是否真的把不同环境的数字隔开"。
@Suite("性能样本分组与样本闸门")
struct PerformanceGroupTests {

    // MARK: - 刷新率档位

    @Test("刷新率档位：60/120 归一，其他照实，取不到不假装 60Hz")
    func refreshBuckets() {
        #expect(PerformanceGroup.refreshLabel(hz: 60.0) == "60Hz")
        // ProMotion 与 EDID 的实际读数不是整数。
        #expect(PerformanceGroup.refreshLabel(hz: 59.94) == "60Hz")
        #expect(PerformanceGroup.refreshLabel(hz: 120.0) == "120Hz")
        #expect(PerformanceGroup.refreshLabel(hz: 119.88) == "120Hz")
        #expect(PerformanceGroup.refreshLabel(hz: 90.0) == "90Hz")
        #expect(PerformanceGroup.refreshLabel(hz: 0) == "刷新率未知")
        #expect(PerformanceGroup.refreshLabel(hz: -1) == "刷新率未知")
        #expect(PerformanceGroup.refreshLabel(hz: .nan) == "刷新率未知")
    }

    @Test("本机帧间隔只是事实，不参与 §20.1 的 20ms 判据")
    func nativeIntervalIsFactNotTarget() {
        #expect(PerformanceGroup(refreshHz: 120, reduceMotion: false, coldStart: false).nativeFrameIntervalMS
                == 1000.0 / 120.0)
        #expect(PerformanceGroup(refreshHz: 60, reduceMotion: false, coldStart: false).nativeFrameIntervalMS
                == 1000.0 / 60.0)
        #expect(PerformanceGroup(refreshHz: 0, reduceMotion: false, coldStart: false).nativeFrameIntervalMS == 0)
    }

    // MARK: - 分组键

    @Test("三个维度各自都能把分组隔开，任何一维不同就不是同一个键")
    func keySeparatesEveryDimension() {
        let base = PerformanceGroup(refreshHz: 120, reduceMotion: false, coldStart: false)
        let byRefresh = PerformanceGroup(refreshHz: 60, reduceMotion: false, coldStart: false)
        let byMotion = PerformanceGroup(refreshHz: 120, reduceMotion: true, coldStart: false)
        let byStart = PerformanceGroup(refreshHz: 120, reduceMotion: false, coldStart: true)
        let keys = [base.key, byRefresh.key, byMotion.key, byStart.key]
        #expect(Set(keys).count == 4)
        #expect(base.key == "120Hz·reduceMotion=关·热路径")
        #expect(byStart.key.hasSuffix("冷启动"))
        // 环境标签不带冷热：同一开关下冷热两轮的"环境"仍是同一台机器。
        #expect(base.environmentLabel == byStart.environmentLabel)
        #expect(base.environmentLabel != byRefresh.environmentLabel)
        #expect(byMotion.environmentLabel.contains("reduceMotion=开"))
    }

    // MARK: - 样本闸门

    @Test("样本不足只标未判，够 100 条才谈达标或未达标")
    func sampleGateDecidesUndetermined() {
        let fast = Array(repeating: 10.0, count: 99)
        #expect(PerformanceGate.judge(groupKey: "g", values: fast, targetMS: 500).status == .undetermined)
        let enough = Array(repeating: 10.0, count: 100)
        let passed = PerformanceGate.judge(groupKey: "g", values: enough, targetMS: 500)
        #expect(passed.status == .pass)
        #expect(passed.count == 100)
        let slow = Array(repeating: 600.0, count: 100)
        #expect(PerformanceGate.judge(groupKey: "g", values: slow, targetMS: 500).status == .miss)
        // 零样本既不是 0ms 也不是失败。
        let none = PerformanceGate.judge(groupKey: "g", values: [], targetMS: 500)
        #expect(none.status == .undetermined)
        #expect(none.factText == "g 无样本（未判）")
    }

    @Test("P95 取 nearest-rank，不被单个离群值搬走")
    func percentileIsNearestRank() {
        let ramp = Array(stride(from: 1.0, through: 100.0, by: 1.0))
        #expect(PerformanceGate.p95(of: ramp) == 95)
        #expect(PerformanceGate.p95(of: [5, 5, 5, 5, 5, 5, 5, 5, 5, 500]) == 5)
        #expect(PerformanceGate.p95(of: []).isNaN)
    }

    @Test("分组指标名：生产侧写什么，读取侧就取回什么；形状不对只还 nil")
    func metricNameRoundTrips() {
        let group = PerformanceGroup(refreshHz: 119.88, reduceMotion: false, coldStart: true)
        let base = "过渡帧间隔p95·总览→L 型"
        let qualified = PerformanceMetricName.qualified(base, group: group)
        #expect(qualified == "\(base)·\(group.key)")
        // summary() 会在 measure 名后再拼「 p95」，读取侧按同一个常量识别这个尾巴。
        #expect(PerformanceMetricName.groupKey(fromSummaryRow: qualified + PerformanceMetricName.summarySuffix, base: base) == group.key)
        #expect(PerformanceMetricName.groupKey(fromCounterName: PerformanceMetricName.qualified("过渡有效帧间隔·总览→L 型", group: group),
                                               base: "过渡有效帧间隔·总览→L 型") == group.key)
        // 这三种形状都不许猜出一个键：漏尾巴、别的族、空分组键。
        // 猜出来会把别的族的样本读成这一族的，或让"P0-18 一行都没有"看起来像产品没跑。
        #expect(PerformanceMetricName.groupKey(fromSummaryRow: qualified, base: base) == nil)
        #expect(PerformanceMetricName.groupKey(fromSummaryRow: "过渡首帧延迟·总览→L 型·\(group.key) p95", base: base) == nil)
        #expect(PerformanceMetricName.groupKey(fromSummaryRow: "\(base)· p95", base: base) == nil)
        #expect(PerformanceMetricName.groupKey(fromCounterName: "过渡零呈现段", base: "过渡帧预算内") == nil)
        #expect(PerformanceMetricName.groupKey(fromCounterName: "\(base)·", base: base) == nil)
    }

    /// 分组存在的理由：冷热混池会把一个达标的热路径和一个超时的冷启动平均成同一个数字。
    @Test("分组后热路径达标与冷启动未判各自成立，混池会互相掩盖")
    func groupedVerdictsDoNotMaskEachOther() {
        let hot = PerformanceGroup(refreshHz: 120, reduceMotion: false, coldStart: false)
        let cold = PerformanceGroup(refreshHz: 120, reduceMotion: false, coldStart: true)
        let hotValues = Array(repeating: 120.0, count: 100)
        let coldValues = [900.0]
        let hotVerdict = PerformanceGate.judge(groupKey: hot.key, values: hotValues, targetMS: 500)
        let coldVerdict = PerformanceGate.judge(groupKey: cold.key, values: coldValues, targetMS: 500)
        #expect(hotVerdict.status == .pass)
        #expect(coldVerdict.status == .undetermined)
        // 混池（把两段并进一组）得到的样本数是 101、p95 仍算得出来，但那条 900ms 的冷启动
        // 就从"单独一条未判的样本"变成"藏在热路径达标里看不见的东西"——这就是 §20.2 要分组的原因。
        #expect(PerformanceGate.judge(groupKey: "混池", values: hotValues + coldValues, targetMS: 500).status == .pass)
        #expect(coldVerdict.factText.contains("n=1"))
        #expect(coldVerdict.factText.contains("未判"))
    }
}
