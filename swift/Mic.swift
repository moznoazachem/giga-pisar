// Запись с микрофона — по-висперному.
//
// Раньше мы просили у устройства сразу 16 кГц/16 бит (AVAudioRecorder
// с жёсткими настройками), и частоту на лету пересчитывал драйвер.
// Настоящие драйверы с этим справляются, а виртуальные (Parallels, VMware,
// UTM) на таком запросе теряют куски звука — диктовка приходила с дырками.
//
// Теперь берём звук в РОДНОМ формате устройства (драйверу — самая простая
// работа «отдай как есть»), а в 16 кГц для модели пересчитываем сами,
// штатным AVAudioConverter. Так пишут MacWhisper и остальные серьёзные
// диктовалки. Бонус: аудиоблок держим готовым между записями — старт быстрее,
// и начало фразы не съедается.
//
// Пишем через голый AUHAL, а не через AVAudioEngine. У AVAudioEngine на macOS
// нет штатного способа выбрать микрофон: устройство приходилось назначать
// в уже собранный движок, и тот после этого то и дело останавливался сам —
// запись приходила пустой (#44). AUHAL получает микрофон до
// AudioUnitInitialize, как и задумано Apple. Так же пишет VoiceInk.

import AVFoundation
import CoreAudio

final class Mic {
    /// Аудиоблок живёт между записями: повторный старт заметно быстрее первого.
    /// Микрофон между записями НЕ открыт (оранжевой точки нет) — устройство
    /// включается только на время start()…stop().
    private var input: InputUnit?
    private var inputStale = false // devices changed during a recording; audioQueue only
    private var segments: [(rate: Double, samples: [Float])] = [] // моно, по микрофонам; audioQueue only
    private var drainTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private(set) var isRecording = false
    private let audioQueue = DispatchQueue(label: "ru.panda.giga.audio")
    private var stopping = false // main queue
    private var pendingStart: ((Error?) -> Void)? // at most one held press
    private var engineActive = false // audioQueue only
    private let startOverride: (() throws -> Void)?
    private let stopOverride: (() -> [Float])?

    /// Microphones came or went, or the system default changed. Main queue.
    var onDevicesChange: (() -> Void)?

    /// Громкость для волны, 0…1. Считается на audioQueue, читается
    /// из главного — живёт под локом.
    ///
    /// Это ПИКОВЫЙ измеритель с удержанием: между двумя взглядами волны
    /// микрофон может прислать и три куска, и ни одного, и всплеск голоса
    /// не должен пропасть ни в том, ни в другом случае. Поэтому куски
    /// копят максимум, а взгляд его забирает и обнуляет копилку.
    private var levelPeak: Float = 0
    private var levelSeen = false
    private var levelHeld: Float = 0

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        guard levelSeen else { return levelHeld } // куска ещё не было — держим прошлое
        levelSeen = false
        levelHeld = levelPeak
        levelPeak = 0
        return levelHeld
    }

    /// Тишина и полный голос в дБ относительно максимума. Ниже пола
    /// столбики лежат, выше потолка стоят во весь рост. Меряем пики
    /// по 10 мс, а не среднее по всему куску, поэтому и края взяты
    /// по-пиковому: тихая комната живёт около −55 дБ, обычная речь
    /// даёт пики от −35 до −12.
    private static let dbFloor: Float = -50
    private static let dbCeil: Float = -15

    /// Кривая громкости. Ухо слышет тихое лучше, чем показывает линейка:
    /// без поджатия обычная речь болталась бы в нижней трети столбика,
    /// и волна казалась вялой. 0.6 поднимает середину, не трогая края.
    private static let curve: Float = 0.6

    // Injection exercises the real lifecycle without opening a microphone.
    init(startEngine: (() throws -> Void)? = nil, stopEngine: (() -> [Float])? = nil) {
        startOverride = startEngine; stopOverride = stopEngine
        // A microphone that vanished and came back while idle (a monitor's
        // USB hub powered down with the display, a headset switched off)
        // must not leave the prepared unit bound to the dead device.
        // CoreAudio tells us about the device list and the default input
        // at any time.
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &addr, audioQueue) { [weak self] _, _ in
                self?.dropEngine()
                DispatchQueue.main.async { self?.onDevicesChange?() }
            }
        }
    }

    /// The prepared unit may no longer match the hardware: rebuild it on the
    /// next start. During a recording only a microphone that is gone forces
    /// a move: the recording goes on from the one that should be used now.
    /// A microphone that merely became preferred (the chosen one plugged
    /// back in, another system input) waits for the next take — a freshly
    /// plugged USB microphone takes about 1.6 s to start, all of it silence
    /// in the middle of the phrase. audioQueue only.
    private func dropEngine() {
        guard engineActive, let current = input else { input = nil; return }
        inputStale = true // rebuild after this take in any case
        guard !Self.isAlive(current.device) else { return }
        let wanted = Self.chosenInputDevice() ?? Self.defaultInputDevice()
        guard wanted != current.device, wanted != 0 else { return }
        current.stop()
        drain()
        do {
            let unit = try InputUnit(device: wanted)
            try unit.start()
            input = unit
            inputStale = false
            segments.append((rate: unit.rate, samples: []))
        } catch {
            // What was recorded so far is kept; the take just ends here.
            NSLog("Гига Писарь: microphone switch during a recording failed: \(error)")
        }
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func defaultInputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             0, nil, &size, &device)
        return err == noErr ? device : 0
    }

    // MARK: выбранный микрофон

    /// UID выбранного микрофона. nil — использовать системный вход.
    static var chosenUID: String? {
        get { UserDefaults.standard.string(forKey: "micDeviceUID") }
        set { UserDefaults.standard.set(newValue, forKey: "micDeviceUID") }
    }
    /// Имя выбранного — чтобы показать его, пока устройство отключено.
    static var chosenName: String? {
        get { UserDefaults.standard.string(forKey: "micDeviceName") }
        set { UserDefaults.standard.set(newValue, forKey: "micDeviceName") }
    }

    struct InputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    struct PreferredInput: Identifiable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// No list preserves the old single-device choice; an empty list follows
    /// the system input explicitly.
    static var preferredInputs: [PreferredInput] {
        get {
            if let rows = UserDefaults.standard.array(forKey: "micPreferredInputs") as? [[String: String]] {
                return rows.compactMap { row in
                    guard let uid = row["uid"], !uid.isEmpty, let name = row["name"] else { return nil }
                    return PreferredInput(uid: uid, name: name)
                }
            }
            guard let uid = chosenUID, !uid.isEmpty else { return [] }
            return [PreferredInput(uid: uid, name: chosenName ?? uid)]
        }
        set {
            UserDefaults.standard.set(newValue.map { ["uid": $0.uid, "name": $0.name] },
                                      forKey: "micPreferredInputs")
        }
    }

    /// Все устройства, у которых есть хотя бы один канал ввода.
    static func inputDevices() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("CADefaultDeviceAggregate-"),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Возвращает ID выбранного входа, если он доступен в списке устройств.
    /// nil означает, что вызывающий код должен использовать системный вход.
    private static func chosenInputDevice() -> AudioDeviceID? {
        preferredInput(preferredInputs, available: inputDevices())?.id
    }

    static func preferredInput(_ preferred: [PreferredInput], available: [InputDevice]) -> InputDevice? {
        preferred.lazy.compactMap { wanted in available.first { $0.uid == wanted.uid } }.first
    }

    /// Запускает запись. Бросает, если устройство не завелось, — тогда
    /// звука точно нет и надо честно сказать об этом человеку.
    func start(_ done: @escaping (Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRecording else {
            done(OrtError.failed("микрофон уже запущен")); return
        }
        if stopping { isRecording = true; pendingStart = done; return }
        isRecording = true
        audioQueue.async {
            var error: Error?
            do {
                if let start = self.startOverride { try start() }
                else { try self.startEngine() }
            } catch let failure { error = failure }
            let failure = error
            DispatchQueue.main.async {
                if failure != nil, self.pendingStart == nil { self.isRecording = false }
                done(failure)
            }
        }
    }

    private func startEngine() throws {
        do { try startInput(on: Self.chosenInputDevice() ?? Self.defaultInputDevice()) } catch {
            // A prepared unit can hold a device that is gone even when no
            // notification arrived, and a fresh one can catch CoreAudio
            // mid-switch right after a device vanished. Retry once from
            // scratch a moment later before telling the user it failed.
            NSLog("Гига Писарь: microphone failed to start, rebuilding: \(error)")
            input = nil
            Thread.sleep(forTimeInterval: 0.2)
            try startInput(on: Self.chosenInputDevice() ?? Self.defaultInputDevice())
        }
    }

    private func startInput(on device: AudioDeviceID) throws {
        guard device != 0 else { throw OrtError.failed("в системе нет микрофона") }
        // The prepared unit keeps the format the device had when it was
        // built; a device switched to another rate or channel count since
        // then would be read in the wrong format.
        if let prepared = input, prepared.device != device
            || prepared.rate != Self.nominalRate(device)
            || prepared.channels != Self.inputChannels(device) {
            input = nil
        }
        let unit = try input ?? InputUnit(device: device)
        segments = [(rate: unit.rate, samples: [])]
        do { try unit.start() } catch {
            input = nil // сломанный блок не переиспользуем
            throw error
        }
        input = unit
        engineActive = true
        startDraining()
    }

    /// The real-time callback only parks buffers; turning them into mono
    /// samples and the level happens here, on audioQueue. 20 ms is two
    /// windows of the level meter: the wave stays live, the queue stays idle.
    private func startDraining() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func drain() {
        guard let unit = input, !segments.isEmpty else { return }
        var peak: Float = 0, seen = false
        unit.drain { channels, frames in
            let mono = Self.mixToMono(channels, frames: frames)
            peak = max(peak, Self.level(of: mono, rate: unit.rate))
            seen = true
            segments[segments.count - 1].samples += mono
        }
        guard seen else { return }
        lock.lock()
        levelPeak = max(levelPeak, peak)
        levelSeen = true
        lock.unlock()
    }

    /// Останавливает запись и отдаёт всё записанное: 16 кГц, моно.
    func stop(_ done: @escaping ([Float]?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRecording else { DispatchQueue.main.async { done(nil) }; return }
        isRecording = false
        if pendingStart != nil {
            pendingStart = nil; DispatchQueue.main.async { done(nil) }; return
        }
        stopping = true
        audioQueue.async {
            let samples = self.stopOverride?() ?? self.stopEngine()
            DispatchQueue.main.async {
                self.stopping = false
                if let pending = self.pendingStart {
                    self.pendingStart = nil; self.isRecording = false
                    self.start(pending)
                }
                done(samples)
            }
        }
    }

    private func stopEngine() -> [Float]? {
        guard engineActive, let unit = input else { return nil }
        unit.stop() // сам блок оставляем — следующий старт быстрее
        drainTimer?.cancel(); drainTimer = nil
        drain() // хвост, пришедший после последнего разбора
        let lost = unit.losses()
        if lost.oversized > 0 || lost.overflowed > 0 {
            NSLog("Гига Писарь: за запись потеряно буферов — больше ячейки: \(lost.oversized), кольцо полно: \(lost.overflowed)")
        }
        engineActive = false
        let recorded = segments
        segments = []
        lock.lock()
        levelPeak = 0; levelHeld = 0; levelSeen = false // микрофон закрыт — волне показывать нечего
        lock.unlock()
        // Not a single buffer arrived: the unit ran on a device that is
        // no longer delivering sound. Never reuse it.
        if inputStale || recorded.allSatisfy({ $0.samples.isEmpty }) {
            input = nil
            inputStale = false
        }
        return Self.resample(recorded, to: 16000)
    }

    /// Каналы складываются и делятся на их число.
    static func mixToMono(_ channels: [UnsafePointer<Float>], frames: Int) -> [Float] {
        var mono = [Float](repeating: 0, count: frames)
        for p in channels {
            for i in 0..<frames { mono[i] += p[i] }
        }
        if channels.count > 1 {
            let k = Float(channels.count)
            for i in 0..<frames { mono[i] /= k }
        }
        return mono
    }

    /// Громкость для волны, 0…1: не среднее по всему куску, а самое громкое
    /// окно в 10 мс внутри него. Кусок в 4096 отсчётов — это ~85 мс;
    /// среднее по такому сроку размазывает слоги в ровный гул,
    /// и волна получается вялой, хотя голос живой.
    static func level(of mono: [Float], rate: Double) -> Float {
        let n = mono.count
        let window = max(1, Int(rate / 100))
        var peak: Float = 0
        var i = 0
        while i < n {
            let edge = min(i + window, n)
            var sum: Float = 0
            for j in i..<edge { sum += mono[j] * mono[j] }
            peak = max(peak, sqrt(sum / Float(edge - i)))
            i = edge
        }
        let db = 20 * log10(max(peak, 1e-7))
        let norm = min(max((db - dbFloor) / (dbCeil - dbFloor), 0), 1)
        return pow(norm, curve)
    }

    /// Запись, которая шла с нескольких микрофонов подряд: каждый отрезок
    /// в своей частоте пересчитывается отдельно, потом склеивается.
    static func resample(_ segments: [(rate: Double, samples: [Float])], to: Double) -> [Float] {
        segments.flatMap { resample($0.samples, from: $0.rate, to: to) }
    }

    /// Пересчёт частоты штатным конвертером Apple — тем же классом качества,
    /// что делает система, только у нас, а не в драйвере.
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        guard from != to else { return x }
        guard
            let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                      channels: 1, interleaved: false),
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                       channels: 1, interleaved: false),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                         frameCapacity: AVAudioFrameCount(x.count)),
            let conv = AVAudioConverter(from: inFmt, to: outFmt)
        else { return [] }

        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer {
            inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count)
        }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(x.count) * to / from) + 16)
        var fed = false
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 8192)
            else { break }
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { _, status in
                if fed {
                    status.pointee = .endOfStream
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            if let err { NSLog("Гига Писарь: ресемплинг — \(err)"); break }
            if outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if st == .endOfStream || st == .error || outBuf.frameLength == 0 { break }
        }
        return out
    }
}

/// One AUHAL input unit bound to one microphone, plus the ring its
/// real-time callback fills and audioQueue empties. The callback must not
/// allocate or wait, so it renders straight into preallocated slots and
/// only bumps a counter under a lock held for a few instructions.
private final class InputUnit {
    let device: AudioDeviceID
    let rate: Double
    let channels: Int
    private let unit: AudioUnit
    private let maxFrames: Int
    private let slotCount: Int
    private let samples: UnsafeMutablePointer<Float> // slotCount × channels × maxFrames
    private let slotFrames: UnsafeMutablePointer<Int>
    private let target: UnsafeMutableAudioBufferListPointer // render destination, repointed per slot
    private let ringLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var written = 0, read = 0 // under ringLock
    private var oversized = 0, overflowed = 0 // buffers lost since start; under ringLock

    init(device: AudioDeviceID) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw OrtError.failed("нет аудиоблока HAL")
        }
        var made: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &made), "аудиоблок не создался")
        guard let unit = made else { throw OrtError.failed("аудиоблок не создался") }
        let hw: AudioStreamBasicDescription, maxFrames: Int, ioFrames: Int
        do {
            // Input on, output off, the microphone set — all before
            // AudioUnitInitialize, so the unit is built for this device.
            var on: UInt32 = 1, off: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                                kAudioUnitScope_Input, 1, &on, flagSize), "вход не включился")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                                kAudioUnitScope_Output, 0, &off, flagSize), "выход не выключился")
            var id = device
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                kAudioUnitScope_Global, 0, &id,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)), "микрофон не выбрался")
            // The device side of the input bus is the device's own format;
            // we take it as is and only ask for Float32, one buffer per channel.
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Input, 1, &format, &size),
                           "микрофон не отдал формат звука")
            guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
                throw OrtError.failed("микрофон не отдал формат звука")
            }
            hw = format
            var client = AudioStreamBasicDescription(
                mSampleRate: hw.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: hw.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Output, 1, &client, size),
                           "формат звука не принят")
            var slice: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                                kAudioUnitScope_Global, 0, &slice, &size),
                           "аудиоблок не назвал размер буфера")
            var io: UInt32 = 0
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &io) != noErr { io = slice }
            ioFrames = Int(max(1, min(io, slice)))
            // Room for the largest buffer the device may ever pass: the top
            // of its buffer size range, or its variable size if it has one.
            // Without it a buffer above the slice is dropped by render below
            // and refused by AudioUnitRender (TN2321).
            var largest = max(slice, io)
            var range = AudioValueRange()
            size = UInt32(MemoryLayout<AudioValueRange>.size)
            addr.mSelector = kAudioDevicePropertyBufferFrameSizeRange
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range) == noErr, range.mMaximum > 0 {
                largest = max(largest, UInt32(range.mMaximum.rounded(.up)))
            }
            addr.mSelector = kAudioDevicePropertyUsesVariableBufferFrameSizes
            var variable: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectHasProperty(device, &addr),
               AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &variable) == noErr {
                largest = max(largest, variable)
            }
            if largest > slice {
                let status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                                  kAudioUnitScope_Global, 0, &largest, size)
                if status != noErr { NSLog("Гига Писарь: аудиоблок не принял буфер \(largest): \(status)") }
                try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                                    kAudioUnitScope_Global, 0, &slice, &size),
                               "аудиоблок не назвал размер буфера")
            }
            maxFrames = Int(max(slice, io))
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.device = device
        self.unit = unit
        rate = hw.mSampleRate
        channels = Int(hw.mChannelsPerFrame)
        self.maxFrames = maxFrames
        // About a second of the device's usual buffers: audioQueue empties
        // the ring every 20 ms, so only a queue stuck for a whole second
        // would lose sound.
        slotCount = max(8, Int(hw.mSampleRate) / ioFrames)
        samples = .allocate(capacity: slotCount * channels * maxFrames)
        slotFrames = .allocate(capacity: slotCount)
        target = AudioBufferList.allocate(maximumBuffers: channels)
        ringLock.initialize(to: os_unfair_lock())

        var callback = AURenderCallbackStruct(inputProc: inputCallback,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                            kAudioUnitScope_Global, 0, &callback,
                                            UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                       "аудиоблок не принял приём звука")
        try Self.check(AudioUnitInitialize(unit), "аудиоблок не запустился")
    }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        samples.deallocate()
        slotFrames.deallocate()
        free(target.unsafeMutablePointer)
        ringLock.deallocate()
    }

    func start() throws {
        os_unfair_lock_lock(ringLock); read = written; oversized = 0; overflowed = 0; os_unfair_lock_unlock(ringLock)
        try Self.check(AudioOutputUnitStart(unit), "микрофон не включился")
    }

    func stop() { AudioOutputUnitStop(unit) }

    /// Hands every buffer parked since the last call to `body`, one pointer
    /// per channel. audioQueue only.
    func drain(_ body: ([UnsafePointer<Float>], Int) -> Void) {
        os_unfair_lock_lock(ringLock); let from = read, to = written; os_unfair_lock_unlock(ringLock)
        guard from < to else { return }
        for i in from..<to {
            let slot = i % slotCount
            body((0..<channels).map { UnsafePointer(samples + (slot * channels + $0) * maxFrames) },
                 slotFrames[slot])
        }
        os_unfair_lock_lock(ringLock); read = to; os_unfair_lock_unlock(ringLock)
    }

    /// Buffers the callback had to drop since start: larger than a slot,
    /// or with the ring full. audioQueue only.
    func losses() -> (oversized: Int, overflowed: Int) {
        os_unfair_lock_lock(ringLock); defer { os_unfair_lock_unlock(ringLock) }
        return (oversized, overflowed)
    }

    /// Real-time thread.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timeStamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        let n = Int(frames)
        guard n <= maxFrames else {
            os_unfair_lock_lock(ringLock); oversized += 1; os_unfair_lock_unlock(ringLock)
            return noErr
        }
        os_unfair_lock_lock(ringLock)
        let slot = written - read < slotCount ? written % slotCount : -1
        if slot < 0 { overflowed += 1 }
        os_unfair_lock_unlock(ringLock)
        guard slot >= 0 else { return noErr } // ring full: the buffer is lost
        for c in 0..<channels {
            target[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4),
                                    mData: UnsafeMutableRawPointer(samples + (slot * channels + c) * maxFrames))
        }
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, target.unsafeMutablePointer)
        guard status == noErr else { return status }
        slotFrames[slot] = n
        os_unfair_lock_lock(ringLock); written += 1; os_unfair_lock_unlock(ringLock)
        return noErr
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw OrtError.failed("\(what): \(status)") }
    }
}

private let inputCallback: AURenderCallback = { refCon, flags, timeStamp, _, frames, _ in
    Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, frames)
}
