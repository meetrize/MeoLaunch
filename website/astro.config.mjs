import { defineConfig } from 'astro/config';

// 部署在 http://www.meofind.top/meolaunch/
export default defineConfig({
  site: 'http://www.meofind.top',
  base: '/meolaunch',
  trailingSlash: 'always',
  build: {
    format: 'directory',
  },
});
