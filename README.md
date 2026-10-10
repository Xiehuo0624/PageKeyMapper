# PageKeyMapper

一个常驻菜单栏的 macOS 小工具：**打开后，Page Up / Page Down 不再是翻页键**。

有两种模式，在菜单栏里切换，选择会被记住：

| 模式 | Page Up | Page Down |
|---|---|---|
| **方向键模式**（默认） | `←` | `→` |
| **字符模式** | `2` | `空格` |

- 按住 **Shift / Command / Control** 时保留原来的翻页功能（临时绕过）
- 点菜单栏图标可以 **切换模式** / 暂停 / 查看统计 / 退出

只有一个约 120 KB 的原生程序，没有第三方依赖，不联网。

> **建议装到 `~/Applications/` 并在授权后不要再重新编译** —— macOS 的辅助功能授权
> 是按代码签名指纹登记的，重新编译会让授权失效。详见文末「关于辅助功能授权」。

---

## 快速开始

```bash
./build.sh run      # 编译并启动
```

首次运行会弹窗要求「辅助功能」权限：

1. 系统设置 → 隐私与安全性 → **辅助功能**
2. 勾选 **PageKeyMapper**（列表里没有就点 `+` 选中 `PageKeyMapper.app`）
3. 回到程序，菜单栏出现 `↔` 图标即生效——**不用重启程序**，它会自动检测授权

想开机自启：系统设置 → 通用 → **登录项** → 把 `PageKeyMapper.app` 拖进去。

### 切换模式

点菜单栏 `↔` → **映射模式** → 选中想要的那一项（当前模式前面有 ✓）。切换立即生效，
并且会写进偏好设置，下次启动保持上次的选择。

### 菜单栏图标含义

| 图标 | 含义 |
|---|---|
| `↔` | 正在运行，重映射生效中 |
| `↔ ⏸` | 已暂停（菜单里可恢复） |
| `↔ ⚠︎` | 未生效：缺少辅助功能权限 |

> 如果 DSH Desktop 等应用处于**全屏**状态，macOS 会自动隐藏整条菜单栏，此时看不到 `↔` 属于正常现象，功能不受影响。退出全屏即可看到。

---

## 为什么需要「辅助功能」权限

macOS 不允许普通程序监听全局键盘。要改键，必须用 `CGEventTap` 拦截系统的键盘事件流，
而安装事件 tap 需要辅助功能（Accessibility）权限。没授权时程序会一直提示，不会静默失效。

## 工作原理

```
物理按键 → HID → Session 层 ← 本程序的事件 tap 挂在这里
                    ↓
              AnnotatedSession
                    ↓
                 目标应用
```

1. 事件 tap 挂在 **Session** 层，拦截 `keyDown` / `keyUp`
2. 认出 Page Up（keycode 116）/ Page Down（121）就**吞掉**这个事件（返回 `nil`）
3. 按当前模式的映射表合成目标按键，投递回 **Session** 层，让它正常流向应用

| | Page Up (116) | Page Down (121) |
|---|---|---|
| 方向键模式 | `←` (123) | `→` (124) |
| 字符模式 | `2` (19) | `空格` (49) |

两个防死循环措施：

- 合成事件的键码与原键码不同（123/124/19/49 都不在映射表里），天然不会再被匹配
- 检查 `eventSourceUnixProcessID`，自己发出的事件一律放行

字符模式下合成的事件**必须不带任何修饰键**。带 Option 的话应用收到的是 `™`，
带 Option+Shift 会变成不间断空格——所以 Shift / Command / Control 在映射之前
就已经绕过返回了，走到合成那一步时修饰键一定是空的。

> ⚠️ 踩过的坑：合成事件**必须**投在 `.cgSessionEventTap`。
> 事件流是 `HID → Session → AnnotatedSession → 应用`，如果投在
> `.cgAnnotatedSessionEventTap`，事件只会往应用方向继续走，
> 不会进入应用真正读取的那条流——现象是「日志显示拦截成功，但目标程序毫无反应」。
> 这一点用纯单元测试查不出来，是靠端到端测试（注入按键 + 读靶子程序光标位置）定位的。

---

## 文件结构

```
PageKeyMapper/
├── Sources/
│   ├── Core.swift              重映射核心：模式、映射表、事件回调（主程序与测试共用）
│   ├── main.swift              菜单栏 UI、模式切换、权限申请、事件 tap 的装载/卸载
│   └── selftest/main.swift     单元测试入口
├── build.sh                    编译打包成 PageKeyMapper.app
├── test.sh                     编译并运行单元测试
├── setup-signing.sh            可选：建立稳定的本地签名身份
├── LICENSE                     MIT
└── build/                      中间产物（可安全删除，不纳入版本控制）
```

## 开发

```bash
./build.sh          # 编译 + 打包 + 签名
./test.sh           # 运行单元测试（40 项，不需要辅助功能权限）
./build.sh clean    # 清理
./setup-signing.sh  # 可选：建立稳定的本地签名身份（见下文）
```

调试：程序支持 `PKM_DEBUG=1` 输出每一次拦截/改写，以及 `--listen`（只统计不改键）：

```bash
PKM_DEBUG=1 ./PageKeyMapper.app/Contents/MacOS/PageKeyMapper --listen
```

日志形如：

```
[PKM 23:11:56.531] 事件 tap 已安装（keyDown/keyUp）
[PKM 23:11:56.531] 改写 keycode 121 → 124（按下）
[PKM 23:11:56.547] 改写 keycode 121 → 124（抬起）
```

### 哪些命令会破坏授权

| 命令 | 会不会弹授权窗 | 会不会破坏已授权状态 |
|---|---|---|
| `./test.sh` | **不会** | **不会**（只编译独立的测试二进制，不碰 app 包） |
| `open PageKeyMapper.app` | **不会** | **不会** |
| `./build.sh` | 可能 | **会**（重新签名 → 指纹变化 → 授权作废） |

`test.sh` 编译出的测试程序**不创建事件 tap、不投递任何按键**，所以不会触发系统授权弹窗。
测试里有一项自检（第 8 组）专门守着这条规则，防止以后有人加回这类代码。
`build.sh` 是唯一会破坏授权的命令——除非真的要改代码，否则别跑它。

### 关于辅助功能授权

macOS 的 TCC 按**代码签名指纹 + 程序路径**双重登记授权。这意味着：只要重新编译，
指纹就变了，系统会把它当成一个全新的程序，原来勾选的授权条目随即失效——现象是
设置里那项明明还勾着，但按键完全没反应。

所以省事的做法是：**装到固定位置 → 编译一次 → 授权一次 → 之后别再编译**。

推荐把 App 放在 `~/Applications/`，而不是 `~/Documents`、`~/Desktop`、`~/Downloads`：
后三者会被 launchd 拒绝执行（报 `Bootstrap failed: 5: Input/output error`），
如果你想让它在后台常驻或开机自启，放在 `~/Applications` 最稳。

```bash
./build.sh
mkdir -p ~/Applications
cp -R PageKeyMapper.app ~/Applications/
open ~/Applications/PageKeyMapper.app
```

如果想更省事，可以自己建一个 LaunchAgent（`~/Library/LaunchAgents/`）来托管它，
获得开机自启和崩溃自动重启；这不是必须的，功能本身不依赖它。

### 万一手滑重新编译了，怎么恢复授权

1. 把新产物装回运行位置（覆盖旧的）：
   ```bash
   rm -rf ~/Applications/PageKeyMapper.app
   cp -R PageKeyMapper.app ~/Applications/PageKeyMapper.app
   open ~/Applications/PageKeyMapper.app
   ```
2. 系统设置 → 隐私与安全性 → **辅助功能**
3. 列表里把 PageKeyMapper 的旧条目用 `−` 全部删掉（重新编译后会积多条同名条目）
4. 点 `+` → 弹窗里按 `Shift+Cmd+G` → 输入 `~/Applications` → 选中 `PageKeyMapper.app`
5. 打开开关，程序 1.5 秒内自己生效，**不用重启**

### 关于 setup-signing.sh

`setup-signing.sh` 的思路是建一个**固定的**本地签名证书，让指纹不再随编译变化，
从根上解决上面这个问题。但 `codesign` 只接受**受信任证书链**签发的证书，
自签名证书必须先在「钥匙串访问」里手动设为「始终信任」（需要输入登录密码，
且是 GUI 弹窗，脚本无法代劳）。所以这个脚本是给愿意手动完成信任设置的人用的，
不完成这一步就只有 ad-hoc 签名可用，**不是必须的**。


## 常见问题

**跑测试会不会把授权搞坏？**
不会。`./test.sh` 只编译一个独立的测试二进制到 `build/`，不碰任何 app 包；
而且测试程序不创建事件 tap、不投递按键，所以也不会弹授权窗。
会破坏授权的只有 `./build.sh`。

**按了没反应？**
先看菜单栏图标是不是 `↔ ⚠︎`（缺权限）。如果权限正常，用 `PKM_DEBUG=1` 看日志再定位：
有「改写 keycode …」日志但目标程序没反应 → 事件投递位置不对（见上文那个坑）。

**授权了但程序还说没权限 / 时好时坏？**
几乎总是因为**程序被重新编译过、或者被移动了位置**——TCC 按代码签名指纹
**和路径**双重登记，搬家会当成新 App。特征：系统设置里那一项明明勾着，
但程序自己判定没权限、按键完全没反应。处理办法见上面「万一手滑重新编译了」那一节。

**和 Keyboard Maestro / LinearMouse 之类的工具冲突吗？**
它们也会装事件 tap，谁在前面谁先处理。如果 PageKeyMapper 的改动被别的工具覆盖，
把本程序的 tap 位置从 `.headInsertEventTap` 改成更靠前的层即可
（`Sources/Core.swift` 里的 `EventTap.create()`）。

**怎么改键位映射 / 加第三种模式？**
改 `Sources/Core.swift`：在 `MappingMode` 里加一个 case，并在 `Shared` 的
`arrowTable` / `charTable` 旁边加你的映射表，`table(for:)` 里接上即可——
菜单是按 `MappingMode.allCases` 自动生成的，不用改 UI 代码。
keycode 参考：`PageUp=116`、`PageDown=121`、`Left=123`、`Right=124`、
`Up=126`、`Down=125`、`2=19`、`空格=49`。
改完跑 `./test.sh && ./build.sh`。

---

## 许可证

[MIT](LICENSE) © 2026 Cao Haoxuan
