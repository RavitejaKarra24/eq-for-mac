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
