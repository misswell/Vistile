import Foundation
import VistileCore

/// 所有真实窗口几何变更的唯一入口（方案 §5.1–§5.5、§14.2）。
///
/// 为什么要单独一层：原先每处写入各自起 `Task`/`tail` 链，取消只能翻转布尔标志，
/// 已经排进 AX 队列的命令照样执行。这里把"准入 → 排队 → 执行 → 结算"收进一条串行通道：
/// - 会话相位 + 单调代次：旧代次的普通操作连准入都拿不到；
/// - 单条串行通道天然保证同一身份的 写入 → 读回 → 日志 → 补偿 顺序，
///   也不会出现两条并发 AX 写流互相覆盖；
/// - 取消屏障只撤销普通操作许可；补偿与会话恢复走独立授权，撤销之后仍能准入；
/// - 带预算的作业在出队时先查预算，预算归零就绝不开始新的 AX 写入。
@MainActor
final class GeometryOperationScheduler {

    /// 单调时间戳（纳秒）。生产值来自 `ContinuousClock`，测试可注入可控时钟。
    struct Stamp: Comparable, Sendable {
        let nanoseconds: UInt64
        static func < (lhs: Stamp, rhs: Stamp) -> Bool { lhs.nanoseconds < rhs.nanoseconds }
    }

    /// 作业被丢弃的原因：调用方据此保留日志事实，而不是当作"什么都没发生"。
    enum Skip: Hashable, Sendable {
        case cancelled
        case sessionChanged
        case budgetExpired
    }

    /// 一个已排队的操作。许可在准入时创建，闭包真正执行前还会再查一次。
    struct Operation {
        let context: GeometryOperationContext
        let identities: [WindowIdentity]
        /// latest-wins 合并键：同一个键只允许一个"尚未执行"的目标留在队列里。
        let coalesceKey: String?
        /// 预算截止：到点还没开始就不开始（恢复与退出共用一份预算，方案 §14.2）。
        let deadline: Stamp?
        let run: (GeometryWritePermit) async -> Void
        /// 被丢弃时的补偿性回调：只在主线程调用。
        let onSkipped: ((Skip) -> Void)?

        init(context: GeometryOperationContext,
             identities: [WindowIdentity],
             coalesceKey: String? = nil,
             deadline: Stamp? = nil,
             onSkipped: ((Skip) -> Void)? = nil,
             run: @escaping (GeometryWritePermit) async -> Void) {
            self.context = context
            self.identities = identities
            self.coalesceKey = coalesceKey
            self.deadline = deadline
            self.onSkipped = onSkipped
            self.run = run
        }
    }

    private struct Ticket {
        let operation: Operation
        let permit: GeometryWritePermit
    }

    private struct Record {
        let kind: GeometryOperationKind
        let permit: GeometryWritePermit
        var started: Bool
    }

    private struct FenceWaiter {
        let identities: Set<String>
        let continuation: CheckedContinuation<Void, Never>
    }

    private var monotonicNow: () -> Stamp

    /// 会话标识与代次：代次只在取消屏障处单调增加，永不复用。
    private var sessionIDValue = UUID()
    private(set) var sessionEpoch: UInt64 = 0
    private(set) var phase: GeometrySessionPhase = .closed

    private var pending: [Ticket] = []
    private var running: Ticket?
    /// 当前正站在通道里执行（深度 > 0）：此时代码已经在队列头部，
    /// 再排队一个子操作会自己等自己，必须就地执行（方案 §5.3）。
    private var laneDepth = 0
    private var lane: Task<Void, Never>?
    private var records: [UUID: Record] = [:]
    /// 撤销后仍需补偿的操作：写过窗口的事实不能因为取消而消失（方案 §5.2）。
    private(set) var operationsNeedingCompensation: Set<UUID> = []
    private var fences: [FenceWaiter] = []
    /// 补偿决策已做出、尚未落成队列项的占位：这段时间也算忙（方案 §6.1）。
    private var compensationReservations: Set<UUID> = []
    /// 拒绝准入的次数：只用于诊断与断言，不参与调度决策。
    private(set) var admissionRejections = 0

    init(now: (() -> Stamp)? = nil) {
        if let now {
            monotonicNow = now
            return
        }
        // 单调时钟：从对象创建那一刻起算，不受系统时间被调整影响（方案 §14）。
        let reference = ContinuousClock.now
        monotonicNow = { Self.stamp(reference.duration(to: ContinuousClock.now)) }
    }

    private static func stamp(_ duration: Duration) -> Stamp {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let attoseconds = UInt64(max(0, components.attoseconds))
        return Stamp(nanoseconds: seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue
                                        + attoseconds / 1_000_000_000)
    }

    // MARK: - 会话生命周期

    /// 开启新会话：返回的 sessionID 是之后所有上下文与取消屏障的凭据。
    @discardableResult
    func openSession() -> UUID {
        // 旧会话的未执行计划一律作废；旧会话的真实写入事实由日志负责，不靠内存队列。
        revokePermits(ordinaryOnly: false)
        pending.removeAll()
        compensationReservations.removeAll()
        records.removeAll()
        sessionIDValue = UUID()
        sessionEpoch = 0
        operationsNeedingCompensation.removeAll()
        phase = .open
        drainFences()
        return sessionIDValue
    }

    var sessionID: UUID { sessionIDValue }

    /// 采用状态机的会话身份（方案 §5.3）：操作上下文由 reducer 用自己的 sessionID/epoch 生成，
    /// 调度器必须对齐同一份身份，否则真实写入连准入都拿不到。
    ///
    /// 只做两件事，语义与既有入口完全一致：
    /// - 会话换了：等同 `openSession()`，旧会话未执行的计划一律作废，但用状态机给的 sessionID；
    /// - 只是代次涨了：等同取消屏障，撤销普通许可、丢弃未开始的普通计划。
    /// 单调性由状态机保证（epoch 只增不减），这里不回退、不复用。
    func adopt(sessionID newSessionID: UUID, epoch newEpoch: UInt64) {
        if newSessionID != sessionIDValue {
            _ = openSession()
            sessionIDValue = newSessionID
            sessionEpoch = newEpoch
            return
        }
        guard newEpoch != sessionEpoch else { return }
        if newEpoch < sessionEpoch {
            // 代次倒退说明两边各自数了一次：宁可拒绝采纳，也不能让旧事件重新获得准入。
            admissionRejections += 1
            return
        }
        sessionEpoch = newEpoch
        dropPending { $0.isOrdinary }
        revokePermits(ordinaryOnly: true)
        drainFences()
    }

    /// 相位推进：关闭与恢复阶段只放行非普通授权（补偿、会话恢复）。
    /// 这里不动代次——代次只由状态机经 `adopt` 推进，否则调度器与状态机各数一次，
    /// 真实写入会永远拿不到准入（方案 §5.1、§15）。
    func advance(to next: GeometrySessionPhase) {
        phase = next
        switch next {
        case .open:
            break
        case .closing, .restoring, .closed:
            // 停止接收普通操作：丢弃未开始的普通计划、撤销已发出的普通许可。
            dropPending { $0.isOrdinary }
            revokePermits(ordinaryOnly: true)
        }
        drainFences()
    }

    /// 当前单调时间：预算计算与测试注入点。
    var now: Stamp { monotonicNow() }

    /// 由真实 `ContinuousClock` 时长换算的截止点，供退出流程分配共享预算。
    func deadline(after duration: Duration) -> Stamp {
        Stamp(nanoseconds: now.nanoseconds &+ duration.totalNanoseconds)
    }

    func remaining(until deadline: Stamp?) -> UInt64 {
        guard let deadline else { return .max }
        let current = now
        return deadline > current ? deadline.nanoseconds - current.nanoseconds : 0
    }

    /// 每一次新的 AX 写入前都要问一次（方案 §14.2）：没有预算就绝不落笔。
    func canStartNewWrite(deadline: Stamp?) -> Bool {
        guard deadline != nil else { return true }
        return remaining(until: deadline) > 0
    }

    // MARK: - 准入

    /// 为上下文创建写入许可；会话、代次或相位不符时返回 nil。
    func begin(_ context: GeometryOperationContext) -> GeometryWritePermit? {
        guard isAdmissible(context) else {
            admissionRejections += 1
            return nil
        }
        let permit = GeometryWritePermit()
        records[context.operationID] = Record(kind: context.kind, permit: permit, started: false)
        return permit
    }

    /// 现场构造上下文：sessionID/epoch 一律取调度器当前值，避免调用方手抄旧代次。
    func makeContext(token: TransitionToken, kind: GeometryOperationKind) -> GeometryOperationContext {
        GeometryOperationContext(sessionID: sessionIDValue,
                                 sessionEpoch: sessionEpoch,
                                 operationID: UUID(),
                                 transitionToken: token,
                                 kind: kind)
    }

    private func isAdmissible(_ context: GeometryOperationContext) -> Bool {
        guard context.matches(sessionID: sessionIDValue, epoch: sessionEpoch) else { return false }
        switch (phase, context.kind.isOrdinary) {
        case (.open, _): return true
        case (.closing, false), (.restoring, false): return true
        default: return false
        }
    }

    // MARK: - 排队

    /// 排队执行；返回 false 表示未准入，调用方必须按"没有发生过写入"处理。
    @discardableResult
    func perform(_ operation: Operation) -> Bool {
        guard let permit = begin(operation.context) else { return false }
        if operation.context.kind.isOrdinary, let key = operation.coalesceKey,
           let index = pending.firstIndex(where: { $0.operation.coalesceKey == key }) {
            // latest-wins：同一目标只保留最后一个未执行计划；被替换项尚未动过窗口。
            let replaced = pending.remove(at: index)
            skip(replaced, reason: .cancelled)
        }
        pending.append(Ticket(operation: operation, permit: permit))
        pump()
        return true
    }

    /// 取消屏障：撤销普通许可、丢弃尚未开始的普通计划。
    /// 已经在写的操作只撤许可（阻止它继续写下一个属性），"写过"的事实保留给补偿。
    /// 代次不在这里递增：它由状态机推进后经 `adopt` 下发，两处各自加一次会让写入永远失配。
    @discardableResult
    func cancelOrdinaryWrites(sessionID: UUID) -> UInt64 {
        guard sessionID == sessionIDValue else { return sessionEpoch }
        dropPending { $0.isOrdinary }
        for (operationID, record) in records where record.kind.isOrdinary {
            record.permit.revoke()
            if record.started { operationsNeedingCompensation.insert(operationID) }
        }
        drainFences()
        return sessionEpoch
    }

    /// 某个操作是否已经开始真实写入（补偿准入判断用）。
    func didStartWrite(operationID: UUID) -> Bool {
        records[operationID]?.started == true
    }

    /// 补偿阶段占位：从"决定补偿"到"补偿排进队列"之间不能被判为空闲。
    func reserveCompensation(for context: GeometryOperationContext) -> Bool {
        guard !context.kind.isOrdinary else { return false }
        compensationReservations.insert(context.operationID)
        return true
    }

    func releaseCompensation(operationID: UUID) {
        compensationReservations.remove(operationID)
        operationsNeedingCompensation.remove(operationID)
        drainFences()
    }

    var hasPendingCompensation: Bool { !compensationReservations.isEmpty }

    /// 是否正处在通道内：调用方据此判断"还能不能就地嵌套一个子操作"。
    var isInsideChannel: Bool { laneDepth > 0 }

    /// 排队并等待结果；未准入或作业被丢弃时返回 nil，调用方据此保留事务/日志（方案 §5.4）。
    /// 恢复与补偿都走这里：把"许可、相位、代次、预算、顺序"一次性交给调度器。
    /// 已经在通道里时就地执行：串行队列不会自等自。
    func request<T: Sendable>(context: GeometryOperationContext,
                              identities: [WindowIdentity],
                              coalesceKey: String? = nil,
                              deadline: Stamp? = nil,
                              work: @escaping (GeometryWritePermit) async -> T) async -> T? {
        let shot = OneShot<T?>()
        let operation = Operation(context: context,
                                  identities: identities,
                                  coalesceKey: coalesceKey,
                                  deadline: deadline,
                                  onSkipped: { _ in shot.send(nil) },
                                  run: { permit in shot.send(await work(permit)) })
        if laneDepth > 0 {
            guard let permit = begin(context) else { return nil }
            guard canStartNewWrite(deadline: deadline) else {
                operation.onSkipped?(.budgetExpired)
                return nil
            }
            laneDepth += 1
            defer { laneDepth -= 1 }
            return await work(permit)
        }
        guard perform(operation) else { return nil }
        return await withCheckedContinuation { continuation in
            shot.attach(continuation)
        }
    }

    // MARK: - 栅栏与排空

    /// 等这些身份的排队/在途工作全部结束；退出与恢复必须站在栅栏之后（方案 §14.2）。
    func fence(identities: [WindowIdentity]) async {
        let wanted = Set(identities.map(\.journalKey))
        guard !isQuiet(for: wanted) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            fences.append(FenceWaiter(identities: wanted, continuation: continuation))
            drainFences()
        }
    }

    /// 等整条通道静默；预算到点仍未静默则返回 false（调用方据此保留日志并停止）。
    func drain(until deadline: Stamp?) async -> Bool {
        while !isIdle {
            if let deadline, remaining(until: deadline) == 0 { return false }
            await fence(identities: [])
        }
        return true
    }

    /// 空闲 = 队列空 + 无在途 + 无补偿占位（方案 §5.4）。
    var isIdle: Bool {
        running == nil && pending.isEmpty && compensationReservations.isEmpty
    }

    /// 忙在哪：诊断面板与测试断言用。
    var busyDescription: String {
        if let running { return "在途:\(running.operation.context.kind.rawValue)" }
        if !pending.isEmpty { return "排队:\(pending.count)" }
        if !compensationReservations.isEmpty { return "待补偿:\(compensationReservations.count)" }
        return "空闲"
    }

    var queuedCount: Int { pending.count }
    var inFlightCount: Int { running == nil ? 0 : 1 }

    // MARK: - 串行通道

    private func pump() {
        guard lane == nil else { return }
        lane = Task { [weak self] in
            while let ticket = await self?.takeNext() {
                await self?.execute(ticket)
            }
            await self?.laneDidFinish()
        }
    }

    /// 出队时复查：入队时有效不代表现在仍有效（这是原缺陷的正解）。
    private func takeNext() -> Ticket? {
        guard running == nil else { return nil }
        while !pending.isEmpty {
            let ticket = pending.removeFirst()
            let context = ticket.operation.context
            guard context.sessionID == sessionIDValue else {
                skip(ticket, reason: .sessionChanged)
                continue
            }
            if context.kind.isOrdinary {
                guard ticket.permit.isGranted, context.sessionEpoch == sessionEpoch, phase == .open else {
                    skip(ticket, reason: .cancelled)
                    continue
                }
            } else {
                guard ticket.permit.isGranted else {
                    skip(ticket, reason: .cancelled)
                    continue
                }
            }
            guard canStartNewWrite(deadline: ticket.operation.deadline) else {
                skip(ticket, reason: .budgetExpired)
                continue
            }
            running = ticket
            records[context.operationID]?.started = true
            return ticket
        }
        return nil
    }

    private func execute(_ ticket: Ticket) async {
        laneDepth += 1
        defer { laneDepth -= 1 }
        await ticket.operation.run(ticket.permit)
        let operationID = ticket.operation.context.operationID
        running = nil
        records[operationID] = nil
        compensationReservations.remove(operationID)
        operationsNeedingCompensation.remove(operationID)
        drainFences()
        if !pending.isEmpty { pump() }
    }

    private func laneDidFinish() {
        lane = nil
        drainFences()
    }

    /// 丢弃一个尚未执行的队列项：撤销前只可能没写过窗口，因此不需要补偿事实。
    private func skip(_ ticket: Ticket, reason: Skip) {
        ticket.permit.revoke()
        records[ticket.operation.context.operationID] = nil
        compensationReservations.remove(ticket.operation.context.operationID)
        ticket.operation.onSkipped?(reason)
    }

    private func dropPending(where predicate: (GeometryOperationKind) -> Bool) {
        pending.removeAll { ticket in
            guard predicate(ticket.operation.context.kind) else { return false }
            skip(ticket, reason: .cancelled)
            return true
        }
    }

    private func revokePermits(ordinaryOnly: Bool) {
        for (operationID, record) in records {
            if ordinaryOnly, !record.kind.isOrdinary { continue }
            record.permit.revoke()
            if record.started { operationsNeedingCompensation.insert(operationID) }
        }
    }

    // MARK: - 栅栏结算

    private func isQuiet(for identities: Set<String>) -> Bool {
        if identities.isEmpty { return isIdle }
        if let running,
           !Set(running.operation.identities.map(\.journalKey)).isDisjoint(with: identities) { return false }
        return !pending.contains {
            !Set($0.operation.identities.map(\.journalKey)).isDisjoint(with: identities)
        }
    }

    private func drainFences() {
        guard !fences.isEmpty else { return }
        var remaining: [FenceWaiter] = []
        for fence in fences {
            if isQuiet(for: fence.identities) { fence.continuation.resume() } else { remaining.append(fence) }
        }
        fences = remaining
    }
}

extension Duration {
    /// `Duration` 没有公开的纳秒取值；按分量换算，够调度器用。
    var totalNanoseconds: UInt64 {
        let components = self.components
        let seconds = UInt64(max(0, components.seconds))
        let attoseconds = UInt64(max(0, components.attoseconds))
        return seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue
            + attoseconds / 1_000_000_000
    }
}

/// 至多一次的取值通道：先有结果或先有等待者都只恢复一次。
final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var value: T?
    private var delivered = false

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if delivered, let value {
            self.value = nil
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func send(_ value: T) {
        lock.lock()
        if delivered {
            lock.unlock()
            return
        }
        delivered = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            self.value = value
            lock.unlock()
        }
    }
}
