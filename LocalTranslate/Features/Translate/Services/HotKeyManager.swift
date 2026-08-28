import Foundation
import Carbon.HIToolbox
import AppKit

final class HotKeyManager {

    private static let signature: OSType = 0x4C54524E // 'LTRN'

    private var translateHotKeyRef: EventHotKeyRef?
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var translateAction: (() -> Void)?
    private var screenshotAction: (() -> Void)?

    private var lastTranslateTimestamp: TimeInterval = 0
    private var lastScreenshotTimestamp: TimeInterval = 0
    private let lock = NSLock()

    func register(
        onTranslate: @escaping () -> Void,
        onScreenshot: @escaping () -> Void
    ) {
        self.translateAction = onTranslate
        self.screenshotAction = onScreenshot

        guard let target = GetEventDispatcherTarget() else {
            return
        }

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

                // 仅响应按键按下事件 (忽略释放事件，但必须监听以保证 Carbon 状态机正常)
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

                guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                    return noErr
                }

                let now = ProcessInfo.processInfo.systemUptime

                manager.lock.lock()
                defer { manager.lock.unlock() }

                if hotKeyID.id == 1 {
                    // 划词翻译防抖 400ms
                    guard now - manager.lastTranslateTimestamp > 0.4 else {
                        return noErr
                    }
                    manager.lastTranslateTimestamp = now

                    DispatchQueue.main.async {
                        manager.translateAction?()
                    }
                } else if hotKeyID.id == 2 {
                    // 截图翻译防抖 600ms (严格在 Carbon 线程同步过滤重复连击)
                    guard now - manager.lastScreenshotTimestamp > 0.6 else {
                        return noErr
                    }
                    manager.lastScreenshotTimestamp = now

                    DispatchQueue.main.async {
                        manager.screenshotAction?()
                    }
                }

                return noErr
            },
            eventSpecs.count,
            eventSpecs,
            pointer,
            &eventHandlerRef
        )

        // 1. 划词/剪贴板翻译: ⌥⇧T (kVK_ANSI_T = 17, optionKey = 2048, shiftKey = 512)
        let translateID = EventHotKeyID(
            signature: Self.signature,
            id: 1
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(optionKey | shiftKey),
            translateID,
            target,
            0,
            &translateHotKeyRef
        )

        // 2. 截图翻译: ⌥⇧S (kVK_ANSI_S = 1, optionKey = 2048, shiftKey = 512)
        let screenshotID = EventHotKeyID(
            signature: Self.signature,
            id: 2
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(optionKey | shiftKey),
            screenshotID,
            target,
            0,
            &screenshotHotKeyRef
        )
    }

    deinit {
        if let translateHotKeyRef {
            UnregisterEventHotKey(translateHotKeyRef)
        }
        if let screenshotHotKeyRef {
            UnregisterEventHotKey(screenshotHotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
