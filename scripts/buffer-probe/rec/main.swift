import CoreAudio
import AudioToolbox
import Foundation
import os
let dev = findDevice(CommandLine.arguments[1])
var setSlice = UInt32(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "0")!
var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var u: AudioUnit?; AudioComponentInstanceNew(AudioComponentFindNext(nil, &desc)!, &u)
let unit = u!
var on: UInt32 = 1, off: UInt32 = 0
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4)
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4)
var id = dev; AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4)
var fmt = AudioStreamBasicDescription(); var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &fmt, &sz)
var client = AudioStreamBasicDescription(mSampleRate: fmt.mSampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: fmt.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, sz)
if setSlice > 0 { print("set slice:", AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &setSlice, 4)) }
let ch = Int(fmt.mChannelsPerFrame)
let mem = UnsafeMutablePointer<Float>.allocate(capacity: ch * 16384)
let abl = AudioBufferList.allocate(maximumBuffers: ch)
final class Log { var lock = os_unfair_lock(); var ev: [(UInt32, OSStatus)] = [] }
let log = Log()
var cb = AURenderCallbackStruct(inputProc: { _, flags, ts, _, frames, _ in
  for c in 0..<ch { abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: mem + c * 16384) }
  let st = AudioUnitRender(unit, flags, ts, 1, frames, abl.unsafeMutablePointer)
  os_unfair_lock_lock(&log.lock); log.ev.append((frames, st)); os_unfair_lock_unlock(&log.lock)
  return noErr }, inputProcRefCon: nil)
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
print("init:", AudioUnitInitialize(unit), "start:", AudioOutputUnitStart(unit))
var sl: UInt32 = 0; var s4: UInt32 = 4
for t in 0..<10 {
  Thread.sleep(forTimeInterval: 0.5)
  os_unfair_lock_lock(&log.lock); let ev = log.ev; log.ev = []; os_unfair_lock_unlock(&log.lock)
  AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &sl, &s4)
  var hist: [String: Int] = [:]; for (f, st) in ev { hist["\(f)/\(st)", default: 0] += 1 }
  print(String(format: "t=%.1f", Double(t+1)*0.5), "devbuf=\(bufSize(dev)) slice=\(sl) frames/status:", hist.sorted { $0.key < $1.key })
}
