/** Join a site-root path with Astro `base` (e.g. `/meolaunch/`). */
export function withBase(path = '/'): string {
  const base = import.meta.env.BASE_URL; // always ends with /
  if (!path || path === '/') return base;
  if (path.startsWith('#')) return `${base}${path}`;
  const clean = path.replace(/^\//, '');
  return `${base}${clean}`;
}
