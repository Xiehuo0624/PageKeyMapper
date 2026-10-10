// PageKeyMapper 的单元测试。
//
// 只构造合成的 CGEvent 并跑决策逻辑，**不往系统投递任何按键**，
// 所以在没有授予辅助功能权限、甚至被沙箱限制的环境里也能运行。
//
// 编译运行：./test.sh   或   swiftc -O Sources/Core.swift Sources/selftest.swift -o build/selftest && ./build/selftest

import Cocoa
import Carbon.HIToolbox

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

/// 造一个假的键盘事件（只在本进程里用，不投递）。
func makeKey(_ code: Int64, flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
    event.flags = flags
    return event
}

// ── 1. 键码读取 ────────────────────────────────────────────────
print("\n[1] 从 CGEvent 读取键码")
check(keyCode(from: makeKey(116)) == 116, "PageUp → 116")
check(keyCode(from: makeKey(121)) == 121, "PageDown → 121")
check(keyCode(from: makeKey(123)) == 123, "Left → 123（方向键本身不受影响）")

// ── 2. 方向键模式 ──────────────────────────────────────────────
print("\n[2] 方向键模式（默认）")
check(decide(keyCode: 116, flags: [], enabled: true, mode: .arrows) == .mapTo(123), "PageUp → Left")
check(decide(keyCode: 121, flags: [], enabled: true, mode: .arrows) == .mapTo(124), "PageDown → Right")
check(decide(keyCode: 53, flags: [], enabled: true, mode: .arrows) == .passThrough, "Esc 原样放行")
check(decide(keyCode: 123, flags: [], enabled: true, mode: .arrows) == .passThrough, "Left 原样放行（不会自锁）")
check(decide(keyCode: 124, flags: [], enabled: true, mode: .arrows) == .passThrough, "Right 原样放行（不会自锁）")
check(decide(keyCode: 49, flags: [], enabled: true, mode: .arrows) == .passThrough, "空格等普通键原样放行")

// ── 3. 字符模式（Page Up → 2，Page Down → 空格）─────────────────
print("\n[3] 字符模式")
check(decide(keyCode: 116, flags: [], enabled: true, mode: .chars) == .mapTo(19), "PageUp → 2")
check(decide(keyCode: 121, flags: [], enabled: true, mode: .chars) == .mapTo(49), "PageDown → 空格")
check(decide(keyCode: 53, flags: [], enabled: true, mode: .chars) == .passThrough, "Esc 原样放行")
// 关键回归项：目标键不能落在映射表里，否则会自我递归
check(decide(keyCode: 19, flags: [], enabled: true, mode: .chars) == .passThrough, "「2」本身放行（不会自锁）")
check(decide(keyCode: 49, flags: [], enabled: true, mode: .chars) == .passThrough, "空格本身放行（不会自锁）")
check(decide(keyCode: 123, flags: [], enabled: true, mode: .chars) == .passThrough, "方向键在字符模式下不受影响")

// ── 4. 修饰键绕过 ──────────────────────────────────────────────
print("\n[4] 修饰键保留原义（临时绕过）")
for mode in [MappingMode.arrows, .chars] {
    let tag = mode.shortTitle
    check(decide(keyCode: 116, flags: .maskShift, enabled: true, mode: mode) == .passThrough,
          "\(tag)：Shift+PageUp 保留选择")
    check(decide(keyCode: 121, flags: .maskShift, enabled: true, mode: mode) == .passThrough,
          "\(tag)：Shift+PageDown 保留选择")
    check(decide(keyCode: 121, flags: .maskCommand, enabled: true, mode: mode) == .passThrough,
          "\(tag)：Command+PageDown 保留切换标签页")
    check(decide(keyCode: 116, flags: .maskControl, enabled: true, mode: mode) == .passThrough,
          "\(tag)：Control+PageUp 保留桌面切换")
}
// Option 不是绕过键：留给「Option + Page Up/Down」的系统既有绑定，映射照常生效
check(decide(keyCode: 116, flags: .maskAlternate, enabled: true, mode: .arrows) == .mapTo(123),
      "Option+PageUp 在方向键模式下照常映射")
check(decide(keyCode: 121, flags: .maskAlternate, enabled: true, mode: .chars) == .mapTo(49),
      "Option+PageDown 在字符模式下照常映射")

// ── 5. 开关 ────────────────────────────────────────────────────
print("\n[5] 暂停后完全不介入")
check(decide(keyCode: 116, flags: [], enabled: false, mode: .arrows) == .passThrough, "暂停时 PageUp 原样放行")
check(decide(keyCode: 121, flags: [], enabled: false, mode: .chars) == .passThrough, "暂停时 PageDown 原样放行")
check(Stats.enabled, "默认开启")
Stats.enabled = false
check(Stats.enabled == false, "可以暂停")
Stats.enabled = true
check(Stats.enabled, "可以恢复")

// ── 6. 模式切换与持久化 ────────────────────────────────────────
print("\n[6] 模式切换与持久化")
Stats.mode = .arrows
check(Stats.mode == .arrows, "默认是方向键模式")
Stats.mode = .chars
check(Stats.mode == .chars, "可以切换到字符模式")
check(UserDefaults.standard.object(forKey: "PKMMappingMode") as? Int == MappingMode.chars.rawValue,
      "选择已写入 UserDefaults（下次启动保持）")
Stats.restoreMode()
check(Stats.mode == .chars, "restoreMode() 能恢复上次选择")
Stats.mode = .arrows
Stats.restoreMode()
check(Stats.mode == .arrows, "切回方向键模式后同样能恢复")
check(MappingMode.allCases.count == 2, "菜单里会列出 2 个模式")

// ── 7. 合成事件的属性 ──────────────────────────────────────────
print("\n[7] 合成事件的属性")
let source = CGEventSource(stateID: .hidSystemState)
let arrow = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: true)!
check(keyCode(from: arrow) == 123, "合成的方向键键码正确（≠ 原键码，天然不会死循环）")
let digitTwo = CGEvent(keyboardEventSource: source, virtualKey: 19, keyDown: true)!
check(keyCode(from: digitTwo) == 19, "合成的「2」键码正确")
// 字符键必须不带任何修饰键，否则应用收到的是 "™" / 不间断空格
digitTwo.flags = CGEventFlags.maskAlternate
digitTwo.flags = []
check(digitTwo.flags.isEmpty, "清空修饰键后是干净的裸按键")
let space = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)!
space.flags = []
check(space.flags.isEmpty, "空格同样不带修饰键")

// ── 8. 事件回调的返回值 ────────────────────────────────────────
// ── 8. 安全边界：测试绝不能碰系统事件流 ────────────────────────
//
// 这里**故意不调用 EventTap.create()**。
// 任何进程只要创建 CGEventTap，macOS 就会弹「辅助功能」授权请求，
// 并把该二进制登记进系统设置。测试程序每次编译指纹都不同，
// 于是每跑一次测试就多弹一次窗、多留一条垃圾条目——
// 更糟的是会让「设置里勾着但程序说没权限」这种状态更容易出现。
//
// 事件 tap 的创建与按键投递属于系统交互行为，只应通过人工端到端验证，
// 不属于单元测试的职责。这里用源码自检替代，防止以后又有人在测试里
// 加回创建事件 tap 的代码：
print("\n[8] 安全边界（测试不触碰系统事件流）")
let testSource = (try? String(contentsOfFile: #filePath, encoding: .utf8)) ?? ""
// 扫描前剥掉注释，否则注释里提到的 API 会造成假阳性。
// 搜索模式本身也要拆开拼接，否则这一行自己就会被匹配到。
let codeOnly = testSource
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { line -> Substring in
        guard let range = line.range(of: "//") else { return line }
        return line[line.startIndex..<range.lowerBound]
    }
    .joined(separator: "\n")
let forbiddenTap = "EventTap." + "create()"
let forbiddenPost = ".post(" + "tap:"
check(!codeOnly.contains(forbiddenTap),
      "代码里没有创建事件 tap（不会弹授权窗）")
check(!codeOnly.contains(forbiddenPost),
      "代码里没有投递按键事件")

print("\n──────────────────────────────")
if failures == 0 {
    print("全部通过：\(checks) 项检查")
} else {
    print("失败 \(failures) / \(checks) 项")
}
exit(failures == 0 ? 0 : 1)
