import CoreAudio
import AudioToolbox
import Foundation
import os
let dev = findDevice(CommandLine.arguments[1])
var v = UInt32(CommandLine.arguments[2])!
var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
print("setbuf:", AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &v), "now", bufSize(dev))
Thread.sleep(forTimeInterval: 2.0)
print("setbuf exiting")
