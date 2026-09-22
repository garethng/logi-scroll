# logi-scroll

罗技鼠标滚轮方向反转工具 —— 单个原生二进制，后台守护 + 开机自启，把反转设置**直接写进鼠标硬件**。

无驱动、无事件注入、无账号、无遥测，仅 macOS（本人在用）。

## 特性

- 自动检测连接的罗技鼠标（蓝牙/有线直连），识别型号
- 通过 HID++ 2.0 特性 `0x2121` (HiResWheel) 硬件级反转滚轮方向
  —— 设置存在设备里，重连、重启、换电脑（装同一软件）后依然生效
- LaunchAgent 守护进程：开机自启、崩溃自动拉起、设备重连自动重新应用
- 附带 `status` / `toggle` 命令行，随时查看状态或临时切换方向

## 工作原理

```
检测(vendor 0x046D) → Root GetFeature(0x2121) 解析特性索引
  → GetWheelCapabilities 确认 has_invert → SetWheelMode 写回 mode 字节
```

- HID++ 2.0 短报告 `0x10`(7B) / 长报告 `0x11`(20B)，蓝牙设备可能只声明长报告，协议层自动回退
- mode 字节：`bit2 = inverted`，`bit1 = resolution`，`bit0 = target`；
  反转仅在 `target=native` 生效（工具会顺带清除 Logi Options+ 遗留的 diverted 模式）
- 蓝牙直连设备 device index = `0xFF`

协议参考 [OpenLogi](https://github.com/AprilNEA/OpenLogi)（Apache-2.0/MIT）；
HID 通道使用 [hidapi](https://github.com/libusb/hidapi)（`vendor/`，BSD 许可，静态编入二进制）。

## 构建

需要 Xcode Command Line Tools（swiftc + clang），无其他依赖：

```bash
./build.sh          # 输出 ./logi_scroll
```

## 安装（开机自启）

```bash
logi_scroll install
```

install 把二进制复制到 `~/Library/Application Support/logi-scroll/` 并安装
LaunchAgent `com.garethng.logi-scroll`（`RunAtLoad` + `KeepAlive`），
日志在 `~/Library/Logs/logi-scroll.log`。

### ⚠️ 需授权一次「输入监控」

macOS 会拦截 launchd 进程打开 HID 设备（`0xE00002E2 not permitted`）。安装后：

1. **系统设置 → 隐私与安全性 → 输入监控** → 点「+」
2. `Cmd+Shift+G` 定位到 `/Users/<你>/Library/Application Support/logi-scroll/`
3. 选中 `logi_scroll` 添加，开关保持打开
4. `launchctl kickstart -k gui/$(id -u)/com.garethng.logi-scroll` 重启守护进程

> 授权按「路径 + 二进制哈希」绑定：**重新编译后需重复上述步骤一次**。

## 用法

建议软链到 PATH（如 `/opt/homebrew/bin`），任意目录可用：

```bash
logi_scroll status              # 列出当前罗技设备及滚轮状态
logi_scroll toggle              # 反转 <-> 正常 来回切换
logi_scroll toggle --on/--off   # 指定方向
logi_scroll uninstall           # 移除开机自启
```

## 支持设备

- 实测：**MX Anywhere 3S**（蓝牙直连，PID 0xB037）
- 理论支持所有 HID++ 2.0 且 `0x2121` capabilities 中 `has_invert=1` 的罗技鼠标
  （MX Master 3 / Anywhere 2S/3 系列等），蓝牙、有线直连均可
- 经 Unifying/Bolt 接收器连接：需要接收器设备枚举，**暂未实现**

## 注意事项

- **不要重装 Logi Options+**：它会独占 HID 设备，导致本工具打不开鼠标
- 蓝牙设备重连后约 10 秒内自动重新应用（含唤醒与协议探测时间）
- 守护进程应用完即释放设备句柄，不会影响 `status`/`toggle` 并发使用

## 项目结构

```
logi_scroll.swift    # 主程序（Swift，约 400 行）
hid_bridge.c/h       # hidapi 最小 C 桥接
vendor/hid.c 等      # hidapi 源码（BSD-3-Clause）
build.sh             # 一键编译
```
