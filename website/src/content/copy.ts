/** meoLaunch 官网 MVP 终稿文案 — 全站唯一文案源 */

export const site = {
  name: 'meoLaunch',
  tagline: '原生 Launchpad 替代 · 极致轻量',
  description:
    '把 Launchpad 找回来。真·原生 AppKit，常驻内存极低，热角一触网格即开——启动与切换，一 App 两份能力。',
  url: 'http://www.meofind.top/meolaunch',
  github: 'https://github.com/meetrize/MeoLaunch',
  /** 未配置环境变量时回退到 Releases 页 */
  downloadFallback: 'https://github.com/meetrize/MeoLaunch/releases/latest',
  macos: 'macOS 13+',
  arch: 'Apple Silicon 与 Intel',
};

export const hero = {
  brand: 'meoLaunch',
  title: '把 Launchpad 找回来。再让它配得上你的 Mac。',
  support:
    '真·原生 AppKit。常驻内存压到极致。热角一触，网格即开——启动与切换，一 App 两份能力。',
  ctaPrimary: '下载 macOS 版',
  ctaSecondary: '查看 GitHub',
  trustReady: '已签名与公证 · 支持 Apple Silicon 与 Intel · macOS 13+',
  trustSoon: '即将提供公证安装包 · 支持 Apple Silicon 与 Intel · macOS 13+',
};

export const features = [
  {
    title: '熟悉的全屏网格，更干净的节奏',
    body: '系统拿走了 Launchpad。meoLaunch 把它带回桌面——实时搜索、热角唤起、可配置网格。不是怀念旧物，是把「找应用」重新做成一种体感。',
  },
  {
    title: '启动与切换，不必再装第二套常驻',
    body: '全屏应用网格 + 每屏轻量 Taskbar，同进程协作。钉住常用、底栏切换，内存账只记一次。',
  },
  {
    title: 'C 核心 · AppKit 薄层 · 数字说话',
    body: '设计目标：未打开网格时常驻约 15–25 MB；热角到首帧约 80–120 ms。少占资源，不是口号——是架构选择。',
  },
] as const;

export const proof = {
  headline: '别人用一堆工具堆出功能。我们用一份进程，压住两份能力。',
  idleLabel: '常驻内存（未打开网格）',
  idleValue: '15–25',
  idleUnit: 'MB',
  latencyLabel: '热角 → 首帧',
  latencyValue: '80–120',
  latencyUnit: 'ms',
  mediaCaption: 'Activity Monitor 对比与唤起演示（素材可替换）',
  rows: [
    { aspect: '应用网格', before: '系统已移除 Launchpad', after: '恢复全屏网格 + 搜索 / 热角' },
    { aspect: '窗口切换', before: 'Dock / Mission Control', after: '同 App 内置 Taskbar（每屏一条）' },
    { aspect: '技术栈', before: '—', after: '原生 AppKit（非 Electron）' },
    { aspect: '常驻内存', before: '多工具叠加易膨胀', after: '一份进程扛两种功能' },
  ],
};

export const install = {
  title: '三步装上，热角即开',
  subtitle: '陌生人按官网 3 步能装上并用热角唤起。',
  steps: [
    {
      n: '01',
      title: '下载并打开',
      body: '下载安装包并打开。若遇 Gatekeeper：右键打开，或在系统设置中允许。',
    },
    {
      n: '02',
      title: '授予辅助功能',
      body: '热角需要辅助功能权限；菜单栏与快捷键仍可先用，不必等权限就绪。',
    },
    {
      n: '03',
      title: '移入热角',
      body: '默认左上角移入即唤起。Esc 或点击空白关闭网格。',
    },
  ],
};

export const enSummary = {
  title: 'English',
  line: 'Launchpad, restored—and refined. Native. Tiny memory. Instant. Grid + Taskbar in one process.',
  bullets: [
    'Native AppKit — not Electron, not WebView.',
    'Design targets: ~15–25 MB idle; hot-corner to first frame ~80–120 ms.',
    'One process: app grid + per-display taskbar.',
  ],
  cta: 'Download for macOS',
  github: 'Star on GitHub',
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
  rights: '极致轻量 macOS 工具',
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
