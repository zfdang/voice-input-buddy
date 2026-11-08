import Foundation

/// 目录条目：一款被验证过的小米遥控器。
///
/// App 内置每款遥控器的真机图与按键页，所以「支持 ATVV 桥」不等于「支持这款遥控器」：
/// 只有目录里有条目的型号才允许被采用，未收录的一律不采用。
struct XiaomiRemoteCatalogEntry {
    /// 型号。
    let model: RemoteModel
    /// 真机图资源名（不含扩展名）。每款都必须显式给图；共用必须显式声明，不允许默认套用别款。
    let photoResource: String
    /// 该型号的 DIS Model Number（0x180A / 0x2A24），大写、去首尾空白后匹配。
    let disModelNumbers: [String]
}

/// 已验证小米遥控器目录。
///
/// 准入、型号识别、真机图都必须从这里取，不允许各自另写一份名单——
/// 写成三份就会出现「某处漏收/误收，且只在特定配对状态下复现」的缺陷。
enum XiaomiRemoteCatalog {
    static let entries: [XiaomiRemoteCatalogEntry] = [
        // rc001 与 rc003 外观几乎一致，用户确认共用同一份真机素材（2026-09-19）——
        // 共用是显式声明，不是默认行为。
        XiaomiRemoteCatalogEntry(
            model: .rc001,
            photoResource: "BuddyRemoteIllustration",
            // 真机证实（2026-09-19）：小米蓝牙遥控器 2 的 DIS 报 RC001。
            disModelNumbers: ["RC001"]
        ),
        XiaomiRemoteCatalogEntry(
            model: .rc003,
            photoResource: "BuddyRemoteIllustration",
            // 真机证实（2026-09-19）：小米蓝牙遥控器 2 Pro 的 DIS 报 RC003。
            //
            // ARN9 **不**列入型号目录：两台真机（2 与 2 Pro）的 DIS 都不是 ARN9，
            // 全部历史日志里也从未出现过，没有任何证据表明它属于哪一款——型号不猜。
            // 但 ARN9 的两处功能保留：①广播名白名单里的 "arn9"（连接层，老固件设备
            // 可能广播这个名字）；②桥里 contains("ARN9") 的 ADPCM low-nibble-first
            // 翻转（解码层，见 ATVVProtocol.lowNibbleFirst）——两者都不依赖型号归属。
            disModelNumbers: ["RC003"]
        ),
    ]

    /// 本桥会考虑的广播名（设备自报，小写）。**只作连接前的辅助筛选**：
    /// 广播名与型号不是一一对应（真机实测：广播名「小米蓝牙语音遥控器」、DIS 报 RC003），
    /// 型号判定一律以 DIS 为准。
    ///
    /// 「小米蓝牙遥控器2」「小米蓝牙遥控器2 pro」「arn9」对应的就是**小米蓝牙遥控器 2 / 2 Pro**
    /// （硬件型号 ARN9）——这是老版本用户的主力设备，**绝不能从这份名单里移除**，
    /// 否则老用户升级后遥控器永远无法首次采纳。
    static let adoptedAdvertisedNames: Set<String> = [
        "mi rc",
        "xiaomi bluetooth remote 2",
        "xiaomi bluetooth remote 2 pro",
        "小米蓝牙语音遥控器",
        "小米蓝牙遥控器2",
        "小米蓝牙遥控器2 pro",
        "arn9",
    ]

    /// 按 DIS 型号串识别型号。`raw` 是设备上报的原始串，子串命中即认——
    /// 只有目录里登记的型号串才会命中，登记之外的（如 ARN9）返回 nil，型号不猜。
    static func entry(matchingDISModelNumber raw: String) -> XiaomiRemoteCatalogEntry? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        return entries.first { entry in
            entry.disModelNumbers.contains { normalized.contains($0) }
        }
    }

    /// 该型号应该用的真机图资源名；目录里没有这个型号（包括 `.unknown`）返回 nil，
    /// 调用方必须显示「未识别」占位，不允许套用任何真机图。
    static func photoResource(for model: RemoteModel) -> String? {
        if model.isChromecastRemote { return RemoteSetupDevice.chromecastG9N9N.illustrationResource }
        return entries.first(where: { $0.model == model })?.photoResource
    }
}
