# StikDebug 3.2.2 重新打包说明

> Release 附件 `StikDebug-3.2.2.ipa` 的来历、改动范围与复现方式。

## 上游与许可

| 项目 | 内容 |
|---|---|
| 上游仓库 | [`StephenDev0/StikDebug`](https://github.com/StephenDev0/StikDebug) |
| 许可证 | 主体 **MPL-2.0**；其中 StikJIT 相关部分 **BSD-3-Clause** |
| 原始 IPA 分发 | <https://stikdebug.xyz>（`index.json` 指向 3.2.2） |
| 本仓库附件 | `StikDebug-3.2.2.ipa`，16,924,687 B，SHA-256 `2f238d89ba828d41b7830e4b1bae44ee6fd04e50d3d8c0ffe15ad47bd66af170` |
| Bundle ID / 版本 | `com.stik.stikdebug` / `3.2.2`（`CFBundleVersion` 1） |

版权归上游作者所有。本仓库仅因兼容性需要重新打包，未主张任何额外权利；若上游要求调整分发方式，可随时下架该附件。

## 为什么必须重新打包

上游 3.2.2 的 `Info.plist` 只注册了 `stikjit://`，而 WindowsiOS 的免电脑 JIT 流程使用：

```
stikdebug://enable-jit?bundle-id=<app>&pid=<pid>&script-data=<base64 of henge-jit.js>
```

旧 scheme 未被注册时，`UIApplication.open` 直接返回失败、没有任何界面反应 —— 这是「点启用 JIT 没反应」的根因（见 `docs/26H1-ZH-BUILD-NOTES.md` 第 3.2 节）。

## 修改范围（仅资源层）

1. `Payload/StikDebug.app/Info.plist`
   `CFBundleURLTypes[0].CFBundleURLSchemes` 追加 `stikdebug`（保留原有 `stikjit`）。
2. `Payload/StikDebug.app/zh-Hans.lproj/Localizable.strings`
   状态文案中文化，例如 `Idle` → `空闲`、`Waiting for TXM JIT...` → `等待 TXM JIT（请用 StikDebug 附加）`。

**没有重新编译可执行文件**，`Payload/StikDebug.app/StikDebug` 与上游 3.2.2 一致；也没有改动 `universal.js` / `maciOS.js` / `Geode.js` / `legacy.js` 的 JIT 逻辑。

## 复现步骤

```bash
# 1. 取上游 3.2.2 IPA（stikdebug.xyz 或其 GitHub Release）
unzip -q StikDebug-3.2.2.ipa -d stik

# 2. 注册 stikdebug:// scheme
plutil -insert 'CFBundleURLTypes.0.CFBundleURLSchemes.2' \
       -string stikdebug stik/Payload/StikDebug.app/Info.plist
plutil -p stik/Payload/StikDebug.app/Info.plist | grep -A4 CFBundleURLSchemes
#   => 0 => stikdebug
#      1 => stikjit

# 3.（可选）替换 zh-Hans.lproj/Localizable.strings 中的状态文案

# 4. 重新打包
cd stik && zip -qr ../StikDebug-3.2.2.ipa Payload && cd ..
shasum -a 256 StikDebug-3.2.2.ipa
```

重新打包后**必须保持未签名**，由 LiveContainer / AltStore / TrollStore 侧载时再签名；签名会改变二进制，SHA-256 随之变化。

## 使用顺序

1. 先侧载本 IPA（宿主工具）；
2. 再侧载 `WindowsiOS.ipa`；
3. 打开 WindowsiOS → 「启用 JIT」→ StikDebug 接管并用 `BRK #0x69` / `BRK #0xF00D` 为目标进程祝福 384 MiB RX 内存；
4. 回到 App → 「启动 Windows 11」。

每次覆盖安装 WindowsiOS 后 JIT 都会失效，需要重新执行第 3 步。
