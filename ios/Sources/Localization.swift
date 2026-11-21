// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SwiftUI

/// 界面语言偏好：system 跟随 iOS 系统语言，zhHans / en 为手动指定。
/// 偏好写入 NSUserDefaults("winios.appLanguage")，ObjC / C 层读取同一个 key，
/// 保证 Swift UI 与底层 JIT / VM 状态文本始终使用同一种语言。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case en

    var id: String { rawValue }

    /// 选项本身用双语标注，任何界面语言下都能看懂。
    var label: String {
        switch self {
        case .system: return "跟随系统 / Auto"
        case .zhHans: return "简体中文 / Chinese"
        case .en:     return "English / 英文"
        }
    }

    /// 工具栏 / 启动遮罩上的短标签。
    var shortLabel: String {
        switch self {
        case .system: return L("自动", "Auto")
        case .zhHans: return "中文"
        case .en:     return "EN"
        }
    }
}

/// 全局语言管理器。语言偏好变更会立即刷新桥接层缓存的状态文本。
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    static let defaultsKey = "winios.appLanguage"

    @Published var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.defaultsKey)
            WinIOSBridge.shared.refreshLocalizedStatus()
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        self.selection = AppLanguage(rawValue: raw ?? "") ?? .system
    }

    /// 实际生效语言：跟随系统时，首选语言以 "zh" 开头视为中文，其余视为英文。
    var effective: AppLanguage {
        guard selection == .system else { return selection }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zhHans : .en
    }

    var isEnglish: Bool { effective == .en }

    func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
}

/// 全局便捷函数。View 通过 @EnvironmentObject 的 loc.selection 建立重绘依赖，
/// helper / 子视图中的 L() 会随 body 重新求值而刷新。
func L(_ zh: String, _ en: String) -> String {
    LocalizationManager.shared.t(zh, en)
}
