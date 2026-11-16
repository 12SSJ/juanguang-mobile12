import Foundation
import CryptoKit

/// 授权时段：索引字符与显示名称，与 App 端保持一致
enum LicenseTier: String, CaseIterable, Identifiable {
    case permanent
    case month1
    case month3
    case month7
    case year1
    case year3

    var id: String { rawValue }

    /// 注册码首位：0 永久 1 一个月 2 三个月 3 七个月 4 一年 5 三年
    var index: String {
        switch self {
        case .permanent: return "0"
        case .month1: return "1"
        case .month3: return "2"
        case .month7: return "3"
        case .year1: return "4"
        case .year3: return "5"
        }
    }

    var title: String {
        switch self {
        case .permanent: return "永久授权"
        case .month1: return "1 个月"
        case .month3: return "3 个月"
        case .month7: return "7 个月"
        case .year1: return "1 年"
        case .year3: return "3 年"
        }
    }

    var detail: String {
        switch self {
        case .permanent: return "不限时间"
        case .month1: return "自激活日起 1 个月"
        case .month3: return "自激活日起 3 个月"
        case .month7: return "自激活日起 7 个月"
        case .year1: return "自激活日起 12 个月"
        case .year3: return "自激活日起 36 个月"
        }
    }
}

/// 注册码算法与安卓 / 电脑版完全一致：
/// 注册码 = 时段索引 + SHA-256(机器码|时段索引|密钥) 前 16 位，展示为 X-XXXX-XXXX-XXXX-XXXX
enum Keygen {
    static let secret = "JGY-2026-MOONLIGHT"
    private static let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func normalize(_ value: String) -> String {
        String(value.uppercased().filter { allowed.contains($0) })
    }

    /// 输入机器码与时段，返回格式化注册码；机器码不足 16 位时返回 nil
    static func generate(machine: String, index: String) -> String? {
        let normalized = normalize(machine)
        guard normalized.count >= 16 else { return nil }
        let digest = SHA256.hash(data: Data((normalized + "|" + index + "|" + secret).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16).uppercased()
        return format(index + hex)
    }

    /// 17 位码按 X-4-4-4-4 分组
    static func format(_ raw: String) -> String {
        let chars = Array(raw.uppercased())
        guard chars.count >= 17 else { return raw.uppercased() }
        func part(_ start: Int, _ end: Int) -> String {
            String(chars[start..<end])
        }
        return "\(part(0, 1))-\(part(1, 5))-\(part(5, 9))-\(part(9, 13))-\(part(13, 17))"
    }
}
