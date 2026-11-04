import CoreAudio
import Foundation

/// ほかのアプリ（動画・音楽・会議など）が音を出しているかを調べる。
/// スピーカーの音はマイクに入り、声と区別できないので、鳴っている間は名前を呼ばれたときだけ答えるのに使う
enum OtherAudio {
    static func isPlaying() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return ids.contains { id in
            uint32(id, kAudioProcessPropertyIsRunningOutput) != 0 && pid(id) != me
        }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    private static func pid(_ id: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }
}
