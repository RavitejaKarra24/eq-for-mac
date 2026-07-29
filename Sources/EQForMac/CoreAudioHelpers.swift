import CoreAudio
import Foundation

enum AudioError: LocalizedError {
    case status(OSStatus, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            return "\(message) (OSStatus \(code))"
        case .message(let message):
            return message
        }
    }
}

func caCheck(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else {
        throw AudioError.status(status, message)
    }
}

func getDefaultOutputDeviceID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try caCheck(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ),
        "Failed to get default output device"
    )
    return deviceID
}

/// Resolves the device EQ for Mac should tap and play through.
///
/// Downmix uses BlackHole as the macOS default output, then writes its stereo
/// result directly to a physical device. Sending EQ output back to BlackHole
/// creates the wrong processing order and can feed the virtual device back into
/// itself. When that routing is active, use Downmix's selected physical output.
func getRoutableOutputDeviceID() throws -> AudioDeviceID {
    let defaultDeviceID = try getDefaultOutputDeviceID()
    let defaultUID = try getDeviceUID(defaultDeviceID)

    guard routeContainsBlackHole(deviceID: defaultDeviceID, visited: []) else {
        UserDefaults.standard.set(defaultUID, forKey: lastDirectOutputUIDKey)
        return defaultDeviceID
    }

    let candidateUIDs = [downmixOutputDeviceUID(), lastDirectOutputDeviceUID()]
        .compactMap { $0 }
    for uid in candidateUIDs {
        if let deviceID = try audioDeviceID(matchingUID: uid),
           deviceID != defaultDeviceID,
           !routeContainsBlackHole(deviceID: deviceID, visited: []) {
            UserDefaults.standard.set(uid, forKey: lastDirectOutputUIDKey)
            return deviceID
        }
    }

    throw AudioError.message(
        "BlackHole is the default output, but no physical Downmix output is available. "
            + "Select an output in Downmix, then toggle EQ off and on."
    )
}

private let lastDirectOutputUIDKey = "EQForMac.lastDirectOutputDeviceUID"

private struct DownmixPreferences: Decodable {
    let outputDeviceUID: String
}

private func isBlackHoleDevice(uid: String, name: String) -> Bool {
    uid.localizedCaseInsensitiveContains("blackhole")
        || name.localizedCaseInsensitiveContains("blackhole")
}

private func routeContainsBlackHole(
    deviceID: AudioDeviceID,
    visited: Set<AudioDeviceID>
) -> Bool {
    guard !visited.contains(deviceID) else { return false }
    var visited = visited
    visited.insert(deviceID)

    let uid = (try? getDeviceUID(deviceID)) ?? ""
    let name = (try? getDeviceName(deviceID)) ?? ""
    if isBlackHoleDevice(uid: uid, name: name) { return true }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return false }

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        deviceID,
        &address,
        0,
        nil,
        &dataSize
    ) == noErr, dataSize > 0 else {
        return false
    }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var subdeviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        &subdeviceIDs
    ) == noErr else {
        return false
    }
    return subdeviceIDs.contains {
        routeContainsBlackHole(deviceID: $0, visited: visited)
    }
}

private func downmixOutputDeviceUID() -> String? {
    guard let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else {
        return nil
    }
    let url = applicationSupport
        .appendingPathComponent("Downmix", isDirectory: true)
        .appendingPathComponent("preferences.json")
    guard let data = try? Data(contentsOf: url),
          let preferences = try? JSONDecoder().decode(
            DownmixPreferences.self,
            from: data
          ),
          !preferences.outputDeviceUID.isEmpty
    else {
        return nil
    }
    return preferences.outputDeviceUID
}

private func lastDirectOutputDeviceUID() -> String? {
    let uid = UserDefaults.standard.string(forKey: lastDirectOutputUIDKey)
    return uid?.isEmpty == false ? uid : nil
}

private func audioDeviceID(matchingUID uid: String) throws -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    try caCheck(
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ),
        "Failed to list audio devices"
    )

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    try caCheck(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ),
        "Failed to read audio devices"
    )

    for deviceID in deviceIDs where (try? getDeviceUID(deviceID)) == uid {
        return deviceID
    }
    return nil
}

func isAudioDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
    guard deviceID != kAudioObjectUnknown else { return false }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var isAlive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        &isAlive
    ) == noErr && isAlive != 0
}

func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid),
        "Failed to get device UID"
    )
    guard let uid else {
        throw AudioError.message("Device UID was empty")
    }
    return uid.takeRetainedValue() as String
}

func getDeviceName(_ deviceID: AudioDeviceID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name),
        "Failed to get device name"
    )
    guard let name else {
        throw AudioError.message("Device name was empty")
    }
    return name.takeRetainedValue() as String
}
