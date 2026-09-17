// Тишина на время диктовки.
//
// Диктовать под музыку неудобно вдвойне: её слышно в микрофон, и она мешает
// самому человеку. Поэтому на время записи выход системы уходит в немоту,
// а после — возвращается. Паузу воспроизведения мы пробовали и отказались:
// управлять чужими проигрывателями можно только клавишей «плей/пауза», она
// одна на всех, и надёжно узнать, играет ли что-то прямо сейчас, не вышло —
// на паузе Гига включал музыку вместо того, чтобы молчать.

import AppKit
import CoreAudio

enum Sound {
    /// Приглушать ли выход системы на время диктовки. Выбирается в меню.
    static var muteWhileDictating: Bool {
        get { UserDefaults.standard.bool(forKey: "muteWhileDictating") }
        set { UserDefaults.standard.set(newValue, forKey: "muteWhileDictating") }
    }

    // MARK: выход системы

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Громкость до приглушения — ею возвращаем звук, если у устройства
    /// нет отдельной «немоты» и пришлось крутить ручку.
    private static var volumeBefore: Float32?

    /// Тихо ли уже сейчас: немота включена или громкость на нуле. Если
    /// человек сам сидит в тишине, трогать выход нельзя — иначе после
    /// диктовки мы бы «вернули» ему звук, которого он не просил.
    static var isSilent: Bool {
        guard let dev = defaultOutput() else { return false }
        var mute = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(dev, &mute) {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &mute, 0, nil, &size, &value) == noErr, value != 0 {
                return true
            }
        }
        var volume = address(kAudioDevicePropertyVolumeScalar)
        guard AudioObjectHasProperty(dev, &volume) else { return false }
        var current: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &volume, 0, nil, &size, &current) == noErr
        else { return false }
        return current == 0
    }

    /// Приглушить или вернуть выход. Сперва пробуем честную «немоту»:
    /// её понимают встроенные динамики. Если устройство её не умеет
    /// (так ведут себя многие USB-карты и наушники), убираем громкость
    /// в ноль и потом возвращаем прежнюю.
    static func setMuted(_ on: Bool) {
        guard let dev = defaultOutput() else { return }
        var mute = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(dev, &mute) {
            var value: UInt32 = on ? 1 : 0
            let err = AudioObjectSetPropertyData(dev, &mute, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &value)
            if err == noErr { return }
        }
        var volume = address(kAudioDevicePropertyVolumeScalar)
        guard AudioObjectHasProperty(dev, &volume) else { return }
        if on {
            var current: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(dev, &volume, 0, nil, &size, &current) == noErr
            else { return }
            volumeBefore = current
            var zero: Float32 = 0
            AudioObjectSetPropertyData(dev, &volume, 0, nil,
                                       UInt32(MemoryLayout<Float32>.size), &zero)
        } else if var back = volumeBefore {
            volumeBefore = nil
            AudioObjectSetPropertyData(dev, &volume, 0, nil,
                                       UInt32(MemoryLayout<Float32>.size), &back)
        }
    }

}
