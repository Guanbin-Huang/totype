import AppKit
import Carbon
import OSLog

/// A registered OS shortcut, not an always-on key logger or an audio-path hook.
final class GlobalSettingsShortcut {
    static let keyCode = UInt32(kVK_ANSI_Comma)
    static let modifiers = UInt32(controlKey | cmdKey)
    static let options = UInt32(kEventHotKeyExclusive)
    static let hotKeyID = EventHotKeyID(signature: 0x54747970, id: 1)

    var onPress: (() -> Void)?
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "SettingsShortcut")
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    static func matches(_ id: EventHotKeyID) -> Bool {
        id.signature == hotKeyID.signature && id.id == hotKeyID.id
    }

    func start() throws {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, GlobalSettingsShortcut.matches(id) else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalSettingsShortcut>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak shortcut] in
                shortcut?.onPress?()
                shortcut?.logger.notice("SETTINGS_SHORTCUT_DISPATCHED control+command+comma")
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { throw shortcutError(installed) }
        let registered = RegisterEventHotKey(Self.keyCode, Self.modifiers, Self.hotKeyID,
            GetApplicationEventTarget(), Self.options, &hotKey)
        guard registered == noErr else {
            stop()
            throw shortcutError(registered)
        }
        logger.notice("SETTINGS_SHORTCUT_REGISTERED control+command+comma")
    }

    func stop() {
        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            if status != noErr { NSLog("[Totype] settings shortcut unregister error: %d", status) }
        }
        if let handler {
            let status = RemoveEventHandler(handler)
            if status != noErr { NSLog("[Totype] settings shortcut handler removal error: %d", status) }
        }
        hotKey = nil
        handler = nil
    }

    private func shortcutError(_ status: OSStatus) -> NSError {
        NSError(domain: "Totype.SettingsShortcut", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "全局设置快捷键 ⌃⌘, 注册失败（\(status)）"])
    }

    deinit { stop() }
}
