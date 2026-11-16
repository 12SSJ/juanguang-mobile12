import Foundation
import UIKit
import CryptoKit
import Security
import Capacitor

/* ---------------- 设备机器码与注册激活 ----------------
   机器码 = SHA-256(机型 | 线程数 | 物理内存 | IDFV | Keychain 种子) 前 16 位。
   注册码算法与安卓/电脑版一致：时段索引(1 位) + SHA-256(机器码 | 时段索引 | 固定密钥) 前 16 位，
   展示为 X-XXXX-XXXX-XXXX-XXXX；时段：0 永久 1 一个月 2 三个月 3 七个月 4 一年 5 三年。
   旧版 16 位注册码继续有效（视为永久）。
   IDFV 在卸载 App 后会变化，因此额外生成一个随机种子存进 Keychain，
   保证同一台设备重装后机器码依然稳定。 */

@objc(GyDevicePlugin)
public class GyDevicePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GyDevicePlugin"
    public let jsName = "GyDevice"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getActivationState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "activate", returnType: CAPPluginReturnPromise)
    ]

    private let secret = "JGY-2026-MOONLIGHT"
    private let defaultsKey = "gy_license_code"
    private let defaultsActivatedAt = "gy_license_activated_at"
    private let defaultsExpireAt = "gy_license_expire_at"
    private let keychainService = "com.guangying.yueying.machine"
    private let keychainAccount = "machine_seed"

    /** 时段索引、名称与月数（0 为永久） */
    private let licenseKeys = ["0", "1", "2", "3", "4", "5"]
    private let licenseNames = ["永久授权", "1 个月", "3 个月", "7 个月", "1 年", "3 年"]
    private let licenseMonths = [0, 1, 3, 7, 12, 36]

    private struct MachineInfo {
        let code: String
        let cpu: String
        let memoryGb: Double
        let brand: String
    }

    @objc func getActivationState(_ call: CAPPluginCall) {
        let info = machineInfo()
        let defaults = UserDefaults.standard
        var saved = normalize(defaults.string(forKey: defaultsKey) ?? "")
        let index = matchLicense(machine: info.code, code: saved)
        var activatedAt = defaults.double(forKey: defaultsActivatedAt)
        var expireAt = defaults.double(forKey: defaultsExpireAt)

        // 旧版 16 位注册码校验通过后自动升级为新格式（永久），用户无感知
        if index == 0 && saved.count == 16 {
            saved = normalize(expectedCode(machine: info.code, index: "0"))
            if activatedAt <= 0 { activatedAt = nowMillis() }
            defaults.set(saved, forKey: defaultsKey)
            defaults.set(activatedAt, forKey: defaultsActivatedAt)
            defaults.set(0, forKey: defaultsExpireAt)
            expireAt = 0
        }

        // 有期限的码若缺少到期时间（老数据），按激活时间补算，避免误判为永久
        if index > 0 && expireAt <= 0 {
            let base = activatedAt > 0 ? activatedAt : nowMillis()
            expireAt = addMonths(base, months: licenseMonths[index])
            if activatedAt > 0 {
                defaults.set(expireAt, forKey: defaultsExpireAt)
            }
        }

        let matched = index >= 0
        let expired = matched && expireAt > 0 && nowMillis() >= expireAt
        let activated = matched && !expired

        let result: [String: Any] = [
            "activated": activated,
            "expired": expired,
            "licenseType": matched ? licenseNames[index] : "",
            "activatedAt": activatedAt,
            "expireAt": matched ? expireAt : 0,
            "expireText": matched ? (expireAt > 0 ? formatDate(expireAt) : "永久有效") : "",
            "code": info.code,
            "cpu": info.cpu,
            "cores": ProcessInfo.processInfo.processorCount,
            "memoryGb": String(format: "%.1f", info.memoryGb),
            "brand": info.brand
        ]
        call.resolve(result)
    }

    @objc func activate(_ call: CAPPluginCall) {
        let input = normalize(call.getString("code") ?? "")
        if input.isEmpty {
            call.reject("请输入注册码")
            return
        }
        let info = machineInfo()
        let index = matchLicense(machine: info.code, code: input)
        if index < 0 {
            call.reject("注册码不正确，请核对机器码后重新获取")
            return
        }
        let now = nowMillis()
        let expireAt = licenseMonths[index] == 0 ? 0 : addMonths(now, months: licenseMonths[index])
        let defaults = UserDefaults.standard
        defaults.set(input, forKey: defaultsKey)
        defaults.set(now, forKey: defaultsActivatedAt)
        defaults.set(expireAt, forKey: defaultsExpireAt)
        call.resolve([
            "activated": true,
            "licenseType": licenseNames[index],
            "expireAt": expireAt,
            "expireText": expireAt > 0 ? formatDate(expireAt) : "永久有效"
        ])
    }

    /* ---------------- 机器码 ---------------- */

    private func machineInfo() -> MachineInfo {
        let machine = hardwareModel()
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1024.0 / 1024.0 / 1024.0
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "no-idfv"
        let raw = [
            machine,
            String(ProcessInfo.processInfo.processorCount),
            String(ProcessInfo.processInfo.physicalMemory),
            idfv,
            machineSeed()
        ].joined(separator: "|")
        let code = formatCode(String(sha256Hex(raw).prefix(16)))
        return MachineInfo(
            code: code,
            cpu: machine,
            memoryGb: memory,
            brand: "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
        )
    }

    private func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let model = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return model.isEmpty ? "iphone" : model
    }

    /* ---------------- Keychain 种子 ---------------- */

    private func machineSeed() -> String {
        if let seed = keychainValue() { return seed }
        let seed = UUID().uuidString
        keychainSet(seed)
        return seed
    }

    private func keychainValue() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainSet(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock as String
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /* ---------------- 授权算法 ---------------- */

    /// 新注册码：时段索引 + SHA-256(机器码|时段索引|密钥) 前 16 位
    private func expectedCode(machine: String, index: String) -> String {
        formatCode(index + String(sha256Hex(normalize(machine) + "|" + index + "|" + secret).prefix(16)))
    }

    /// 旧版 16 位永久码，继续有效
    private func legacyCode(machine: String) -> String {
        formatCode(String(sha256Hex(normalize(machine) + "|" + secret).prefix(16)))
    }

    /// 命中返回时段下标，未命中返回 -1
    private func matchLicense(machine: String, code: String) -> Int {
        if code.count == 17 {
            for (index, key) in licenseKeys.enumerated() {
                if code == normalize(expectedCode(machine: machine, index: key)) {
                    return index
                }
            }
            return -1
        }
        if code.count == 16 && code == normalize(legacyCode(machine: machine)) {
            return 0
        }
        return -1
    }

    private func nowMillis() -> Double {
        return Date().timeIntervalSince1970 * 1000
    }

    /// 按自然月累加（1 月 31 日 + 1 个月落到 2 月最后一天）
    private func addMonths(_ base: Double, months: Int) -> Double {
        let date = Date(timeIntervalSince1970: base / 1000)
        let next = Calendar.current.date(byAdding: .month, value: months, to: date) ?? date
        return next.timeIntervalSince1970 * 1000
    }

    private func formatDate(_ millis: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    private func normalize(_ value: String) -> String {
        value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 17 位码按 X-4-4-4-4 分组，16 位码按 4-4-4-4 分组
    private func formatCode(_ raw: String) -> String {
        let chars = Array(raw.uppercased())
        if chars.count >= 17 {
            return "\(String(chars[0..<1]))-\(String(chars[1..<5]))-\(String(chars[5..<9]))-\(String(chars[9..<13]))-\(String(chars[13..<17]))"
        }
        guard chars.count >= 16 else { return raw.uppercased() }
        return "\(String(chars[0..<4]))-\(String(chars[4..<8]))-\(String(chars[8..<12]))-\(String(chars[12..<16]))"
    }

    private func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/* ---------------- 原生 GET 请求 ----------------
   音乐接口需要 Referer / Origin，WebView 的 fetch 会丢掉这些受限请求头，
   这里用 URLSession 发原生请求，返回 Base64 字节给前端。 */

@objc(GyHttpPlugin)
public class GyHttpPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GyHttpPlugin"
    public let jsName = "GyHttp"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "get", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "post", returnType: CAPPluginReturnPromise)
    ]

    @objc func get(_ call: CAPPluginCall) {
        request(call, method: "GET", body: "")
    }

    @objc func post(_ call: CAPPluginCall) {
        request(call, method: "POST", body: call.getString("body") ?? "")
    }

    private func request(_ call: CAPPluginCall, method: String, body: String) {
        guard let urlString = call.getString("url"), let url = URL(string: urlString) else {
            call.reject("缺少 url")
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let headers = call.getObject("headers") ?? [:]
        for (key, value) in headers {
            if let text = value as? String {
                request.setValue(text, forHTTPHeaderField: key)
            }
        }
        if method == "POST" && !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                call.reject(error.localizedDescription)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 把响应头拍平（同名多值用换行分隔），前端靠 Set-Cookie 取会话
            var headerMap: [String: String] = [:]
            if let all = (response as? HTTPURLResponse)?.allHeaderFields {
                for (key, value) in all {
                    let name = String(describing: key)
                    let text = String(describing: value)
                    if let old = headerMap[name] {
                        headerMap[name] = old + "\n" + text
                    } else {
                        headerMap[name] = text
                    }
                }
            }
            call.resolve([
                "status": status,
                "contentType": response?.mimeType ?? "",
                "headers": headerMap,
                "data": (data ?? Data()).base64EncodedString()
            ])
        }.resume()
    }
}

/* ---------------- 沉浸式全屏 / 退出 ----------------
   iOS 没有安卓的系统栏概念，这里通过自定义 ViewController 隐藏状态栏
   和底部 Home 指示条，播放时让画面铺满整块屏幕。 */

@objc(GyImmersivePlugin)
public class GyImmersivePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GyImmersivePlugin"
    public let jsName = "Immersive"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestFullscreenWindow", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exitApp", returnType: CAPPluginReturnPromise)
    ]

    static var immersive = false

    @objc func setEnabled(_ call: CAPPluginCall) {
        GyImmersivePlugin.immersive = call.getBool("enabled") ?? false
        DispatchQueue.main.async {
            self.bridge?.viewController?.setNeedsStatusBarAppearanceUpdate()
            self.bridge?.viewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            call.resolve()
        }
    }

    @objc func requestFullscreenWindow(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func exitApp(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            exit(0)
        }
        call.resolve()
    }
}

/* ---------------- DLNA 投屏 ----------------
   SSDP 组播搜索 MediaRenderer 设备，再用 SOAP 调 AVTransport 把播放地址推给电视。
   iOS 14 起收发组播需要系统授权（首次会弹出「查找并连接本地网络设备」）。 */

@objc(GyDlnaPlugin)
public class GyDlnaPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GyDlnaPlugin"
    public let jsName = "GyDlna"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "discover", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cast", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolume", returnType: CAPPluginReturnPromise)
    ]

    private let ssdpHost = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900
    private let avt = "urn:schemas-upnp-org:service:AVTransport:1"
    private let rcs = "urn:schemas-upnp-org:service:RenderingControl:1"

    private var controlUrl = ""
    private var volumeUrl = ""
    private var deviceName = ""

    @objc func discover(_ call: CAPPluginCall) {
        let timeout = min(6000, max(1200, call.getInt("timeout") ?? 2600))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.ssdpLocations(timeoutMs: timeout)
            var devices: [[String: Any]] = []
            var seen = Set<String>()
            for location in result.locations.prefix(12) {
                guard let info = self.deviceInfo(location: location) else { continue }
                if seen.contains(info.control) { continue }
                seen.insert(info.control)
                devices.append([
                    "id": info.control,
                    "name": info.name,
                    "location": location,
                    "controlUrl": info.control,
                    "volumeUrl": info.volume
                ])
            }
            var hint = ""
            if devices.isEmpty {
                if self.localSubnetPrefix() == nil {
                    hint = "no-wifi"
                } else if result.multicastFailed {
                    hint = "ios-local-network"
                }
            }
            call.resolve(["devices": devices, "hint": hint])
        }
    }

    @objc func cast(_ call: CAPPluginCall) {
        let url = call.getString("url") ?? ""
        let title = call.getString("title") ?? ""
        let type = call.getString("type") ?? "video"
        let seconds = call.getDouble("seconds") ?? 0
        let tuneVolume = call.getBool("tuneVolume") ?? false
        let device = call.getObject("device") ?? [:]
        guard url.hasPrefix("http") else {
            call.reject("播放地址不可投屏")
            return
        }
        let control = (device["controlUrl"] as? String) ?? ""
        guard !control.isEmpty else {
            call.reject("设备不支持投屏控制")
            return
        }
        let volume = (device["volumeUrl"] as? String) ?? ""
        let name = (device["name"] as? String) ?? ""
        controlUrl = control
        volumeUrl = volume
        deviceName = name
        DispatchQueue.global(qos: .userInitiated).async {
            let audio = type == "music"
            let mime = audio ? self.audioMime(url) : self.videoMime(url)
            let metadata = self.metadata(url: url, title: title, audio: audio, mime: mime)
            let body = "<InstanceID>0</InstanceID>"
                + "<CurrentURI>\(self.escape(url))</CurrentURI>"
                + "<CurrentURIMetaData>\(self.escape(metadata))</CurrentURIMetaData>"
            guard self.soap(control, service: self.avt, action: "SetAVTransportURI", body: body) else {
                call.reject("电视拒绝了该播放地址")
                return
            }
            _ = self.soap(control, service: self.avt, action: "Play",
                          body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
            if seconds > 3 {
                _ = self.soap(control, service: self.avt, action: "Seek", body: self.seekBody(seconds))
            }
            if tuneVolume && !volume.isEmpty {
                _ = self.soap(volume, service: self.rcs, action: "SetVolume",
                              body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>60</DesiredVolume>")
            }
            call.resolve(["ok": true, "device": name])
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        transport(call, action: "Pause", body: "<InstanceID>0</InstanceID>")
    }

    @objc func resume(_ call: CAPPluginCall) {
        transport(call, action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    @objc func stop(_ call: CAPPluginCall) {
        transport(call, action: "Stop", body: "<InstanceID>0</InstanceID>")
    }

    @objc func seek(_ call: CAPPluginCall) {
        let seconds = call.getDouble("seconds") ?? 0
        transport(call, action: "Seek", body: seekBody(seconds))
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        let level = min(100, max(0, call.getInt("volume") ?? 50))
        let url = volumeUrl
        guard !url.isEmpty else {
            call.reject("设备不支持音量控制")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.soap(url, service: self.rcs, action: "SetVolume",
                               body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(level)</DesiredVolume>")
            call.resolve(["ok": ok])
        }
    }

    /* ---------------- 控制 ---------------- */

    private func transport(_ call: CAPPluginCall, action: String, body: String) {
        let url = controlUrl
        guard !url.isEmpty else {
            call.reject("还没有连接投屏设备")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.soap(url, service: self.avt, action: action, body: body)
            call.resolve(["ok": ok])
        }
    }

    private func seekBody(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let target = String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        return "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target>"
    }

    private func videoMime(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".m3u8") { return "application/vnd.apple.mpegurl" }
        if lower.contains(".webm") { return "video/webm" }
        if lower.contains(".mkv") { return "video/x-matroska" }
        return "video/mp4"
    }

    private func audioMime(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".flac") { return "audio/flac" }
        if lower.contains(".aac") || lower.contains(".m4a") { return "audio/mp4" }
        return "audio/mpeg"
    }

    private func metadata(url: String, title: String, audio: Bool, mime: String) -> String {
        let cls = audio ? "object.item.audioItem.musicTrack" : "object.item.videoItem"
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
            + "<dc:title>\(escape(name.isEmpty ? "娟光阅影" : name))</dc:title>"
            + "<upnp:class>\(cls)</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mime):*\">\(escape(url))</res>"
            + "</item></DIDL-Lite>"
    }

    private func soap(_ url: String, service: String, action: String, body: String) -> Bool {
        guard let target = URL(string: url) else { return false }
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
            + " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service)\">\(body)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.httpBody = Data(envelope.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        URLSession.shared.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse {
                success = http.statusCode >= 200 && http.statusCode < 300
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 8)
        return success
    }

    /* ---------------- SSDP ---------------- */

    /* iOS 对组播收发有系统限制：没有组播权限时 sendto 会直接失败，
       所以组播搜不到设备时，再逐个向局域网内 IP 发单播 M-SEARCH 兜底。 */

    private func ssdpLocations(timeoutMs: Int) -> (locations: [String], multicastFailed: Bool) {
        let multicast = multicastSearch(timeoutMs: timeoutMs)
        var locations = multicast.locations
        if locations.isEmpty, let prefix = localSubnetPrefix() {
            locations.append(contentsOf: unicastSearch(prefix: prefix, timeoutMs: max(1600, timeoutMs)))
        }
        return (locations, multicast.failed)
    }

    private func localSubnetPrefix() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var fallback: String?
        var cursor = addrs
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr -> String in
                var value = ptr.pointee.sin_addr
                return String(cString: inet_ntoa(value))
            }
            guard !ip.isEmpty, !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else { continue }
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
            if String(cString: current.pointee.ifa_name) == "en0" { return prefix }
            if fallback == nil { fallback = prefix }
        }
        return fallback
    }

    private func unicastSearch(prefix: String, timeoutMs: Int) -> [String] {
        var locations: [String] = []
        var seen = Set<String>()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return locations }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(0).bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return locations }

        let payload = Array(searchMessage.utf8)
        for round in 0..<2 {
            for host in 1...254 {
                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = ssdpPort.bigEndian
                target.sin_addr.s_addr = inet_addr("\(prefix).\(host)")
                _ = payload.withUnsafeBytes { raw in
                    withUnsafePointer(to: &target) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            if round == 0 { Thread.sleep(forTimeInterval: 0.25) }
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr()
            var fromLength = socklen_t(MemoryLayout<sockaddr>.size)
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLength)
                    }
                }
            }
            if received <= 0 { continue }
            let text = String(decoding: buffer[0..<received], as: UTF8.self)
            if let location = headerValue(text, "location"), !seen.contains(location) {
                seen.insert(location)
                locations.append(location)
            }
        }
        return locations
    }

    private var searchMessage: String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(ssdpHost):\(ssdpPort)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\n"
            + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
    }

    private func multicastSearch(timeoutMs: Int) -> (locations: [String], failed: Bool) {
        var locations: [String] = []
        var seen = Set<String>()
        var failed = false
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return (locations, true) }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(0).bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return (locations, false) }

        let payload = Array(searchMessage.utf8)
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = ssdpPort.bigEndian
        target.sin_addr.s_addr = inet_addr(ssdpHost)

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var nextSend = Date()
        var sent = 0
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            if Date() >= nextSend && sent < 3 {
                let wrote = payload.withUnsafeBytes { raw -> Int in
                    withUnsafePointer(to: &target) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                sent += 1
                nextSend = Date().addingTimeInterval(0.4)
                // 组播被系统拦截，不必再等，直接交给单播兜底
                if wrote < 0 {
                    failed = true
                    break
                }
            }
            var from = sockaddr()
            var fromLength = socklen_t(MemoryLayout<sockaddr>.size)
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLength)
                    }
                }
            }
            if received <= 0 { continue }
            let text = String(decoding: buffer[0..<received], as: UTF8.self)
            if let location = headerValue(text, "location"), !seen.contains(location) {
                seen.insert(location)
                locations.append(location)
            }
        }
        return (locations, failed)
    }

    private func headerValue(_ text: String, _ name: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func deviceInfo(location: String) -> (name: String, control: String, volume: String)? {
        guard let url = URL(string: location), let xml = fetchText(url) else { return nil }
        let name = decodeEntities(firstMatch("<friendlyName[^>]*>(.*?)</friendlyName>", in: xml) ?? "")
        if name.isEmpty { return nil }
        var control = ""
        var volume = ""
        guard let blockRegex = try? NSRegularExpression(pattern: "<service>(.*?)</service>",
                                                        options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in blockRegex.matches(in: xml, options: [], range: range) {
            guard let blockRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[blockRange])
            guard let type = firstMatch("<serviceType[^>]*>(.*?)</serviceType>", in: block),
                  let raw = firstMatch("<controlURL[^>]*>(.*?)</controlURL>", in: block) else { continue }
            let absolute = resolve(base: location, relative: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if type.contains(":AVTransport:") {
                control = absolute
            } else if type.contains(":RenderingControl:") {
                volume = absolute
            }
        }
        guard !control.isEmpty else { return nil }
        return (name, control, volume)
    }

    private func fetchText(_ url: URL) -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        URLSession.shared.dataTask(with: request) { body, _, _ in
            data = body
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        guard let body = data else { return nil }
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolve(base: String, relative: String) -> String {
        if relative.hasPrefix("http://") || relative.hasPrefix("https://") { return relative }
        guard let baseUrl = URL(string: base), let resolved = URL(string: relative, relativeTo: baseUrl) else {
            return relative
        }
        return resolved.absoluteString
    }

    private func escape(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func decodeEntities(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
