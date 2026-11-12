import CoreAudio
import Foundation

/// One sound input on this Mac: the built-in microphone, a USB microphone, an audio interface.
nonisolated struct AudioInput: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let channels: Int
}

/// The inputs a person can record from, read from Core Audio. Reading the list needs no permission and
/// never shows a prompt; only starting the microphone does.
nonisolated enum AudioInputs {
    /// Every device that can be the Mac's input (so private and hidden devices, like the one Record from an
    /// app makes, are left out), the system's own input first.
    static func list() -> [AudioInput] {
        let system = AudioHardwareSystem.shared
        let defaultID = systemDefaultID
        let inputs: [AudioInput] = ((try? system.devices) ?? []).compactMap { d in
            guard (try? d.canBeDefaultInputDevice) == true, (try? d.isHidden) != true else { return nil }
            let channels = ((try? d.inputStreamConfiguration) ?? []).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0, let uid = try? d.uid else { return nil }
            let name = (try? d.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Input"
            return AudioInput(id: d.id, uid: uid, name: name, channels: channels)
        }
        return inputs.sorted { ($0.id == defaultID ? 0 : 1, $0.name) < ($1.id == defaultID ? 0 : 1, $1.name) }
    }

    /// The input chosen in System Settings ▸ Sound.
    static var systemDefaultID: AudioObjectID? {
        guard let d = try? AudioHardwareSystem.shared.defaultInputDevice else { return nil }
        return d.id
    }
}
