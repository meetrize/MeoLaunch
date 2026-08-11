# meoLaunch 官网 MVP

静态站点（Astro）。对齐半年增长计划 M1。

当前部署路径：`http://www.meofind.top/meolaunch/`（`astro.config.mjs` 中 `base: '/meolaunch'`）。

## 开发

```bash
cd website
cp .env.example .env
npm install
npm run dev
```

本地预览带 `/meolaunch/` 前缀：`http://localhost:4321/meolaunch/`。

## 构建与上传

```bash
npm run build
```

将 `dist/` **内的文件**上传到服务器的 `meolaunch/` 目录。产物中 CSS/JS/图片路径均以 `/meolaunch/` 开头。

文案源：[`src/content/copy.ts`](src/content/copy.ts)
