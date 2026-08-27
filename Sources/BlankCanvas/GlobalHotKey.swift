import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKey {
    private let identifier: EventHotKeyID
    private let action: () -> Void
    private var hotKeyReference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) throws {
        identifier = EventHotKeyID(signature: 0x424C_4E4B, id: 1) // "BLNK"
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handle(event)
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerReference
        )
        guard handlerStatus == noErr else { throw HotKeyError.installationFailed(handlerStatus) }
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registrationStatus == noErr else {
            if let handlerReference { RemoveEventHandler(handlerReference) }
            throw HotKeyError.registrationFailed(registrationStatus)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
            if let handlerReference { RemoveEventHandler(handlerReference) }
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var received = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &received
        )
        guard status == noErr, received.signature == identifier.signature, received.id == identifier.id else {
            return OSStatus(eventNotHandledErr)
        }
        action()
        return noErr
    }
}

enum HotKeyError: LocalizedError {
    case installationFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .installationFailed(let status): "Could not install the global hot key (OSStatus \(status))."
        case .registrationFailed(let status): "Could not register ⌥⌘H (OSStatus \(status))."
        }
    }
}
