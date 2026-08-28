import Foundation
import Carbon.HIToolbox

final class HotKeyManager {

    private var translateHotKeyRef: EventHotKeyRef?
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var translateAction: (() -> Void)?
    private var screenshotAction: (() -> Void)?

    func register(
        onTranslate: @escaping () -> Void,
        onScreenshot: @escaping () -> Void
    ) {
        self.translateAction = onTranslate
        self.screenshotAction = onScreenshot

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let pointer = Unmanaged.passUnretained(self).toOpaque()

        // 使用 GetEventDispatcherTarget 保证在应用处于后台或 Accessory 模式时仍能全局捕获热键
        let target = GetEventDispatcherTarget() ?? GetApplicationEventTarget()

        InstallEventHandler(
            target,
            { _, inEvent, userData in
                guard let userData, let inEvent else {
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

                guard status == noErr else {
                    return noErr
                }

                DispatchQueue.main.async {
                    if hotKeyID.id == 1 {
                        manager.translateAction?()
                    } else if hotKeyID.id == 2 {
                        manager.screenshotAction?()
                    }
                }

                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandlerRef
        )

        // 1. 划词/剪贴板翻译: ⌥⇧T
        let translateID = EventHotKeyID(
            signature: OSType(0x4C54524E), // LTRN
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

        // 2. 截图翻译: ⌥⇧S
        let screenshotID = EventHotKeyID(
            signature: OSType(0x4C54524E), // LTRN
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
