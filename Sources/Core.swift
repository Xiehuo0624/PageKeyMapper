// 重映射核心逻辑：映射表、模式、事件回调。
//
// 这个文件是决策逻辑的唯一实现来源：主程序（Sources/main.swift）和
// 单元测试（Sources/selftest/main.swift）编译的是同一份代码，
// 所以测试测的就是实际生效的逻辑，不存在两边实现漂移的问题。

import Cocoa
import Carbon.HIToolbox

private enum Key {
    static let pageUp: Int64 = 116
    static let pageDown: Int64 = 121
    static let leftArrow: Int64 = 123
    static let rightArrow: Int64 = 124
    static let digit2: Int64 = 19
    static let space: Int64 = 49
}

/// 两种工作模式，在菜单栏里切换。
enum MappingMode: Int, CaseIterable {
    /// 方向键模式：Page Up → ←，Page Down → →
    case arrows = 0
    /// 字符模式：Page Up → 2，Page Down → 空格
    case chars = 1

    var title: String {
        switch self {
        case .arrows: return "方向键模式（Page Up/Down → ←/→）"
        case .chars:  return "字符模式（Page Up/Down → 2/空格）"
        }
    }

    var shortTitle: String {
        switch self {
        case .arrows: return "方向键模式"
        case .chars:  return "字符模式"
        }
    }

    var detail: String {
        switch self {
        case .arrows: return "Page Up → ←，Page Down → →"
        case .chars:  return "Page Up → 2，Page Down → 空格"
        }
    }
}

// MARK: - 共享状态
// 事件回调跑在专用的 runloop 线程上，菜单跑在主线程上，所以用锁保护。

private enum Shared {
    static let lock = NSLock()

    nonisolated(unsafe) static var mappingEnabled = true

    nonisolated(unsafe) static var mode: MappingMode = .arrows

    /// 我们自己合成的事件要放行，避免递归处理。
    static let ownPid = getpid()

    /// 方向键模式的映射表
    static let arrowTable: [Int64: Int64] = [
        Key.pageUp: Key.leftArrow,
        Key.pageDown: Key.rightArrow,
    ]

    /// 字符模式的映射表
    static let charTable: [Int64: Int64] = [
        Key.pageUp: Key.digit2,
        Key.pageDown: Key.space,
    ]

    static func table(for mode: MappingMode) -> [Int64: Int64] {
        switch mode {
        case .arrows: return arrowTable
        case .chars:  return charTable
        }
    }

    nonisolated(unsafe) static var sentCount = 0
    nonisolated(unsafe) static var seenCount = 0
}

/// 供回调使用的事件 tap 句柄（回调跑在专用线程上，这里只读写指针，不加锁也安全）。
private enum TapRef {
    nonisolated(unsafe) static var port: CFMachPort?
    nonisolated(unsafe) static var source: CFRunLoopSource?
}

/// 重映射的判定结果。
enum MappingDecision: Equatable {
    case passThrough
    case mapTo(Int64)
}

/// 纯函数：给定按键、修饰键和当前模式，决定该原样放行还是映射成别的键。
/// 不依赖任何全局状态，方便测试。
func decide(keyCode: Int64, flags: CGEventFlags, enabled: Bool, mode: MappingMode) -> MappingDecision {
    guard enabled, let target = Shared.table(for: mode)[keyCode] else { return .passThrough }

    // Shift / Command / Control 组合键保留原义（翻页、选页等），方便临时绕过。
    // Option 不在此列——它留给「Option + Page Up/Down」这类系统与应用的既有绑定。
    let bypass = flags.contains(.maskShift)
        || flags.contains(.maskCommand)
        || flags.contains(.maskControl)

    return bypass ? .passThrough : .mapTo(target)
}

/// 从 CGEvent 取出虚拟键码。
func keyCode(from event: CGEvent) -> Int64? {
    guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
    return Int64(nsEvent.keyCode)
}

// MARK: - 事件回调

private func eventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // 系统可能因为我们处理太慢而临时关掉 tap，需要自己重新打开。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = TapRef.port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown || type == .keyUp else {
        return Unmanaged.passUnretained(event)
    }

    // 自己合成的事件直接放行，防止死循环。
    if event.getIntegerValueField(.eventSourceUnixProcessID) == Shared.ownPid {
        return Unmanaged.passUnretained(event)
    }

    guard let code = keyCode(from: event) else {
        return Unmanaged.passUnretained(event)
    }

    Shared.lock.lock()
    let enabled = Shared.mappingEnabled
    let mode = Shared.mode
    let isInteresting = Shared.table(for: mode)[code] != nil
    if isInteresting { Shared.seenCount += 1 }
    Shared.lock.unlock()

    guard case .mapTo(let target) = decide(keyCode: code, flags: event.flags,
                                           enabled: enabled, mode: mode) else {
        if isInteresting, debugEnabled {
            log("看到 keycode \(code) 但按原样放行")
        }
        return Unmanaged.passUnretained(event)
    }

    if debugEnabled {
        log("改写 keycode \(code) → \(target)（\(type == .keyDown ? "按下" : "抬起")）"
            + "［\(mode.shortTitle)］")
    }

    // 用和原事件不同的 keycode 合成目标按键：即使回调被重入也不会再被匹配到，
    // 加上进程号检查，构成双重保险。
    if let synthesized = CGEvent(
        keyboardEventSource: CGEventSource(stateID: .hidSystemState),
        virtualKey: CGKeyCode(target),
        keyDown: (type == .keyDown)
    ) {
        // 必须是空修饰键。目标键是「2」「空格」这类字符键，只要带上 Option，
        // 应用收到的就会是 "™"「不间断空格」而不是我们想要的字符。
        // 需要保留的 Shift/Command/Control 组合在上面就已经绕过、不会走到这里。
        synthesized.flags = []
        Shared.lock.lock()
        Shared.sentCount += 1
        Shared.lock.unlock()
        // 必须投在 .cgSessionEventTap。事件流向是
        //   HID → Session → AnnotatedSession → 目标应用，
        // 我们自己的 tap 挂在 Session 层；如果投在 AnnotatedSession，
        // 合成事件只会继续往应用方向走，不会进入应用真正读取的那条流，
        // 结果就是「拦截成功但目标程序毫无反应」。
        synthesized.post(tap: .cgSessionEventTap)
    }

    // 吞掉原来的 PageUp / PageDown。
    return nil
}

/// 对外暴露的调试统计与设置读写，同时提供带时间戳的 stderr 日志。
enum Stats {
    static var sent: Int {
        Shared.lock.lock(); defer { Shared.lock.unlock() }
        return Shared.sentCount
    }
    static var seen: Int {
        Shared.lock.lock(); defer { Shared.lock.unlock() }
        return Shared.seenCount
    }
    static var enabled: Bool {
        get { Shared.lock.lock(); defer { Shared.lock.unlock() }; return Shared.mappingEnabled }
        set { Shared.lock.lock(); defer { Shared.lock.unlock() }; Shared.mappingEnabled = newValue }
    }

    /// 当前工作模式。写入时会持久化，下次启动保持上次的选择。
    static var mode: MappingMode {
        get { Shared.lock.lock(); defer { Shared.lock.unlock() }; return Shared.mode }
        set {
            Shared.lock.lock()
            Shared.mode = newValue
            Shared.lock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: modeDefaultsKey)
        }
    }

    /// 从 UserDefaults 恢复上次选择的模式。程序启动时调用一次。
    static func restoreMode() {
        let stored = UserDefaults.standard.object(forKey: modeDefaultsKey) as? Int
        if let stored, let restored = MappingMode(rawValue: stored) {
            Shared.lock.lock()
            Shared.mode = restored
            Shared.lock.unlock()
        }
    }
}

private let modeDefaultsKey = "PKMMappingMode"

let debugEnabled = ProcessInfo.processInfo.environment["PKM_DEBUG"] != nil

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// 记录一行调试日志（只有设置 PKM_DEBUG=1 时才输出）。
func log(_ message: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write("[PKM \(logFormatter.string(from: Date()))] \(message)\n".data(using: .utf8)!)
}

/// 供主程序用来安装/卸载事件 tap。
enum EventTap {
    static func create() -> CFMachPort? {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventCallback,
            userInfo: nil
        )
    }

    static func remember(port: CFMachPort?, source: CFRunLoopSource?) {
        TapRef.port = port
        TapRef.source = source
    }
}
