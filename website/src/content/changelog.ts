/** Changelog entries for /changelog */

export type ChangelogEntry = {
  version: string;
  date: string;
  titleZh: string;
  titleEn: string;
  itemsZh: string[];
  itemsEn: string[];
};

export const changelog: ChangelogEntry[] = [
  {
    version: '0.1.0',
    date: '2026-08-01',
    titleZh: '首个对外可安装版本',
    titleEn: 'First installable release',
    itemsZh: [
      '全屏应用网格：扫描、搜索、滚轮翻页',
      '热角唤起与全局快捷键',
      '同进程轻量 Taskbar（每屏底栏）',
      '紧凑设置窗：网格、触发角、应用目录',
    ],
    itemsEn: [
      'Fullscreen app grid: scan, search, scroll paging',
      'Hot corner + global hotkey',
      'In-process lightweight Taskbar (per display)',
      'Compact prefs: grid, hot corner, app roots',
    ],
  },
];
