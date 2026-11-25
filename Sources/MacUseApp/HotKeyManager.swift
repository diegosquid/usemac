import Foundation
import Carbon

public final class HotKeyManager {
    public static let optionSpaceDefaultsKey = "macuse.hotkeys.optionSpaceEnabled"

    public var onToggleHUD: (() -> Void)?
    public var onToggleKillSwitch: (() -> Void)?
    public var onStateChanged: (() -> Void)?

    public private(set) var failedShortcuts: [String] = []
    public private(set) var isOptionSpaceEnabled: Bool

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [HotKeyID: EventHotKeyRef] = [:]

    private static let signature: FourCharCode = 0x4D555345 // 'MUSE'
    private enum HotKeyID: UInt32 {
        case optionSpace = 1
        case controlOptionSpace = 2
        case killSwitch = 3

        var label: String {
            switch self {
            case .optionSpace: return "⌥Space"
            case .controlOptionSpace: return "⌃⌥Space"
            case .killSwitch: return "⌘⇧⎋"
            }
        }
    }

    public init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.optionSpaceDefaultsKey) == nil {
            self.isOptionSpaceEnabled = true
        } else {
            self.isOptionSpaceEnabled = defaults.bool(forKey: Self.optionSpaceDefaultsKey)
        }
        installHandler()
        registerHotKeys()
    }

    deinit {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    public func setOptionSpaceEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.optionSpaceDefaultsKey)
        isOptionSpaceEnabled = enabled

        if enabled {
            if hotKeyRefs[.optionSpace] == nil {
                register(
                    id: .optionSpace,
                    keyCode: UInt32(kVK_Space),
                    modifiers: UInt32(optionKey)
                )
            }
        } else {
            unregister(id: .optionSpace)
            failedShortcuts.removeAll { $0 == HotKeyID.optionSpace.label }
        }
        onStateChanged?()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleHotKeyEvent(eventRef)
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func registerHotKeys() {
        if isOptionSpaceEnabled {
            register(
                id: .optionSpace,
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(optionKey)
            )
        }
        register(
            id: .controlOptionSpace,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey)
        )
        register(
            id: .killSwitch,
            keyCode: UInt32(kVK_Escape),
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    private func register(id: HotKeyID, keyCode: UInt32, modifiers: UInt32) {
        unregister(id: id)
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            failedShortcuts.removeAll { $0 == id.label }
        } else if !failedShortcuts.contains(id.label) {
            failedShortcuts.append(id.label)
        }
    }

    private func unregister(id: HotKeyID) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }

        guard let id = HotKeyID(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch id {
            case .optionSpace, .controlOptionSpace:
                self.onToggleHUD?()
            case .killSwitch:
                self.onToggleKillSwitch?()
            }
        }
        return noErr
    }
}
