import Foundation
import CoreGraphics

public struct MatchWeights: Hashable, Sendable {
    public var geometry: Double
    public var title: Double
    public var role: Double

    public init(geometry: Double = 0.62, title: Double = 0.28, role: Double = 0.10) {
        self.geometry = geometry
        self.title = title
        self.role = role
    }

    public var total: Double { geometry + title + role }
}

public struct MatchThresholds: Hashable, Sendable {
    public var acceptScore: Double
    /// 两个候选分数差小于该值即视为无法唯一映射，禁止任选其一。
    public var ambiguityDelta: Double
    /// 窗口边框造成的尺寸差异容差（pt）。
    public var frameTolerance: CGFloat
    /// 中心距离衰减基准（pt）。
    public var centerFalloff: CGFloat

    public init(acceptScore: Double = 0.55,
                ambiguityDelta: Double = 0.05,
                frameTolerance: CGFloat = 6,
                centerFalloff: CGFloat = 48) {
        self.acceptScore = acceptScore
        self.ambiguityDelta = ambiguityDelta
        self.frameTolerance = frameTolerance
        self.centerFalloff = centerFalloff
    }
}

/// 捕获窗口与 AX 窗口的一对一关联（方案 §6.2-§6.4）。
public enum WindowMatcher {
    public static func match(capture: [CaptureWindowSnapshot],
                             ax: [AXWindowSnapshot],
                             weights: MatchWeights = MatchWeights(),
                             thresholds: MatchThresholds = MatchThresholds()) -> [WindowIdentity: MatchConfidence] {
        guard !capture.isEmpty, !ax.isEmpty else {
            return Dictionary(uniqueKeysWithValues: capture.map { ($0.identity, MatchConfidence.unmatched) })
        }

        // 标题唯一先配对：窗口服务器的几何提交可能明显晚于 AX 一侧（实测约 0.6s），
        // 刚被移动的窗口在提交落地前两侧各报各的 frame，按几何打分会掉到接受阈值以下、
        // 被误判成"不可唯一确定"。进程内标题精确相等且两边各只有一张时身份是确定的（方案 §6.2）。
        var pairByTitle: [Int: Int] = [:]
        var pairedAX: Set<Int> = []
        var captureByTitle: [String: [Int]] = [:]
        for (ci, c) in capture.enumerated() {
            guard let key = normalizedTitle(c.title) else { continue }
            captureByTitle[key, default: []].append(ci)
        }
        var axByTitle: [String: [Int]] = [:]
        for candidate in ax where !candidate.isSheetLike {
            guard let key = normalizedTitle(candidate.title) else { continue }
            axByTitle[key, default: []].append(candidate.index)
        }
        for (key, captureIndices) in captureByTitle {
            guard captureIndices.count == 1, let captureIndex = captureIndices.first,
                  let axIndices = axByTitle[key], axIndices.count == 1, let axIndex = axIndices.first else { continue }
            pairByTitle[captureIndex] = axIndex
            pairedAX.insert(axIndex)
        }

        var pairs: [(captureIndex: Int, axIndex: Int, score: Double)] = []
        pairs.reserveCapacity(capture.count * ax.count)
        for (ci, c) in capture.enumerated() where pairByTitle[ci] == nil {
            for candidate in ax where !pairedAX.contains(candidate.index) {
                pairs.append((ci, candidate.index, score(capture: c, ax: candidate, weights: weights, thresholds: thresholds)))
            }
        }

        // 固定排序，保证同一输入永远得到同一结果（分数相同按索引决胜）。
        pairs.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.captureIndex != $1.captureIndex { return $0.captureIndex < $1.captureIndex }
            return $0.axIndex < $1.axIndex
        }

        var assignedCapture: [Int: (axIndex: Int, score: Double)] = [:]
        var claimedAX: Set<Int> = []
        for pair in pairs where pair.score >= thresholds.acceptScore {
            guard assignedCapture[pair.captureIndex] == nil, !claimedAX.contains(pair.axIndex) else { continue }
            assignedCapture[pair.captureIndex] = (pair.axIndex, pair.score)
            claimedAX.insert(pair.axIndex)
        }

        var result: [WindowIdentity: MatchConfidence] = [:]
        for (ci, snapshot) in capture.enumerated() {
            // 标题配对的窗口直接确定；分数照记（可能因窗口还在移动中而偏低，它是观测事实不是判据）。
            if let axIndex = pairByTitle[ci], let candidate = ax.first(where: { $0.index == axIndex }) {
                result[snapshot.identity] = .unique(score: score(capture: snapshot, ax: candidate,
                                                                 weights: weights, thresholds: thresholds),
                                                    axIndex: axIndex)
                continue
            }
            var scored: [(index: Int, value: Double)] = []
            scored.reserveCapacity(ax.count)
            for candidate in ax where !pairedAX.contains(candidate.index) {
                scored.append((candidate.index, score(capture: snapshot, ax: candidate,
                                                      weights: weights, thresholds: thresholds)))
            }
            let alternatives = scored
                .filter { $0.value >= thresholds.acceptScore }
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.index < rhs.index
                }

            guard let best = alternatives.first else {
                result[snapshot.identity] = .unmatched
                continue
            }
            let runnerUp = alternatives.dropFirst().first
            if let runnerUp, best.value - runnerUp.value <= thresholds.ambiguityDelta {
                result[snapshot.identity] = .ambiguous(alternatives: [best.index, runnerUp.index])
                continue
            }
            guard let assigned = assignedCapture[ci], assigned.axIndex == best.index else {
                // 另一个捕获窗口在竞争同一个 AX 窗口：至少有一个映射会错，宁可都不控制。
                result[snapshot.identity] = .ambiguous(alternatives: [best.index])
                continue
            }
            result[snapshot.identity] = .unique(score: best.value, axIndex: best.index)
        }
        return result
    }

    static func score(capture: CaptureWindowSnapshot,
                      ax: AXWindowSnapshot,
                      weights: MatchWeights,
                      thresholds: MatchThresholds) -> Double {
        guard !ax.isSheetLike else { return 0 }
        let normalized = max(weights.total, 0.0001)
        var total = 0.0

        if let axFrame = ax.frame {
            total += weights.geometry * geometryScore(captureFrame: capture.frame, axFrame: axFrame, thresholds: thresholds)
        } else {
            // 读不到 AX frame 时只给一半几何分，避免仅凭标题就断言唯一。
            total += weights.geometry * 0.5
        }
        total += weights.title * titleScore(capture.title, ax.title)
        total += weights.role * roleScore(ax)
        return total / normalized
    }

    private static func geometryScore(captureFrame: CGRect, axFrame: CGRect, thresholds: MatchThresholds) -> Double {
        let centerDistance = hypot(captureFrame.midX - axFrame.midX, captureFrame.midY - axFrame.midY)
        let centerScore = max(0, 1 - Double(centerDistance / max(thresholds.centerFalloff, 1)))

        let widthDelta = abs(captureFrame.width - axFrame.width)
        let heightDelta = abs(captureFrame.height - axFrame.height)
        let reference = max(captureFrame.width, captureFrame.height, axFrame.width, axFrame.height, 1)
        let worstDelta = max(widthDelta, heightDelta)
        let sizeScore = worstDelta <= thresholds.frameTolerance
            ? 1
            : max(0, 1 - Double((worstDelta - thresholds.frameTolerance) / reference))
        return 0.6 * centerScore + 0.4 * sizeScore
    }

    /// 标题为空不参与标题配对（普通无标题窗口靠几何区分）。
    private static func normalizedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// 标题为空不扣分到 0：普通无标题窗口不能因标题为空而被误排除。
    private static func titleScore(_ lhs: String, _ rhs: String) -> Double {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty && b.isEmpty { return 0.5 }
        if a.isEmpty || b.isEmpty { return 0.25 }
        return a.caseInsensitiveCompare(b) == .orderedSame ? 1 : 0
    }

    private static func roleScore(_ ax: AXWindowSnapshot) -> Double {
        switch ax.subrole {
        case "AXStandardWindow": return 1
        case .none: return 0.5
        default: return 0.25
        }
    }
}
