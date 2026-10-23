import AppKit
import Carbon.HIToolbox

/// 全局快捷键只用公开 Carbon RegisterEventHotKey（方案 §11）。
/// 注册失败必须明确报告并回到菜单入口，不能假装快捷键可用。
@MainActor
final class GlobalHotKey {
    var onFire: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var binding: HotKeyBinding?
    private static let signature: OSType = 0x56495354 // "VIST"

    var isActive: Bool { ref != nil }
    /// 当前生效的组合键；设置页据此判断是否需要重新注册。
    var currentBinding: HotKeyBinding? { binding }

    init() {
        installHandlerIfNeeded()
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    @discardableResult
    func register(_ binding: HotKeyBinding) -> Bool {
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(binding.keyCode,
                                        binding.carbonModifiers,
                                        hotKeyID,
                                        GetEventDispatcherTarget(),
                                        0,
                                        &ref)
        guard status == noErr, let ref else {
            self.ref = nil
            self.binding = nil
            return false
        }
        self.ref = ref
        self.binding = binding
        return true
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        binding = nil
    }

    /// 快捷键被系统或其他 App 占用时给用户的下一步入口。
    var failureHint: String {
        "全局快捷键 \(binding?.displayString ?? "") 注册失败，请从菜单栏打开总览或在设置里换一个组合键"
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // `inUserData` 是按值保存的指针，Carbon 只记住这个值本身。
        // 传 `&context` 等于把**局部变量的地址**交给它：本方法一返回，那块栈内存就失效，
        // 之后每次按下快捷键，`fromOpaque(userData)` 读到的都是垃圾指针——
        // 实机表现就是按 ⌃⌥Space 必崩（EXC_BAD_ACCESS，栈落在 GlobalHotKey 的回调里）。
        // 因此必须直接传 `toOpaque()` 的结果，不能取它的地址。
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            guard hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let hub = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { hub.onFire?() } }
            return noErr
        }, 1, &spec, context, &handler)
        if installed != noErr { handler = nil }
    }
}
