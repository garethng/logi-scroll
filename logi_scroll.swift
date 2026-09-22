// logi_scroll — 罗技鼠标滚轮方向反转守护工具（原生独立进程，仅本机使用）
//
// 后台检测连接的罗技鼠标（蓝牙/接收器/有线），识别型号，通过 HID++ 2.0
// 特性 0x2121 (HiResWheel) 把滚轮方向硬件级反转（设置存在设备里，重连后依然生效）。
//
// 协议参考 OpenLogi (https://github.com/AprilNEA/OpenLogi, Apache-2.0/MIT):
//   - HID++ 2.0 短报告: [0x10, dev_idx, feat_idx, func|sw, p0, p1, p2]  (7 字节)
//   - HID++ 2.0 长报告: [0x11, dev_idx, feat_idx, func|sw, p0..p15]    (20 字节)
//   - 部分蓝牙设备只声明长报告，短报文需加宽为长报告发送
//   - 0x2121: fn0=GetWheelCapabilities(bit3=has_invert) fn1=GetWheelMode fn2=SetWheelMode
//     mode 字节: bit0=target(1=diverted) bit1=resolution(1=hi-res) bit2=inverted
//     反转仅在 target=native 时生效
//   - 蓝牙直连设备 dev_idx = 0xFF
//
// HID 通道用 hidapi（vendor/hid.c，BSD 许可，静态编入本二进制）：
// 系统 IOHIDManager 句柄的输入回调在本机蓝牙设备上不投递报告，
// 而 hidapi 的独立读线程实现工作正常。
//
// 用法:
//   logi_scroll run                 守护模式：轮询检测并保持反转（开机自启用）
//   logi_scroll status              列出当前连接的罗技设备及滚轮状态
//   logi_scroll toggle [--on|--off] 一次性切换反转方向（默认来回切换）
//   logi_scroll install             安装 LaunchAgent 开机自启
//   logi_scroll uninstall           移除 LaunchAgent
//
// 构建: ./build.sh

import Foundation
import IOKit.hid
import IOKit

let VID_LOGITECH: UInt32 = 0x046D
let DEV_IDX_DIRECT: UInt8 = 0xFF
let SW_ID: UInt8 = 0x01
let FEATURE_HIRES_WHEEL: UInt16 = 0x2121
let WHEEL_INVERT: UInt8 = 0x04
let POLL_SECONDS: TimeInterval = 2

let AGENT_LABEL = "com.garethng.logi-scroll"
let AGENT_PLIST = NSHomeDirectory() + "/Library/LaunchAgents/\(AGENT_LABEL).plist"
let LOG_PATH = NSHomeDirectory() + "/Library/Logs/logi-scroll.log"

// 常见产品 ID → 型号（识别不到就用设备自报的 product string）
let PID_NAMES: [UInt32: String] = [
    0xB037: "MX Anywhere 3S",
    0xB035: "MX Anywhere 3S (Bolt)",
    0xB015: "MX Master 3",
    0xB023: "MX Master 3 (Bolt)",
    0xB01A: "MX Anywhere 2S",
    0xB01F: "MX Anywhere 2S (Bolt)",
    0xC52B: "Unifying 接收器",
    0xC548: "Bolt 接收器",
]

struct HidppError: Error { let message: String }

// hidapi C 桥接（见 hid_bridge.c）
@_silgen_name("logi_hid_open")
func logiHidOpen(_ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("logi_hid_write")
func logiHidWrite(_ h: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>, _ len: Int) -> Int
@_silgen_name("logi_hid_read_timeout")
func logiHidReadTimeout(_ h: UnsafeMutableRawPointer?, _ data: UnsafeMutablePointer<UInt8>, _ len: Int, _ ms: Int32) -> Int
@_silgen_name("logi_hid_close")
func logiHidClose(_ h: UnsafeMutableRawPointer?)
@_silgen_name("logi_hid_error")
func logiHidError(_ h: UnsafeMutableRawPointer?) -> UnsafePointer<wchar_t>?

func log(_ msg: String) {
    let t = DateFormatter()
    t.dateFormat = "HH:mm:ss"
    print("[\(t.string(from: Date()))] \(msg)")
    fflush(stdout)
}

func makeManager() -> IOHIDManager {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID_LOGITECH] as CFDictionary)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    return mgr
}

func enumerate(_ mgr: IOHIDManager) -> [IOHIDDevice] {
    guard let set = IOHIDManagerCopyDevices(mgr) as NSSet? else { return [] }
    return set.allObjects as? [IOHIDDevice] ?? []
}

func deviceProp(_ dev: IOHIDDevice, _ key: String) -> AnyObject? {
    IOHIDDeviceGetProperty(dev, key as CFString)
}

/// 设备的 hidapi 路径（"DevSrvsID:<registry id>"）
func registryPath(_ dev: IOHIDDevice) -> String {
    var entryID: UInt64 = 0
    let service = IOHIDDeviceGetService(dev)
    IORegistryEntryGetRegistryEntryID(service, &entryID)
    return "DevSrvsID:\(entryID)"
}

/// 一个罗技 HID++ 2.0 设备。通信走 hidapi（写报告 → 读回复）。
final class LogiDevice {
    let dev: IOHIDDevice
    let name: String
    let serial: String
    let pid: UInt32
    let path: String
    let key: String
    var wheelFeatureIndex: UInt8 = 0
    private var shortWorks = false
    private var longWorks = false
    private var handle: UnsafeMutableRawPointer?

    init(_ dev: IOHIDDevice, name: String, serial: String, pid: UInt32) {
        self.dev = dev
        self.name = name
        self.serial = serial
        self.pid = pid
        self.path = registryPath(dev)
        self.key = "\(serial):\(pid)"
    }

    var modelName: String {
        name.isEmpty ? (PID_NAMES[pid] ?? String(format: "PID 0x%04X", pid)) : name
    }

    func open() -> Bool {
        if handle != nil { return true }
        guard let h = logiHidOpen(path) else {
            if let err = logiHidError(nil) {
                log("hidapi 错误: \(String(decodingCString: UnsafeRawPointer(err).assumingMemoryBound(to: UInt32.self), as: UTF32.self)) (path=\(path))")
            }
            return false
        }
        handle = h
        return true
    }

    func close() {
        if let h = handle {
            logiHidClose(h)
            handle = nil
        }
    }

    /// 发一条 HID++ 2.0 消息（优先短报告，无响应则加宽为长报告）。
    /// 返回 16 字节 payload。
    func call(featureIndex: UInt8, function: UInt8, params: [UInt8],
              timeout: TimeInterval = 3) throws -> [UInt8] {
        guard let h = handle else {
            throw HidppError(message: "设备未打开")
        }
        let header = [DEV_IDX_DIRECT, featureIndex, (function << 4) | SW_ID]
        var useLong = longWorks && !shortWorks
        while true {
            var msg: [UInt8]
            if useLong {
                msg = [0x11] + header + params + Array(repeating: 0, count: 16 - params.count)
            } else {
                msg = [0x10] + header + Array(params.prefix(3))
            }
            let w = msg.withUnsafeBytes { rb -> Int in
                logiHidWrite(h, rb.baseAddress!.assumingMemoryBound(to: UInt8.self), msg.count)
            }
            if w < 0 {
                if !useLong { useLong = true; continue }
                throw HidppError(message: "写入失败")
            }
            // 读输入报告，直到拿到匹配请求头的回复
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var buf = [UInt8](repeating: 0, count: 64)
                let ms = Int32(max(10, Int(deadline.timeIntervalSinceNow * 1000)))
                let n = buf.withUnsafeMutableBytes { rb -> Int in
                    logiHidReadTimeout(h, rb.baseAddress!.assumingMemoryBound(to: UInt8.self), 64, ms)
                }
                if n <= 0 { break }  // 超时或出错
                let data = Array(buf.prefix(n))
                guard data[0] == 0x10 || data[0] == 0x11, data.count > 3 else { continue }
                let hdr = Array(data.dropFirst().prefix(3))
                // 匹配请求头；错误回复把 feat_idx 字段置 0xFF 且字节右移
                if hdr == header || (hdr[0] == header[0] && hdr[1] == 0xFF && hdr[2] == header[1]) {
                    shortWorks = shortWorks || !useLong
                    longWorks = longWorks || useLong
                    // 注意: 蓝牙直连回复里 data[1](dev_idx) 恒为 0xFF，错误标志看 feat_idx 字段 data[2]
                    if data[2] == 0xFF {
                        throw HidppError(message: "HID++ 错误码 \(data[5])")
                    }
                    return Array(data.dropFirst(4).prefix(16))
                }
            }
            if !useLong && shortWorks != true {
                useLong = true  // 短报告无响应，改试长报告
                continue
            }
            throw HidppError(message: "设备无响应")
        }
    }

    /// 确认设备支持 0x2121 且带 has_invert。返回 (caps, mode)，不支持抛错。
    func probe() throws -> ([UInt8], [UInt8]) {
        let r = try call(featureIndex: 0x00, function: 0x00, params: [0x21, 0x21, 0x00]) // Root fn0 GetFeature
        wheelFeatureIndex = r[0]
        guard wheelFeatureIndex != 0 else {
            throw HidppError(message: "设备不支持 0x2121")
        }
        let caps = try call(featureIndex: wheelFeatureIndex, function: 0x00, params: [0, 0, 0])
        let mode = try call(featureIndex: wheelFeatureIndex, function: 0x01, params: [0, 0, 0])
        guard caps.count > 1, caps[1] & 0x08 != 0 else {
            throw HidppError(message: "不支持滚轮反转（has_invert=否）")
        }
        return (caps, mode)
    }

    func setMode(_ modeByte: UInt8) throws -> UInt8 {
        try call(featureIndex: wheelFeatureIndex, function: 0x02, params: [modeByte, 0, 0])[0]
    }

    /// 应用反转。返回 (是否生效, 描述)。
    func applyInvert(_ want: Bool) -> (Bool, String) {
        do {
            let (_, mode) = try probe()
            let current = mode[0]
            // 保留 resolution，清 target 为 native（反转只在 native 生效），按需设/清 invert
            let new = (current & 0x02) | (want ? WHEEL_INVERT : 0)
            if new == current {
                return (true, "已是\(want ? "反转" : "正常")方向")
            }
            let back = try setMode(new)
            let ok = (back & WHEEL_INVERT) == (want ? WHEEL_INVERT : 0)
            let desc = String(format: "mode 0x%02X -> 0x%02X (inverted=%@, target=%@)",
                              current, back, back & WHEEL_INVERT != 0 ? "是" : "否",
                              back & 1 != 0 ? "diverted" : "native")
            return (ok, desc)
        } catch {
            return (false, "\(error)")
        }
    }
}

// MARK: - 命令实现

func runDaemon() {
    let mgr = makeManager()
    var handles: [String: LogiDevice] = [:]
    var applied = Set<String>()
    log("守护启动，轮询罗技设备……")
    while true {
        var seen = Set<String>()
        for dev in enumerate(mgr) {
            let name = deviceProp(dev, kIOHIDProductKey) as? String ?? ""
            let serial = deviceProp(dev, kIOHIDSerialNumberKey) as? String ?? ""
            let pid = (deviceProp(dev, kIOHIDProductIDKey) as? NSNumber)?.uint32Value ?? 0
            let key = "\(serial):\(pid)"
            seen.insert(key)
            if applied.contains(key) { continue }
            let d = handles[key] ?? LogiDevice(dev, name: name, serial: serial, pid: pid)
            handles[key] = d
            if !d.open() {
                log("\(d.modelName): 打开设备失败")
                continue
            }
            let (ok, msg) = d.applyInvert(true)
            // 应用成功后立即释放设备：status/toggle 等其他进程需要能并发打开
            // （蓝牙设备只允许一个客户端持有，常开句柄会导致独占访问冲突）
            d.close()
            handles.removeValue(forKey: key)
            if ok {
                applied.insert(key)
                log("\(d.modelName) (\(serial)) 反转已生效：\(msg)")
            } else {
                // 失败则下个周期重试（可能设备在重连/休眠）
                log("\(d.modelName) 暂不可用：\(msg)")
            }
        }
        for k in handles.keys where !seen.contains(k) {
            handles[k]?.close()
            handles.removeValue(forKey: k)
            if applied.remove(k) != nil {
                log("设备断开，等待重连")
            }
        }
        Thread.sleep(forTimeInterval: POLL_SECONDS)
    }
}

func cmdStatus() {
    let mgr = makeManager()
    let devs = enumerate(mgr)
    if devs.isEmpty {
        print("未检测到罗技设备")
        return
    }
    for dev in devs {
        let name = deviceProp(dev, kIOHIDProductKey) as? String ?? ""
        let serial = deviceProp(dev, kIOHIDSerialNumberKey) as? String ?? ""
        let pid = (deviceProp(dev, kIOHIDProductIDKey) as? NSNumber)?.uint32Value ?? 0
        let d = LogiDevice(dev, name: name, serial: serial, pid: pid)
        defer { d.close() }
        if !d.open() {
            print("\(d.modelName): 无法打开设备")
            continue
        }
        do {
            let (caps, mode) = try d.probe()
            let m = mode[0]
            print("\(d.modelName) (serial=\(serial), path=\(d.path))")
            print("  inverted=\(m & 4 != 0 ? "是" : "否")  resolution=\(m & 2 != 0 ? "hi-res" : "low")  "
                  + "target=\(m & 1 != 0 ? "diverted" : "native")  has_invert=\(caps[1] & 8 != 0 ? "是" : "否")  "
                  + "棘轮齿数=\(caps[2])  直径=\(caps[3])mm")
        } catch {
            print("\(d.modelName): \(error)")
        }
    }
}

func cmdToggle(force: Bool?) {
    let mgr = makeManager()
    let devs = enumerate(mgr)
    if devs.isEmpty {
        print("未检测到罗技设备")
        return
    }
    for dev in devs {
        let name = deviceProp(dev, kIOHIDProductKey) as? String ?? ""
        let serial = deviceProp(dev, kIOHIDSerialNumberKey) as? String ?? ""
        let pid = (deviceProp(dev, kIOHIDProductIDKey) as? NSNumber)?.uint32Value ?? 0
        let d = LogiDevice(dev, name: name, serial: serial, pid: pid)
        defer { d.close() }
        if !d.open() {
            print("\(d.modelName): 无法打开设备")
            continue
        }
        var want = force
        if want == nil {
            do {
                let (_, mode) = try d.probe()
                want = mode[0] & WHEEL_INVERT == 0
            } catch {
                print("\(d.modelName): \(error)")
                continue
            }
        }
        let (ok, msg) = d.applyInvert(want!)
        print("\(d.modelName): \(want! ? "反转" : "正常") -> \(ok ? "OK" : "失败") (\(msg))")
    }
}

func cmdInstall() {
    // 守护进程二进制固定在 ~/Library/Application Support/logi-scroll/：
    // ~/Documents 受 TCC 文件保护，launchd 加载那里的二进制不稳定。
    let raw = CommandLine.arguments[0]
    let src = raw.hasPrefix("/") ? raw : FileManager.default.currentDirectoryPath + "/" + raw
    guard FileManager.default.isExecutableFile(atPath: src) else {
        print("找不到可执行文件: \(src)")
        exit(1)
    }
    let dstDir = NSHomeDirectory() + "/Library/Application Support/logi-scroll"
    let dstBin = dstDir + "/logi_scroll"
    try? FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
    do {
        try? FileManager.default.removeItem(atPath: dstBin)
        try FileManager.default.copyItem(atPath: src, toPath: dstBin)
    } catch {
        print("复制失败: \(error)")
        exit(1)
    }
    let exeURL = URL(fileURLWithPath: dstBin).standardizedFileURL
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(AGENT_LABEL)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(exeURL.path)</string>
            <string>run</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>StandardOutPath</key><string>\(LOG_PATH)</string>
        <key>StandardErrorPath</key><string>\(LOG_PATH)</string>
    </dict>
    </plist>
    """
    try? FileManager.default.createDirectory(atPath: (AGENT_PLIST as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try? plist.write(toFile: AGENT_PLIST, atomically: true, encoding: .utf8)
    let _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                             arguments: ["bootout", "gui/\(getuid())/\(AGENT_LABEL)"]) { _ in }
    let r = Process()
    r.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    r.arguments = ["bootstrap", "gui/\(getuid())", AGENT_PLIST]
    let err = Pipe()
    r.standardError = err
    try? r.run()
    r.waitUntilExit()
    if r.terminationStatus != 0 {
        let data = err.fileHandleForReading.readDataToEndOfFile()
        print("安装失败: \(String(data: data, encoding: .utf8) ?? "")")
        exit(1)
    }
    print("已安装并启动。日志: \(LOG_PATH)")
    print("注意: 重新编译后需在 系统设置→隐私与安全性→输入监控 中重新添加一次")
    print("      \(dstBin)")
    print("验证: logi_scroll status")
}

func cmdUninstall() {
    let _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                             arguments: ["bootout", "gui/\(getuid())/\(AGENT_LABEL)"]) { _ in }
    try? FileManager.default.removeItem(atPath: AGENT_PLIST)
    print("已移除开机自启")
}

func usage() {
    print("""
    用法: logi_scroll <run|status|toggle|install|uninstall>
      run                 守护模式：轮询检测并保持反转
      status              列出当前连接的罗技设备及滚轮状态
      toggle [--on|--off] 切换反转方向（默认来回切换）
      install             安装 LaunchAgent 开机自启
      uninstall           移除 LaunchAgent
    """)
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(1) }
switch args[1] {
case "run":
    runDaemon()
case "status":
    cmdStatus()
case "toggle":
    let force: Bool?
    if args.contains("--on") { force = true }
    else if args.contains("--off") { force = false }
    else { force = nil }
    cmdToggle(force: force)
case "install":
    cmdInstall()
case "uninstall":
    cmdUninstall()
default:
    usage()
    exit(1)
}
