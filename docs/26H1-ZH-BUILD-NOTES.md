# Windows 11 26H1 中文镜像 + App 汉化 + 免电脑启动：完整构建笔记

本文记录 2026-11-21 完成的三件事及其背后的全部排障知识：

1. 用桌面版 **Windows 11 26H1 ARM64 中文 ISO（Build 28000）** 重做镜像：**不精简、全驱动、100 GB、中文桌面**；
2. 将 iOS App（WindowsiOS）界面**汉化**；
3. 打通**免电脑、纯手机端**启动路径（StikDebug on-device JIT）。

最终成果已在 iPhone DUO（iOS 27.2.1）实机验证：中文桌面正常渲染、8 个 VirtIO 驱动全部安装、TXM JIT 生效。

---

## 一、中文 26H1 镜像是怎么做出来的

### 1.1 输入与输出

| 项 | 值 |
|---|---|
| 源 ISO | Win11 26H1 ARM64 zh-cn，`install.wim` 7.6 GB（单映像，Index 1 = Windows 11 Pro） |
| 目标镜像 | `work/windows11.img`，100 GB GPT（EFI 100 MB + MSR 16 MB + NTFS） |
| 交付格式 | `windows11.hvsparse` 18.41 GB（App 端自动解包成 100 GB img） |
| 账户 | 本地账户 `Ammaar`，管理员，自动登录 |
| 驱动 | NetKVM / viogpudo / vioinput / viorng / vioscsi / vioserial / viosock / viostor（全 ARM64） |

### 1.2 Phase 1 — WinPE 里分区 + DISM 部署

入口：`scripts/provision_windows_arm64.py`。关键决策全部来自实机排障：

- **boot.wim 必须用原始 Setup 映像的 Index 2，并把 Boot Index 保持为 2。**
  早期 24H2 用的 `wimlib-imagex export ... --boot` 导出纯 WinPE（单映像 Index 1）在 26H1 上会导致 **UEFI 重启循环**。正确做法是直接 `wimlib-imagex update work/boot_orig.wim 2`，只注入 `startnet.cmd` / `winpeshl.ini` / `unattend_panther.xml`，不导出、不改 Boot Index。
- **不要往 boot.wim 里注入 virtio 驱动文件。** 26H1 的 WinPE 原生识别 NVMe；把 65 MB 驱动塞进 boot.wim 反而导致启动崩溃重启。驱动应放在安装盘的 WINWIM 分区，由脚本在运行时从该分区读取。
- **VIRTIO_ROOT 必须在 `wpeinit` 之后立刻查找并记录。** `diskpart` 创建分区后会重新分配盘符（实测 D:/E: 漂移），在脚本后段再找驱动目录会失败。
- **`dism /Apply-Image` 用 `/Index:1`。** 导出的独立 `install.wim` 只剩一个映像；沿用源盘里的 `Index 3` 会返回错误 87。
- **WinPE 内存至少 8 GB。** 26H1 的 boot.wim 解压后约 2.8 GB（24H2 约 1.4 GB），4 GB 内存会在 UEFI `ConvertPages` 阶段失败并触发 PSCI SYSTEM_RESET 循环。脚本默认 `GUEST_RAM_MB=8192`，Phase 1 实测用 12 GB。
- **磁盘匹配按 100 GB。** diskpart 中文 locale 下输出 `磁盘 0 ... 100 GB`，用 `tokens=1,2,3,4,5` 取 `%%d %%e` 匹配。

### 1.3 驱动注入 — 为什么最终用 RunOnce + pnputil

这是踩坑最多的一环，结论是：**离线 `dism /Image:W:\ /Add-Driver` 在本环境对 26H1 ARM64 持续返回错误 87**（换 NTFS 源目录也一样）。而 WinPE 又不需要这些驱动来识别磁盘，所以没必要在阶段一强装。

最终方案（已验证 8/8 成功）：

1. WinPE 阶段把驱动 `xcopy` 到系统盘的 `C:\_drivers`（NTFS，持久化）；
2. 用 `reg load HKLM\OFFSOFT W:\Windows\System32\config\SOFTWARE` 写入 RunOnce：
   ```
   InstallVirtIO = cmd /c pnputil /add-driver C:\_drivers\*.inf /subdirs /install > C:\driver_install.log 2>&1
   ```
3. 系统首次登录自动执行，`driver_install.log` 确认：
   ```
   NetKVM -> oem1.inf, 已绑定到 PCI\VEN_1AF4&DEV_1041
   viogpudo/vioinput/viorng/vioscsi/vioserial/viosock/viostor -> oem2..oem8
   Total driver packages: 8 / Added: 8
   ```

历史教训（勿重蹈）：
- `for /f "usebackq delims=" %%D in ("X:\virtio")` 不会遍历目录，要用 `for /d` 或显式枚举子目录名；
- 脚本里 `>> D:\provision_status.txt` 的盘符在 DISM 后会漂移（D: 从 WINPE 变成 WINWIM），状态文件因此分裂成两份，排障时要两个分区都看；
- SetupComplete.cmd 方案在此部署方式下未被执行，RunOnce 才可靠。

### 1.4 Phase 2 — OOBE

- `PANTHER_UNATTEND_XML` 负责创建本地账户、跳过联网（BypassNRO）、关闭 BitLocker、自动登录，`FirstLogonCommands` 末尾自动关机。
- **QEMU 的串口重定向（EMS）会让 26H1 的图形 OOBE 卡住**；Phase 2 必须改用带 ramfb 的 `build/winvm` 才能跑完 OOBE 并进桌面。
- 装机阶段反过来更适合 QEMU（hvf）：winvm 下 26H1 WinPE 会循环 SYSTEM_RESET。即：**装机用 QEMU，OOBE/运行用 winvm**。
- 目标盘装好 Windows 后，UEFI 会优先从 Windows Boot Manager 启动。若还需从安装盘引导做修复，必须用 QEMU `bootindex=1` 强制安装盘优先，否则会陷入重启循环。

### 1.5 打包与传输

```bash
./build/hvsparse pack work/windows11.img work/windows11.hvsparse
```

传输到 iPhone（UDID `00008160-000A70EC21E00036`，Bundle `me.ammaar.windowsios.83K872NSAG`）：

```bash
# 旧 img 置 0，触发 App 端解包
: > /tmp/empty_img
xcrun devicectl device copy to --device $UDID --domain-type appDataContainer \
  --domain-identifier $BID --source /tmp/empty_img \
  --destination Documents/Machines/Win11/windows11.img
# 传三个文件
for f in code.fd vars.fd windows11.hvsparse; do
  xcrun devicectl device copy to --device $UDID --domain-type appDataContainer \
    --domain-identifier $BID --source work/$f --destination Documents/Machines/Win11/$f
done
```

---

## 二、App 汉化

### 2.1 改动范围

| 文件 | 内容 |
|---|---|
| `ios/Sources/SessionView.swift` | 工具栏/快捷磁贴/状态栏/按钮文本（笔记本模式、资源管理器、启用 JIT、启动 Windows 11、重试启动、设备名称、可用内存 等） |
| `ios/Sources/VMViewModel.swift` | PostureMode / DeckLayout 增加 `localizedName`；JIT/VM 状态初值中文化；**修复 StikDebug URL scheme** |
| `ios/Sources/LaptopDeckView.swift` | 布局标签「分屏」（键盘键位名 Shift/Ctrl/Alt/Win/Caps/Fn 保留英文，符合 Windows 习惯） |
| `ios/Sources/Native/winios_bridge.m` | VM 状态文本（空闲、正在解压、等待 TXM JIT、正在运行、已停止 等） |
| `ios/Sources/Native/winios_jit.c` | JIT 状态文本（尚未初始化、陷阱保护已就绪、已就绪、失败原因 等） |
| `ios/Sources/Info.plist` + `ios/project.yml` | 麦克风用途说明汉化；`LSApplicationQueriesSchemes` 加 `stikdebug` / `stikjit` |

### 2.2 关键 BUG：StikDebug URL scheme

原代码用 `stikjit://enable-jit?...`，但 **StikDebug 3.2.2 只认 `stikdebug://enable-jit`**，导致手机上点「启用 JIT」毫无反应。已改为 `URLComponents` 构造：

```
stikdebug://enable-jit?bundle-id=<bundleID>&pid=<pid>&script-data=<base64(henge-jit.js)>
```

注意 `script-data` 用标准 base64（含 `+` `/` `=`），由 `URLComponents` 自动百分号编码，不要手工改成 URL-safe 变体。

### 2.3 编译注意（Agent/沙箱环境）

Xcode 27.2 在受限环境下编译 SwiftUI 会因宏插件 `swift-plugin-server` 被 `sandbox-exec` 拦截而报 `malformed response`。解决：

```bash
xcodebuild ... CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-Xfrontend -disable-sandbox"
```

---

## 三、免电脑启动（StikDebug on-device JIT）

### 3.1 原理

JIT 依赖外部调试器响应 App 的两个 BRK 陷阱：

- `BRK #0x69`：探测，调试器把 `x0` 写成 `0xE0000069`；
- `BRK #0xF00D`：`x16=1` 申请并"祝福" RX 页（384 MiB），`x16=0` 请求 detach。

电脑端由 `scripts/_lldb_txm_jit.py` 处理；**手机端由 App 内置的 `henge-jit.js` 交给 StikDebug 处理，二者协议完全等价**。这就是免电脑的理论基础。

### 3.2 踩过的坑

- StikDebug 若**装在 LiveContainer 内部**，`stikdebug://` URL scheme 不会注册到 iOS 系统，App 内点按钮无反应。必须**独立安装** StikDebug（最终设备上是 `com.stik.stikdebug.83K872NSAG`）。
- iOS 27 可在手机内直接配对：StikDebug → 设置 → 配对设备 → 配对 iPhone → 系统「隐私与安全性 → 开发者模式」→ 选 StikDebug → 输锁屏密码 → 填 6 位配对码。
- 需要 **LocalDevVPN** 打开本地回环通道，并在 LiveContainer 设置里把 JIT 启动工具指向 StikDebug（若 StikDebug 装在 LiveContainer 内则选 "Another LiveContainer/Multitask"）。
- App 与镜像必须在**同一个容器**：若 App 是独立安装的，镜像放该 App 自己的 `Documents/Machines/Win11/`；若在 LiveContainer 内，则放对应的 `Documents/Data/Application/<UUID>/Documents/Machines/Win11/`。卸载 App 会连带删除容器内镜像，需重传。

### 3.3 使用流程

1. 手机打开 Windows 11 App → 点「启用 JIT」→ 自动跳 StikDebug 完成附加；
2. 切回 App，`onAppBecameActive()` 会调用 `tryAcquireJIT(true)`，JIT 就绪后自动 `prepareAndStart()`；
3. 首次会解包 hvsparse → img，然后启动 Windows。全程无需电脑。

LLDB 附加偶发卡在符号加载（不打印 `Initial attach settled`）时，终止后重跑 `scripts/launch_on_duo.sh` 即可。

---

## 四、文件清单（本次改动）

```
ios/Sources/Info.plist
ios/Sources/LaptopDeckView.swift
ios/Sources/Native/winios_bridge.m
ios/Sources/Native/winios_jit.c
ios/Sources/SessionView.swift
ios/Sources/VMViewModel.swift
ios/project.yml
scripts/_lldb_txm_jit.py
scripts/deploy_and_verify_duo.py
scripts/launch_on_duo.sh
scripts/optimize_windows_lite.py
scripts/provision_windows_arm64.py
docs/26H1-ZH-BUILD-NOTES.md   (本文)
```

其中 scripts 的改动还包括：设备 UDID / Bundle ID 更新为实机值、LLDB 附加改为轮询寄存器（避免 CoreDevice 上 `SBListener.WaitForEvent` 挂起触发 iOS watchdog）、`WIM_PRO_INDEX` / `WIN_INDEX` 拆分、`GUEST_RAM_MB` 可配、EFI 文件从解包后的 ISO 根目录复制而非 wimlib extract。

---

## 五、高分辨率显示（800×600 → 1920×1080）

### 5.1 为什么 Windows 里改不了分辨率

这是三份可验证来源共同说明的机制：

- 标准 EDK2 `QemuRamfbDxe` 只提供 640×480、800×600、1024×768 三种 GOP 模式（SiliconWin "ARCHITECTURE.md"）；
- 默认 800×600 来自 EDK2 的两个动态 PCD：`PcdVideoHorizontalResolution|800`、`PcdVideoVerticalResolution|600`（Hoffmann "ArmVirtPkg: change qemu default resolution to 1280x800"）；
- Windows on Arm 没有 ramfb 原生驱动，会继承固件设置的 GOP 模式，所以进系统后在显示设置里改无效（SiliconWin "ARCHITECTURE.md"；Ersek "Re: [Qemu-devel] [RfC PATCH] vga: wire up -g switch"）。

本项目的 `devices/fb_display.c` 本身接受 64×64 到 8192×8192 的配置，限制完全在固件端。

### 5.2 采用的方案

移植 SiliconWin 的补丁版 `QemuRamfbDxe`（源码来自 OathWallet/SiliconWin，BSD-2-Clause-Patent）：

- 提供 18 种模式，从 640×480 到 3840×2160；
- 读取 fw_cfg 文件 `opt/siliconwin/resolution`（格式 `"<宽>x<高>"`，上限 5120×2880）作为自定义模式；
- 通过 `PcdSet32S(PcdVideoHorizontalResolution/VerticalResolution, ...)` 让控制台和 OS loader 保持该模式。

本项目的对应改动：

- `firmware/QemuRamfb.c`、`firmware/QemuRamfbDxe.inf`、`firmware/hires-edk2.config`：补丁驱动与 EDK2 构建配置；
- `scripts/build-hires-firmware.sh`：一键构建（QEMU 源码树 → BaseTools → iasl → 固件），产物 `work/firmware-build/hires-code.fd`；
- `devices/winvirt.c`：创建 fw_cfg 后读取环境变量 `HV_RESOLUTION`（如 `1920x1080`），校验范围后写入 `opt/siliconwin/resolution`。host 和 iOS 两端无需改接口。

### 5.3 实机验证结果（2026-11-21，Mac QEMU 11.1.3 + hvf）

| 组合 | 输出分辨率 |
|---|---|
| Homebrew 原版 `edk2-aarch64-code.fd` | 800×600 |
| 定制固件，未指定 HV_RESOLUTION | 1280×800（QEMU 11.1.2 自带 edk2 的默认 PCD） |
| 定制固件 + `HV_RESOLUTION=1920x1080` | 1920×1080 |

用 26H1 中文镜像 + 定制固件 + `HV_RESOLUTION=1920x1080` 启动后，截图确认进入中文桌面（任务栏、图标、壁纸正常），无回归。日志确认 `winvm: requested GOP resolution 1920x1080` 与 `winvm: ramfb configured 1920x1080 stride=7680`。

### 5.4 使用方式

```bash
# 首次构建（需 Homebrew llvm/lld；脚本会自动下载 QEMU 源码并编译 iasl）
./scripts/build-hires-firmware.sh

# 启动
HV_RESOLUTION=1920x1080 ./build/winvm \
  --code work/firmware-build/hires-code.fd \
  --vars work/vars.fd --disk work/windows11.img --ram 6144
```

范围限制：宽 640–5120，高 480–2880。固件自身会再校验一次；无效值被忽略并回退默认模式。

### 5.5 手机端接入（2026-11-21 完成）

高分辨率方案已接入 iOS App，完整链路：

```
启动界面选择 → NSUserDefaults("winios.resolutionPreset")
  → WinIOSBridge.startConfiguredVMInDirectory: setenv("HV_RESOLUTION", "<w>x<h>")
  → devices/winvirt.c 读环境变量并写入 fw_cfg "opt/siliconwin/resolution"
  → patched QemuRamfbDxe 设定 GOP 模式（PcdVideo*Resolution）
  → Windows on Arm 继承该 GOP 模式，进入对应分辨率的中文桌面
```

对应源码改动：

- `ios/Sources/VMViewModel.swift`：新增 `GuestResolution` 枚举，与固件 18 档 GOP 模式一一对应（640×480 → 3840×2160），**默认 1920 × 1080**，选择持久化到 `NSUserDefaults`；
- `ios/Sources/SessionView.swift`：启动遮罩新增中文「显示分辨率」下拉菜单，分「常用 / 更多分辨率」两组；
- `ios/Sources/Native/winios_bridge.h/.m`：新增 `resolutionPreset` 属性；在 `hv_winvm_create` 之前 `setenv("HV_RESOLUTION", ...)`，未设置时 `unsetenv` 回落固件默认模式；`boot_status.txt` 增加 `resolution_preset:` 行便于真机排障。

**向后兼容**：原版 `code.fd` 不认识 `opt/siliconwin/resolution` 这个 fw_cfg key，会直接回落到自身默认模式；因此即使 App 设置了高分辨率，换回旧固件也不会启动失败。反之，新固件 + 不设置分辨率同样能正常启动。

#### 部署记录（已通过 `xcrun devicectl` 完成）

| 文件 | 目标容器 | 目标路径 |
|---|---|---|
| `work/firmware-build/hires-code.fd` | `me.ammaar.windowsios.83K872NSAG` | `Documents/Machines/Win11/code.fd` |
| `build/WindowsiOS_高分辨率.ipa` | `com.kdt.livecontainer.83K872NSAG` | `Documents/WindowsiOS_高分辨率.ipa` |

两份文件均已回读并校验 SHA-256 一致。Mac 侧同步更新 `WindowsIOS_交付_26H1/` 中的 `WindowsiOS.ipa` 与 `code.fd`；旧固件、旧 IPA 分别保留为 `code_800x600_原版.fd`、`WindowsiOS_汉化旧版.ipa` 以便回滚。手机端 `vars.fd` 与 5.3 节 Mac 端 1920×1080 验证所用文件 SHA-256 完全一致，NVRAM 兼容性已覆盖。

> 注意：`libwinvm.a` 必须重新编译。`devices/winvirt.c` 的 `HV_RESOLUTION` 读取逻辑在静态库里，只改 Swift/ObjC 而不重编 `make ios-lib` 会导致设置不生效。

#### 分辨率入口位置（2026-11-21 补充）

初版只把菜单放在启动遮罩里，而启动遮罩仅在 `!vm.isVMRunning` 时显示 —— VM 一旦启动，遮罩整体消失，运行时就找不到菜单了。现已在三处都放入口，覆盖全部界面状态：

| 界面状态 | 入口 |
|---|---|
| VM 未运行（启动遮罩） | 遮罩中部「显示分辨率 / Resolution」下拉菜单，标签上直接显示当前档位 |
| VM 运行 · Studio 展开模式 | 顶部悬浮工具栏**最左侧**（紧跟「开始」按钮）的 `display` 图标胶囊，显示当前值如 `1920x1080` |
| VM 运行 · 笔记本折叠模式 / 工具栏被收起 | 屏幕左上角常驻的半透明 `display` 小胶囊 |

三处共用同一份 `resolutionMenuContent()`，分「常用 / 更多分辨率」两组，菜单内自带生效条件说明。切换档位后屏幕底部会弹出 4.5 秒提示条：「已设为 X，在 Windows 内关机后重新启动虚拟机生效」。

> 分辨率在 `hv_winvm_create` 时读取，**运行中改档位不会立刻改变当前画面**；需在 Windows 内正常关机后回到 App 再启动。若工具栏被收起，点右上角小胶囊可重新展开。

#### 用户操作要点

1. 在 LiveContainer 里用**「替换 / 更新」**导入新 IPA，**不要卸载旧的 Windows 11** —— 卸载会连带清空 App 容器里的 18 GB 镜像与固件。
2. 重新打开 App，点「启用 JIT」经 StikDebug 重新获取 JIT（覆盖安装后 JIT 失效）。
3. 在启动遮罩、工具栏最左侧或左上角胶囊任一入口选择「显示分辨率」（默认 1920 × 1080），点「启动 Windows 11」。
4. 分辨率只在 VM **创建时**读取，切换档位后需重启 VM / App 才生效。

#### 真机验证方法

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer \
  --domain-identifier me.ammaar.windowsios.83K872NSAG \
  --source Documents/boot_status.txt --destination /tmp/boot_status.txt
grep -E "fb_size|resolution_preset" /tmp/boot_status.txt
```

`fb_size: 1920x1080` 且 `resolution_preset: 1920x1080` 即表示链路已生效。

### 5.6 中英双语界面（跟随系统 + 手动切换，2026-11-21 完成）

App 内所有可见文本——启动遮罩、Studio 工具栏、笔记本键盘区、JIT / VM 状态、错误提示——均支持中英文。默认**跟随 iOS 系统语言**：系统首选语言以 `zh` 开头（含 zh-Hans / zh-Hant / zh-HK）显示中文，其余显示英文。

实现要点：

- `ios/Sources/Localization.swift`：`AppLanguage`（`system` / `zhHans` / `en`）+ `LocalizationManager`（`@Published selection`，持久化到 `NSUserDefaults("winios.appLanguage")`）+ 全局便捷函数 `L("中文", "English")`；`effective` 负责 system 判定，View 通过 `@EnvironmentObject` 建立重绘依赖。
- `ios/Sources/Native/winios_l10n.h/.m`：`WinIOSUseEnglish()` / `WinIOSL(zh, en)`，使 **ObjC 与纯 C** 代码读取同一个偏好；`winios_jit.c` 用 `SET_STATUS(zh, en, ...)` 宏在生成状态文本时选语言，两个格式串仍保留编译期 printf 检查。
- `WinIOSBridge.refreshLocalizedStatus`：切换语言时重建缓存的 VM 状态文本；`winios_jit_refresh_status_l10n()` 重建 JIT 状态文本；`notifyChanged` 触发 Swift 层 `syncFromBridge()` 立即刷新。切换即时生效，无需重启 App。
- 语言偏好只影响 **App 界面**，不影响 Windows 客户机系统语言（客户机仍是独立的 26H1 中文版镜像）。
- `NSMicrophoneUsageDescription` 属于系统权限弹窗，无法在运行时切换，因此改为中英双语单句，两种系统语言下都可读。

手动切换入口（两处，VM 运行前后都可达）：

1. 启动遮罩：「界面语言 / Language」下拉菜单；
2. Studio 顶部工具栏：🌐 语言胶囊，显示当前短标签（自动 / 中文 / EN）。

三个选项本身用双语标注（跟随系统 / Auto、简体中文 / Chinese、English / 英文），任何界面语言下都能识别。偏好持久化，下次启动沿用。

> 最终 IPA：`WindowsIOS_交付_26H1/WindowsiOS.ipa`（含高分辨率 + 双语），已同步推送到 LiveContainer 文档目录，覆盖同名旧文件。

---

## 六、Release 交付产物（2026-11-21）

编译产物**不进 git**（`.gitignore` 忽略 `*.ipa` / `*.fd` / `*.hvsparse`），统一发布在 GitHub Release：

**https://github.com/shaliuxin/WindowsiOS/releases/tag/v26H1-zh-hires**（tag `v26H1-zh-hires`，指向 `main @ 40d82d6`）

| 文件 | 大小 | 说明 |
|---|---|---|
| `WindowsiOS.ipa` | 596 KB | 最终版 App（中英双语 + 可切换高分辨率），未签名 |
| `code.fd` | 64 MB | 高分辨率 EDK2 固件（SiliconWin patched `QemuRamfbDxe`） |
| `code_800x600_original.fd` | 64 MB | 原版 800×600 固件，回滚用 |
| `vars.fd` | 64 MB | UEFI NVRAM（与 5.3 节 Mac 端 1920×1080 验证同一份） |
| `WindowsiOS_legacy_zh.ipa` | 536 KB | 上一版中文 IPA，回滚用 |
| `StikDebug-3.2.2.ipa` | 16.9 MB | 免电脑授予 TXM JIT 的宿主工具（基于上游 3.2.2 重新打包，见下） |
| `windows11.hvsparse.zst.part00` … `part05` | 合计 8,701,255,261 B | 镜像 zstd 压缩包（8.10 GiB）再切 6 片 × 1400 MiB |
| `SHA256SUMS` | — | 全部文件（含合并后的 `.zst` 与解压后的原镜像）的校验和 |

### 压缩与分片策略

GitHub Release **单个 asset 硬上限 2 GB**，而 `windows11.hvsparse` 是 18.41 GiB（19,762,451,824 B），无论压缩与否都必须分片。方案演进：

1. 最初按**原始格式**切 14 片（每片 1.4 GiB，总计 18.41 GiB 直传）—— 实测上行仅 ~5.5 MiB/s，每片 4 分钟、全部约 1 小时，对下载方也是巨大负担，已放弃并删除已传分片；
2. 最终改为**先压缩再分片**：`zstd -6 -T0` 多线程压缩 18.41 GiB → **8.10 GiB（44.03%），仅 11.6 秒**，再 `split -b 1400m` 切成 6 片。下载量从 18.41 GiB 降到 8.10 GiB，上传时间同步缩短 58%。

代价是解压需要 `zstd`（macOS `brew install zstd`；主流 Linux 发行版自带；Windows 有官方二进制）。

> 上传实现备忘：`curl --data-binary @file` 会把整个文件读进内存，1.3 GiB 分片直接 OOM。改用 `http.client` 流式 `POST`（手工设置 `Content-Length`，逐 4 MiB 块 `conn.send()`），3 路并发 + 每片 4 次重试 + 「跳过已存在 asset」断点续传。`zstd -T0` 多线程压缩同样关键 —— 单线程 gzip 压 18 GiB 要十几分钟，多线程 zstd 只要 12 秒。

### 下载后还原

```bash
# 需要 zstd：macOS brew install zstd；Linux 大多自带
cat windows11.hvsparse.zst.part* > windows11.hvsparse.zst
shasum -a 256 -c SHA256SUMS         # Linux: sha256sum -c SHA256SUMS
zstd -d windows11.hvsparse.zst      # 得到 19,762,451,824 B 的 windows11.hvsparse
```

把 `windows11.hvsparse`、`code.fd`、`vars.fd` 一起放入 App 容器 `Documents/Machines/Win11/`；当 `windows11.img` 为 0 字节或不存在时，App 会自动解包为 100 GB。若换回 `code_800x600_original.fd`，固件不认识 `opt/siliconwin/resolution` 会回落默认模式，不会启动失败（见 5.5 节向后兼容说明）。

### StikDebug 重新打包说明

`StikDebug-3.2.2.ipa` 基于上游 [`StephenDev0/StikDebug`](https://github.com/StephenDev0/StikDebug) 3.2.2（bundle id `com.stik.stikdebug`，原始分发 [stikdebug.xyz](https://stikdebug.xyz)，主体 MPL-2.0 / StikJIT 部分 BSD-3-Clause）重新打包。相对上游的改动：

- **注册 `stikdebug://` URL scheme**（上游只有 `stikjit://`）—— WindowsiOS 用 `stikdebug://enable-jit?bundle-id=…&pid=…&script-data=…` 唤起，旧 scheme 在 3.2.2 上不生效，这是「点启用 JIT 没反应」的根因；
- 状态文本中文化（`Idle` → `空闲`、`Waiting for TXM JIT…` → `等待 TXM JIT（请用 StikDebug 附加）` 等）；
- 改动**仅在资源层**（`Info.plist` 与 `zh-Hans.lproj/Localizable.strings`），未重新编译可执行文件，也未改动 `universal.js` 等 JIT 逻辑；完整复现步骤、校验和与许可说明见 [`docs/stikdebug-repack.md`](stikdebug-repack.md)。

工作方式：WindowsiOS 发起 URL 请求后，StikDebug 用 `BRK #0x69` 探测 / `BRK #0xF00D` 为目标进程分配并「祝福」384 MiB RX 内存，JIT 即可脱离电脑使用。

### 侧载注意

安装顺序：

1. 先侧载 `StikDebug-3.2.2.ipa`（LiveContainer / AltStore / TrollStore 均可）；
2. 再侧载 `WindowsiOS.ipa` —— 在 LiveContainer 里用**「替换 / 更新」**导入，**不要卸载旧的 Windows 11**（卸载会清空容器里的 18 GB 镜像与固件）；
3. 打开 WindowsiOS，点「启用 JIT」，StikDebug 接管并授予 JIT；
4. 回到 App 点「启动 Windows 11」。

覆盖安装后 JIT 必然失效，每次更新 App 都要重新执行第 3 步。
