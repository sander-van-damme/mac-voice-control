import AppKit
import Carbon

@MainActor final class VoiceShortcuts {
    private weak var model: AppModel?
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    init(model: AppModel) {
        self.model = model
        var events = [EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,
                                    UInt32(MemoryLayout<EventHotKeyID>.size),nil,&id) == noErr else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated {
                let owner = Unmanaged<VoiceShortcuts>.fromOpaque(context).takeUnretainedValue()
                switch id.id {
                case 1: pressed ? owner.model?.beginPushToTalk() : owner.model?.endPushToTalk()
                case 2: if pressed { owner.model?.toggleContinuous() }
                case 3: if pressed { owner.model?.stop() }
                default: break
                }
            }
            return noErr
        },UInt32(events.count),&events,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard result == noErr else { model.message = "Global shortcuts could not be installed. Use the menu-bar controls."; return }
        for (id,key,modifiers) in [(UInt32(1),UInt32(kVK_Space),UInt32(controlKey|optionKey)),
                                   (2,UInt32(kVK_Space),UInt32(cmdKey|optionKey)),
                                   (3,UInt32(kVK_ANSI_Period),UInt32(controlKey|optionKey))] {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key,modifiers,EventHotKeyID(signature:0x4A455646,id:id),GetApplicationEventTarget(),0,&reference)
            if status == noErr, let reference { keys.append(reference) }
            else { model.message = "A global shortcut is already in use. Menu-bar controls remain available." }
        }
    }
    deinit {
        keys.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
