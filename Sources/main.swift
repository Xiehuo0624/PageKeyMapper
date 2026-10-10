// PageKeyMapper — 把 Page Up / Page Down 重新映射为 ← / →
//
// 原理：安装一个 CGEventTap 拦截系统键盘事件，看到 PageUp/PageDown 就吞掉，
//       再合成一个 Left/Right 方向键事件。需要「辅助功能」权限，
//       否则系统不会把键盘事件交给本程序。
//
// 核心判定逻辑在 Sources/Core.swift（主程序与单元测试共用同一份）。
//
// 编译：./build.sh          产物 PageKeyMapper.app
// 调试：./PageKeyMapper.app/Contents/MacOS/PageKeyMapper --listen   只监听、不改键

import Cocoa

// MARK: - 权限

private func hasAccessibilityPermission(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// MARK: - 应用（常驻菜单栏）

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private let listenOnly: Bool

    init(listenOnly: Bool) {
        self.listenOnly = listenOnly
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        Stats.enabled = !listenOnly      // --listen 只统计不改键
        Stats.restoreMode()              // 恢复上次选择的映射模式
        log("启动，当前模式：\(Stats.mode.shortTitle)")

        // 注意：这里**故意不弹系统授权对话框**（prompt: false）。
        //
        // 带 prompt 的检测会让 macOS 在任何未授权进程启动本程序时弹窗，
        // 而且会把这个二进制登记进系统设置。开发调试时它每启动一次就弹一次，
        // 甚至会把已经授权好的条目状态搅乱。
        //
        // 现在是静默检测：没权限就只在菜单栏显示 ↔ ⚠︎，用户自己决定去不去授权。
        // 这样启动程序永远不会打扰人，只是安静地等着权限到位。
        if hasAccessibilityPermission(prompt: false) {
            startTap()
        } else {
            log("没有辅助功能权限，暂不接管键盘（菜单栏会显示 ↔ ⚠︎）")
            // 用户去系统设置里授权，回来后会自己生效，不用重启程序。
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
                if hasAccessibilityPermission(prompt: false) {
                    timer.invalidate()
                    log("权限已到位，开始接管键盘")
                    self.startTap()
                }
            }
        }
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopTap()
    }

    // MARK: 事件 tap

    private func startTap() {
        guard tap == nil else { return }

        guard let port = EventTap.create() else {
            log("事件 tap 创建失败：没有辅助功能权限")
            let alert = NSAlert()
            alert.messageText = "无法建立键盘监听"
            alert.informativeText = """
            请到「系统设置 → 隐私与安全性 → 辅助功能」里勾选 PageKeyMapper，
            然后重新打开本程序。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "PageKeyMapper.EventTap"
        thread.start()

        tap = port
        runLoopSource = source
        tapThread = thread
        EventTap.remember(port: port, source: source)
        log("事件 tap 已安装（keyDown/keyUp）")
        refreshMenu()
    }

    private func stopTap() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        tapThread = nil
        EventTap.remember(port: nil, source: nil)
    }

    private var isRunning: Bool { tap != nil }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "↔"
        log("状态项已创建：visible=\(statusItem.isVisible) button=\(statusItem.button != nil ? "有" : "无")")
    }

    private func refreshMenu() {
        guard let statusItem else { return }
        let running = isRunning
        let on = running && Stats.enabled

        statusItem.button?.title = !running ? "↔ ⚠︎" : (on ? "↔" : "↔ ⏸")

        let menu = NSMenu()

        if !running {
            let warn = NSMenuItem(title: "未生效：需要「辅助功能」权限", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)

            let fix = NSMenuItem(title: "打开辅助功能设置…",
                                 action: #selector(openAccessibilitySettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }

        let mode = Stats.mode
        let status = NSMenuItem(
            title: listenOnly ? "监听模式（只统计，不改键）"
                              : (on ? "运行中 · \(mode.shortTitle)：\(mode.detail)"
                                    : "已暂停 · \(mode.shortTitle)"),
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let toggle = NSMenuItem(title: on ? "暂停重映射" : "开启重映射",
                                action: #selector(toggleMapping), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = running && !listenOnly
        menu.addItem(toggle)

        menu.addItem(.separator())

        // 模式选择：当前模式打勾，点另一个即切换
        let modeHeader = NSMenuItem(title: "映射模式", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        for candidate in MappingMode.allCases {
            let item = NSMenuItem(title: candidate.title,
                                  action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = (candidate == mode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let stats = NSMenuItem(title: "已处理 \(Stats.sent) 次（检测到 \(Stats.seen) 次）",
                               action: nil, keyEquivalent: "")
        stats.isEnabled = false
        menu.addItem(stats)

        menu.addItem(.separator())

        let help = NSMenuItem(title: "使用说明", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        let openSettings = NSMenuItem(title: "打开辅助功能设置…",
                                      action: #selector(openAccessibilitySettings), keyEquivalent: "")
        openSettings.target = self
        menu.addItem(openSettings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleMapping() {
        Stats.enabled.toggle()
        refreshMenu()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let mode = MappingMode(rawValue: raw) else { return }
        Stats.mode = mode          // 自动持久化，下次启动保持
        log("切换模式 → \(mode.shortTitle)")
        refreshMenu()
    }

    @objc private func openAccessibilitySettings() {
        // 不同 macOS 版本的 URL scheme 不一样，挨个试。
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "PageKeyMapper"
        alert.informativeText = """
        两种模式，在菜单栏的「映射模式」里切换（会记住选择）：

        · 方向键模式：Page Up → ←，Page Down → →
        · 字符模式：  Page Up → 2，Page Down → 空格

        当前模式：\(Stats.mode.shortTitle)（\(Stats.mode.detail)）

        · 按住 Shift / Command / Control 时保留原来的翻页功能，
          需要临时翻页就用 Shift + Page Up / Page Down。
        · 点击菜单栏的 ↔ 图标可以切换模式、暂停、查看统计或退出。
        · 授权路径：系统设置 → 隐私与安全性 → 辅助功能。
        · 想开机自启：把 PageKeyMapper.app 拖进
          系统设置 → 通用 → 登录项。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        stopTap()
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    PageKeyMapper — 把 Page Up / Page Down 映射为 ← / →

      （无参数）  正常运行，常驻菜单栏
      --listen    只监听统计、不改键（用来确认权限是否生效）
      --help      显示这段帮助
    """)
    exit(0)
}

let listenOnly = CommandLine.arguments.contains("--listen")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // 不占 Dock，没有主窗口
let delegate = AppDelegate(listenOnly: listenOnly)
app.delegate = delegate
app.run()
