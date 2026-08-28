import Foundation
import Carbon.HIToolbox

final class HotKeyManager {

    private static let signature: OSType = 0x4C54524E // 'LTRN'

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

        let eventSpecs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
        ]

        let pointer = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
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

                if status == noErr {
                    DispatchQueue.main.async {
                        if hotKeyID.id == 1 {
                            manager.translateAction?()
                        } else if hotKeyID.id == 2 {
                            manager.screenshotAction?()
                        }
                    }
                }

                return noErr
            },
            eventSpecs.count,
            eventSpecs,
            pointer,
            &eventHandlerRef
        )

        _ = installStatus

        // 1. 划词/剪贴板翻译: ⌥⇧T (kVK_ANSI_T = 17, optionKey = 2048, shiftKey = 512)
        let translateID = EventHotKeyID(
            signature: Self.signature,
            id: 1
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(optionKey | shiftKey),
            translateID,
            GetApplicationEventTarget(),
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
            GetApplicationEventTarget(),
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
