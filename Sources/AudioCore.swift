// AudioCore — тонкие обёртки над CoreAudio, IOKit (USB) и libproc.

import CoreAudio
import Foundation
import IOKit
import Darwin

// MARK: - CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ s: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ dev: AudioDeviceID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &cf) == noErr, let s = cf else { return "?" }
    return s.takeRetainedValue() as String
}

func transport(_ dev: AudioDeviceID) -> UInt32 {
    var a = addr(kAudioDevicePropertyTransportType)
    var t: UInt32 = 0
    var size = UInt32(4)
    AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &t)
    return t
}

func channels(_ dev: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getDefault(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = addr(sel); var d = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &d)
    return d
}

@discardableResult
func setDefault(_ sel: AudioObjectPropertySelector, _ dev: AudioDeviceID) -> Bool {
    var a = addr(sel); var d = dev
    return AudioObjectSetPropertyData(systemObject, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}

func sampleRate(_ dev: AudioDeviceID) -> Float64 {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var r: Float64 = 0; var size = UInt32(8)
    AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &r)
    return r
}

func setSampleRate(_ dev: AudioDeviceID, _ rate: Float64) {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var r = rate
    AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &r)
}

/// Пустой keyword = автоматический режим: первое USB-аудиоустройство.
func findAudioDevice(_ keyword: String, _ scope: AudioObjectPropertyScope) -> AudioDeviceID? {
    if keyword.isEmpty {
        return allDevices().first { transport($0) == kAudioDeviceTransportTypeUSB && channels($0, scope) > 0 }
    }
    return allDevices().first { deviceName($0).localizedCaseInsensitiveContains(keyword) && channels($0, scope) > 0 }
}

// MARK: - USB (IORegistry)

func regString(_ e: io_registry_entry_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
}

func regInt(_ e: io_registry_entry_t, _ key: String) -> Int? {
    (IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
}

/// Все USB-устройства, подходящие под условие. Вызывающий должен освободить их через IOObjectRelease.
func usbDevices(where match: (io_registry_entry_t) -> Bool) -> [io_registry_entry_t] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var out: [io_registry_entry_t] = []
    while case let s = IOIteratorNext(it), s != 0 {
        if match(s) { out.append(s) } else { IOObjectRelease(s) }
    }
    return out
}

/// Есть ли у USB-устройства аудиоинтерфейс (USB Audio Class = 1).
func usbHasAudioInterface(_ device: io_registry_entry_t) -> Bool {
    var it: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &it) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(it) }
    var found = false
    while case let c = IOIteratorNext(it), c != 0 {
        if regInt(c, "bInterfaceClass") == 1 { found = true }
        IOObjectRelease(c)
    }
    return found
}

/// Процессы, открывшие «клиентов» на USB-устройстве или его интерфейсах (ключ IOUserClientCreator = "pid N, Name").
func userClientPids(of device: io_registry_entry_t) -> Set<pid_t> {
    var pids = Set<pid_t>()
    func walk(_ e: io_registry_entry_t) {
        if let c = regString(e, "IOUserClientCreator"),
           let p = c.split(separator: ",").first?.split(separator: " ").last, let pid = pid_t(p) {
            pids.insert(pid)
        }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) == KERN_SUCCESS else { return }
        while case let c = IOIteratorNext(it), c != 0 { walk(c); IOObjectRelease(c) }
        IOObjectRelease(it)
    }
    walk(device)
    return pids
}

// MARK: - Процессы

func processPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(0, got))))
}

/// Системные процессы macOS никогда не трогаем.
func isSystemPath(_ p: String) -> Bool {
    ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/"].contains { p.hasPrefix($0) }
}

/// Путь к внешнему .app, в котором лежит исполняемый файл (для имени и иконки).
func outerAppPath(_ exec: String) -> String? {
    guard let r = exec.range(of: ".app/") else { return nil }
    return String(exec[..<r.lowerBound]) + ".app"
}

func displayName(forExec exec: String) -> String {
    if let app = outerAppPath(exec) {
        let b = Bundle(path: app)
        return (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
    }
    return URL(fileURLWithPath: exec).lastPathComponent
}

/// Программа построена на Chromium/Electron/CEF? Признак — icudtl.dat внутри фреймворка.
func isChromiumBased(appPath: String) -> Bool {
    let fw = appPath + "/Contents/Frameworks"
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: fw) else { return false }
    for f in items where f.hasSuffix(".framework") {
        let base = "\(fw)/\(f)"
        if FileManager.default.fileExists(atPath: base + "/Resources/icudtl.dat") { return true }
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: base + "/Versions"),
           vers.contains(where: { FileManager.default.fileExists(atPath: "\(base)/Versions/\($0)/Resources/icudtl.dat") }) {
            return true
        }
    }
    return false
}
