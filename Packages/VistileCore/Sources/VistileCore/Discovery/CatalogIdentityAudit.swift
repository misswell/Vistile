import Foundation

/// 目录身份的客观判据（P0-1）。
///
/// AX 索引只在"同一个进程的窗口列表"里有意义：句柄表按 pid 分桶，几何写回也按 (pid, index) 取元素。
/// 因此两个不同应用各自都有索引 0 是常态，把它算成冲突是错口径；
/// 同一个进程里两个窗口解析到同一个索引才会让画面与真实窗口错位。
public enum CatalogIdentityAudit {
    public struct AXIndexClash: Hashable, Sendable {
        public let processID: Int32
        public let axIndex: Int
        /// 解析到同一个索引的捕获窗口编号，升序。
        public let windowIDs: [UInt32]
    }

    public static func axIndexClashes(in records: [WindowRecord]) -> [AXIndexClash] {
        let indexed = records.compactMap { record -> (pid: Int32, index: Int, windowID: UInt32)? in
            guard let index = record.confidence.resolvedAXIndex else { return nil }
            return (record.identity.processID, index, record.identity.windowID)
        }
        let groups = Dictionary(grouping: indexed, by: { "\($0.pid):\($0.index)" })
        return groups.values.compactMap { bucket -> AXIndexClash? in
            guard bucket.count > 1, let first = bucket.first else { return nil }
            return AXIndexClash(processID: first.pid, axIndex: first.index, windowIDs: bucket.map(\.windowID).sorted())
        }
        .sorted { ($0.processID, $0.axIndex) < ($1.processID, $1.axIndex) }
    }

    /// CGWindowID 是全局的：两个格子指向同一个编号就说明目录本身重复了。
    public static func hasUniqueWindowIDs(_ records: [WindowRecord]) -> Bool {
        Set(records.map(\.identity.windowID)).count == records.count
    }
}
