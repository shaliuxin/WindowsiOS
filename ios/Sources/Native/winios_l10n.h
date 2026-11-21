/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_L10N_H
#define WINIOS_L10N_H

#include <stdbool.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
/// 依据当前语言偏好返回中文或英文字符串（供 ObjC 代码使用）。
NSString *WinIOSL(NSString *zh, NSString *en);
#endif

/// 当前是否应使用英文（供纯 C 代码使用）。
/// 读取 NSUserDefaults("winios.appLanguage")；为 system 时按系统首选语言判断。
bool WinIOSUseEnglish(void);

#endif /* WINIOS_L10N_H */
