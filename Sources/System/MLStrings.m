#import "MLStrings.h"

NSNotificationName const MLLanguageDidChangeNotification = @"MLLanguageDidChangeNotification";

@implementation MLStrings

static MLLanguage sLanguage = MLLanguageEnglish;
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *sTable;

+ (void)initialize {
    if (self != [MLStrings class]) {
        return;
    }
    sLanguage = [self systemPreferredLanguage];
    sTable = @{
        @"menu.show_overlay" : @{
            @"en" : @"Show Overlay",
            @"zh" : @"显示启动器",
        },
        @"menu.retry_hot_corner" : @{
            @"en" : @"Retry Hot Corner Permission",
            @"zh" : @"重试触发角权限",
        },
        @"menu.preferences" : @{
            @"en" : @"Preferences…",
            @"zh" : @"设置…",
        },
        @"menu.quit" : @{
            @"en" : @"Quit MeoLaunch",
            @"zh" : @"退出 MeoLaunch",
        },
        @"menu.tooltip" : @{
            @"en" : @"MeoLaunch (⌥Space)",
            @"zh" : @"MeoLaunch（⌥Space）",
        },
        @"taskbar.pin" : @{
            @"en" : @"Pin",
            @"zh" : @"钉住",
        },
        @"taskbar.unpin" : @{
            @"en" : @"Unpin",
            @"zh" : @"取消钉住",
        },
        @"prefs.title" : @{
            @"en" : @"MeoLaunch Preferences",
            @"zh" : @"MeoLaunch 设置",
        },
        @"prefs.language" : @{
            @"en" : @"Language",
            @"zh" : @"语言",
        },
        @"prefs.lang.en" : @{
            @"en" : @"English",
            @"zh" : @"English",
        },
        @"prefs.lang.zh" : @{
            @"en" : @"中文",
            @"zh" : @"中文",
        },
        @"prefs.grid_cols" : @{
            @"en" : @"Grid columns",
            @"zh" : @"网格列数",
        },
        @"prefs.grid_rows" : @{
            @"en" : @"Grid rows",
            @"zh" : @"网格行数",
        },
        @"prefs.icon_size" : @{
            @"en" : @"Icon size",
            @"zh" : @"图标大小",
        },
        @"prefs.icon_auto" : @{
            @"en" : @"Auto",
            @"zh" : @"自动",
        },
        @"prefs.overlay_opacity" : @{
            @"en" : @"Overlay opacity",
            @"zh" : @"遮罩透明度",
        },
        @"prefs.launch_at_login" : @{
            @"en" : @"Launch at login",
            @"zh" : @"开机启动",
        },
        @"prefs.launch_at_login_failed" : @{
            @"en" : @"Couldn’t Change Login Item",
            @"zh" : @"无法更改开机启动",
        },
        @"prefs.launch_at_login_failed_info" : @{
            @"en" : @"Open System Settings → General → Login Items and allow MeoLaunch, or move the app to /Applications and try again.",
            @"zh" : @"请在「系统设置 → 通用 → 登录项」中允许 MeoLaunch，或将应用移到「应用程序」文件夹后再试。",
        },
        @"prefs.hot_corner_enabled" : @{
            @"en" : @"Hot corner enabled",
            @"zh" : @"启用触发角",
        },
        @"prefs.hot_corner" : @{
            @"en" : @"Hot corner",
            @"zh" : @"触发角位置",
        },
        @"prefs.corner.top_left" : @{
            @"en" : @"Top Left",
            @"zh" : @"左上角",
        },
        @"prefs.corner.top_right" : @{
            @"en" : @"Top Right",
            @"zh" : @"右上角",
        },
        @"prefs.corner.bottom_left" : @{
            @"en" : @"Bottom Left",
            @"zh" : @"左下角",
        },
        @"prefs.corner.bottom_right" : @{
            @"en" : @"Bottom Right",
            @"zh" : @"右下角",
        },
        @"prefs.corner.off" : @{
            @"en" : @"Off",
            @"zh" : @"关闭",
        },
        @"prefs.hot_size" : @{
            @"en" : @"Hot size (pt)",
            @"zh" : @"热区大小 (pt)",
        },
        @"prefs.scan_title" : @{
            @"en" : @"App Folders",
            @"zh" : @"应用目录",
        },
        @"prefs.scan_hint" : @{
            @"en" : @"Add folders with .app on external disks; scans that folder and one level of subfolders.",
            @"zh" : @"外接硬盘上的 .app 可加在这里；仅扫描该文件夹及一层子文件夹。",
        },
        @"prefs.system_dirs" : @{
            @"en" : @"System folders (read-only)",
            @"zh" : @"系统目录（只读）",
        },
        @"prefs.extra_dirs" : @{
            @"en" : @"Extra folders",
            @"zh" : @"额外目录",
        },
        @"prefs.add_folder" : @{
            @"en" : @"Add Folder…",
            @"zh" : @"添加文件夹…",
        },
        @"prefs.remove" : @{
            @"en" : @"Remove",
            @"zh" : @"移除",
        },
        @"prefs.rescan" : @{
            @"en" : @"Rescan",
            @"zh" : @"重新扫描",
        },
        @"prefs.config_path" : @{
            @"en" : @"Config: %@",
            @"zh" : @"配置：%@",
        },
        @"prefs.unmounted" : @{
            @"en" : @"%@ (unmounted)",
            @"zh" : @"%@（未挂载）",
        },
        @"prefs.add_prompt" : @{
            @"en" : @"Add",
            @"zh" : @"添加",
        },
        @"prefs.add_message" : @{
            @"en" : @"Choose a folder that contains .app items (for example Apps on an external disk).",
            @"zh" : @"选择包含 .app 的文件夹（例如外接硬盘上的 Apps）",
        },
        @"prefs.add_failed_title" : @{
            @"en" : @"Couldn’t Add Folder",
            @"zh" : @"未能添加目录",
        },
        @"prefs.add_failed_info" : @{
            @"en" : @"The path is invalid, or it’s already in the list.",
            @"zh" : @"路径无效，或已在列表中。",
        },
        @"prefs.ok" : @{
            @"en" : @"OK",
            @"zh" : @"好",
        },
        @"a11y.title" : @{
            @"en" : @"Accessibility Permission Required",
            @"zh" : @"需要「辅助功能」权限",
        },
        @"a11y.body" : @{
            @"en" : @"MeoLaunch uses a hot corner to show your apps. Allow MeoLaunch in System Settings → Privacy & Security → Accessibility.\n\nWithout permission you can still open it from the menu bar or ⌥Space.",
            @"zh" : @"MeoLaunch 用触发角唤起应用列表。请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 MeoLaunch。\n\n未授权时仍可通过菜单栏或 ⌥Space 打开。",
        },
        @"a11y.open_settings" : @{
            @"en" : @"Open System Settings",
            @"zh" : @"打开系统设置",
        },
        @"a11y.later" : @{
            @"en" : @"Later",
            @"zh" : @"稍后",
        },
    };
}

+ (MLLanguage)systemPreferredLanguage {
    for (NSString *lang in [NSLocale preferredLanguages]) {
        if ([lang hasPrefix:@"zh"]) {
            return MLLanguageChinese;
        }
        if ([lang hasPrefix:@"en"]) {
            return MLLanguageEnglish;
        }
    }
    return MLLanguageEnglish;
}

+ (MLLanguage)languageFromCode:(NSString *)code {
    if ([code isEqualToString:@"zh"] || [code hasPrefix:@"zh-"] || [code hasPrefix:@"zh_"]) {
        return MLLanguageChinese;
    }
    return MLLanguageEnglish;
}

+ (NSString *)codeForLanguage:(MLLanguage)language {
    return language == MLLanguageChinese ? @"zh" : @"en";
}

+ (MLLanguage)language {
    return sLanguage;
}

+ (void)setLanguage:(MLLanguage)language {
    if (sLanguage == language) {
        return;
    }
    sLanguage = language;
    [[NSNotificationCenter defaultCenter] postNotificationName:MLLanguageDidChangeNotification
                                                        object:nil];
}

+ (NSString *)t:(NSString *)key {
    if (key.length == 0) {
        return @"";
    }
    NSDictionary<NSString *, NSString *> *entry = sTable[key];
    if (!entry) {
        return key;
    }
    NSString *code = [self codeForLanguage:sLanguage];
    NSString *value = entry[code];
    if (value.length) {
        return value;
    }
    value = entry[@"en"];
    return value.length ? value : key;
}

@end
