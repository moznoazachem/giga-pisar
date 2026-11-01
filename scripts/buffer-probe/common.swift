import CoreAudio
import AudioToolbox
import Foundation
func findDevice(_ want: String) -> AudioDeviceID {
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
  var ids = [AudioDeviceID](repeating: 0, count: Int(size)/4)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
  for d in ids {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<CFString>.size); AudioObjectGetPropertyData(d, &a, 0, nil, &s, &name)
    if (name!.takeUnretainedValue() as String) == want { return d }
  }
  fatalError("no device")
}
func bufSize(_ d: AudioDeviceID) -> UInt32 {
  var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var io: UInt32 = 0; var s: UInt32 = 4; AudioObjectGetPropertyData(d, &a, 0, nil, &s, &io); return io
}
