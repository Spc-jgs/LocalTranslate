import Foundation
import Combine
import Carbon.HIToolbox
import AppKit

/// 一个全局快捷键的完整定义。
///
/// 原先四个快捷键各有一份 ref、action、时间戳和防抖分支，注册代码也复制了
/// 四遍；新增或改键必须同时改五个地方。现在只需要在这里加一个 case。
nonisolated enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {

    case translateSelection
    case miniHUD
    case screenshotOCR
    case liveSubtitles

    var id: String { rawValue }

    /// Carbon `EventHotKeyID` 的数值标识，注册后不可更改。
    var hotKeyID: UInt32 {
        switch self {
        case .translateSelection: return 1
        case .screenshotOCR: return 2
        case .liveSubtitles: return 3
        case .miniHUD: return 4
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .translateSelection: return UInt32(kVK_ANSI_T)
        case .miniHUD: return UInt32(kVK_ANSI_D)
        case .screenshotOCR: return UInt32(kVK_ANSI_S)
        case .liveSubtitles: return UInt32(kVK_ANSI_C)
        }
    }

    var modifiers: UInt32 {
        UInt32(optionKey | shiftKey)
    }

    /// 连按抑制窗口。截图与字幕启动较重，给更长的间隔。
    var debounceInterval: TimeInterval {
        switch self {
        case .translateSelection, .miniHUD: return 0.4
        case .screenshotOCR, .liveSubtitles: return 0.6
        }
    }

    var title: String {
        switch self {
        case .translateSelection: return "划词翻译 / 打开浮窗"
        case .miniHUD: return "划词气泡"
        case .screenshotOCR: return "截图 OCR 翻译"
        case .liveSubtitles: return "实时字幕"
        }
    }

    var displayShortcut: String {
        switch self {
        case .translateSelection: return "⌥ ⇧ T"
        case .miniHUD: return "⌥ ⇧ D"
        case .screenshotOCR: return "⌥ ⇧ S"
        case .liveSubtitles: return "⌥ ⇧ C"
        }
    }
}

/// 快捷键注册结果，供设置界面展示。
///
/// `RegisterEventHotKey` 的返回值原先被全部丢弃：某个组合已被其他 App 占用
/// 时用户只会觉得「按了没反应」，没有任何提示。
@MainActor
final class HotKeyRegistry: ObservableObject {

    static let shared = HotKeyRegistry()

    @Published private(set) var unavailableActions: Set<HotKeyAction> = []

    private init() {}

    func update(unavailable: Set<HotKeyAction>) {
        unavailableActions = unavailable
    }

    func isAvailable(_ action: HotKeyAction) -> Bool {
        !unavailableActions.contains(action)
    }
}

final class HotKeyManager {

    private static let signature: OSType = 0x4C54524E // 'LTRN'

    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private var actions: [UInt32: (action: HotKeyAction, handler: () -> Void)] = [:]
    private var lastFiredAt: [UInt32: TimeInterval] = [:]
    private let lock = NSLock()

    /// 注册全部快捷键，返回未能注册成功的动作。
    @discardableResult
    func register(
        handlers: [HotKeyAction: () -> Void]
    ) -> Set<HotKeyAction> {

        lock.lock()
        for (action, handler) in handlers {
            actions[action.hotKeyID] = (action, handler)
        }
        lock.unlock()

        guard let target = GetEventDispatcherTarget() else {
            return Set(handlers.keys)
        }

        installHandlerIfNeeded(target: target)

        var unavailable: Set<HotKeyAction> = []

        for action in HotKeyAction.allCases where handlers[action] != nil {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                action.keyCode,
                action.modifiers,
                EventHotKeyID(
                    signature: Self.signature,
                    id: action.hotKeyID
                ),
                target,
                0,
                &ref
            )

            if status == noErr, let ref {
                hotKeyRefs[action] = ref
            } else {
                // 通常是该组合已被其他 App 抢占。
                unavailable.insert(action)
            }
        }

        return unavailable
    }

    private func installHandlerIfNeeded(target: EventTargetRef) {
        guard eventHandlerRef == nil else { return }

        let eventSpecs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        let pointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            target,
            { _, inEvent, userData in
                guard let inEvent, let userData else {
                    return noErr
                }

                // 仅响应按键按下事件
                guard GetEventKind(inEvent) == UInt32(kEventHotKeyPressed) else {
                    return noErr
                }

                let manager = Unmanaged<HotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    inEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == HotKeyManager.signature else {
                    return noErr
                }

                manager.fire(hotKeyID.id)
                return noErr
            },
            eventSpecs.count,
            eventSpecs,
            pointer,
            &eventHandlerRef
        )
    }

    private func fire(_ hotKeyID: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        guard let entry = actions[hotKeyID] else {
            lock.unlock()
            return
        }

        let last = lastFiredAt[hotKeyID] ?? 0
        guard now - last > entry.action.debounceInterval else {
            lock.unlock()
            return
        }
        lastFiredAt[hotKeyID] = now
        let handler = entry.handler
        lock.unlock()

        DispatchQueue.main.async {
            handler()
        }
    }

    deinit {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
