/** meoLaunch 官网 MVP 终稿文案 — 全站唯一文案源 */

export const site = {
  name: 'meoLaunch',
  tagline: '一个应用 · Launchpad + Taskbar · 极省内存 · 安装包 < 2 MB · 核心免费',
  description:
    '一个应用，两种能力：全屏 Launchpad 网格 + 轻量 Taskbar。真·原生 AppKit，常驻约 15–25 MB，安装包小于 2 MB。核心能力免费，下载即用。',
  url: 'http://www.meofind.top/meolaunch',
  github: 'https://github.com/meetrize/MeoLaunch',
  /** 未配置环境变量时回退到 Releases 页 */
  downloadFallback: 'https://github.com/meetrize/MeoLaunch/releases/latest',
  macos: 'macOS 13+',
  arch: 'Apple Silicon 与 Intel',
};

export const hero = {
  brand: 'meoLaunch',
  title: '一个应用，两种能力。核心免费。',
  support:
    'Launchpad 全屏网格 + 轻量 Taskbar，同进程协作，常驻约 15–25 MB，安装包小于 2 MB。网格、搜索、热角、底栏——秒下秒装，无订阅门槛。',
  ctaPrimary: '免费下载 macOS 版',
  ctaSecondary: '查看 GitHub',
  trustReady: '核心免费 · 安装包 < 2 MB · 已签名与公证 · Apple Silicon 与 Intel · macOS 13+',
  trustSoon: '核心免费 · 安装包 < 2 MB · 即将提供公证安装包 · Apple Silicon 与 Intel · macOS 13+',
};

export const featuresSection = {
  title: '一个 App，两份桌面能力',
  lead: '不必再叠两套常驻工具。网格负责启动，底栏负责切换；极省内存，安装包小于 2 MB，核心能力免费。',
};

export const features = [
  {
    title: 'Launchpad：熟悉的全屏网格',
    body: '系统拿走了 Launchpad。meoLaunch 把它带回桌面——实时搜索、热角唤起、可配置网格。找应用，重新变成一种干净的体感。免费可用。',
  },
  {
    title: 'Taskbar：每屏一条轻量底栏',
    body: '同进程内置 Taskbar：按屏显示窗口、钉住常用、底栏一键切换。启动与切换，装一个就够——同样免费。',
  },
  {
    title: '极省内存 · 安装包 < 2 MB · 核心免费',
    body: '设计目标：未打开网格时常驻约 15–25 MB；热角到首帧约 80–120 ms；Universal 安装包小于 2 MB。C 核心 + AppKit 薄层——秒下秒装，网格 / 搜索 / 热角 / Taskbar 无订阅门槛。',
  },
] as const;

export const proof = {
  headline: '一份进程，压住 Launchpad + Taskbar；内存极省，安装包小于 2 MB，核心免费。',
  idleLabel: '常驻内存（未打开网格）',
  idleValue: '15–25',
  idleUnit: 'MB',
  latencyLabel: '热角 → 首帧',
  latencyValue: '80–120',
  latencyUnit: 'ms',
  packageLabel: '安装包体积（Universal）',
  packageValue: '< 2',
  packageUnit: 'MB',
  mediaCaption: 'Activity Monitor 对比与唤起演示（素材可替换）',
  rows: [
    { aspect: 'Launchpad', before: '系统已移除', after: '全屏网格 + 搜索 / 热角' },
    { aspect: 'Taskbar', before: '另装常驻工具', after: '同 App 每屏一条轻量底栏' },
    { aspect: '技术栈', before: 'Electron / 多进程叠加', after: '原生 AppKit · 单进程' },
    { aspect: '常驻内存', before: '多工具叠加易膨胀', after: '目标约 15–25 MB' },
    { aspect: '安装包', before: '动辄几十～上百 MB', after: '小于 2 MB（Universal）' },
    { aspect: '价格', before: '订阅 / 多工具叠加付费', after: '核心能力免费，下载即用' },
  ],
};

export const install = {
  title: '三步装上，热角即开',
  subtitle: '按官网 3 步装上，即可用热角唤起网格；Taskbar 随应用常驻。',
  steps: [
    {
      n: '01',
      title: '下载并打开',
      body: '下载安装包并打开。若遇 Gatekeeper：右键打开，或在系统设置中允许。',
    },
    {
      n: '02',
      title: '授予辅助功能',
      body: '热角与窗口相关能力需要辅助功能权限；菜单栏与快捷键仍可先用。',
    },
    {
      n: '03',
      title: '移入热角',
      body: '默认左上角移入即唤起网格。Esc 或点击空白关闭。底栏随时切换窗口。',
    },
  ],
};

export const subscribe = {
  title: '跟上版本与路线图',
  body: '新版本、对比素材与下一款轻量工具预告，先发到名单。国内亦可加入社群获取更新。',
  emailPlaceholder: 'you@example.com',
  emailCta: '订阅更新',
  communityHint: '或扫码加入微信交流群（二维码放入 public/media/wechat-qr.png）',
  success: '已记录，感谢关注。',
};

export const footer = {
  privacy: '隐私政策',
  changelog: '更新日志',
  github: 'GitHub',
  rights: '一个应用 · Launchpad + Taskbar · 极省内存 · 安装包 < 2 MB · 核心免费',
};

export const privacy = {
  title: '隐私政策',
  updated: '2026-08-11',
  sections: [
    {
      h: '我们收集什么',
      p: 'meoLaunch 在本地扫描你指定的应用目录以展示图标与名称。应用列表、布局与配置保存在本机，不会上传到我们的服务器。',
    },
    {
      h: '遥测与分析',
      p: '当前版本无应用内遥测。官网若启用 Cloudflare Web Analytics，仅收集匿名访问统计，不使用跟踪 Cookie。',
    },
    {
      h: '权限',
      p: '辅助功能权限仅用于热角与窗口相关能力；拒绝权限时仍可通过菜单栏或快捷键使用网格。',
    },
    {
      h: '联系',
      p: '隐私相关问题请通过 GitHub Issues 联系维护者。',
    },
  ],
};
