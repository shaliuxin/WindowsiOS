/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "winios_l10n.h"

/* 与 Swift 侧 LocalizationManager.defaultsKey 保持一致的唯一数据源。 */
static NSString *const kWinIOSLanguageKey = @"winios.appLanguage";

bool WinIOSUseEnglish(void) {
    NSString *sel = [[NSUserDefaults standardUserDefaults] stringForKey:kWinIOSLanguageKey];
    if ([sel isEqualToString:@"zhHans"]) return false;
    if ([sel isEqualToString:@"en"]) return true;
    /* system: 系统首选语言以 "zh" 开头（zh-Hans / zh-Hant / zh-HK 等）视为中文 */
    NSString *preferred = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    return ![preferred hasPrefix:@"zh"];
}

NSString *WinIOSL(NSString *zh, NSString *en) {
    return WinIOSUseEnglish() ? en : zh;
}
