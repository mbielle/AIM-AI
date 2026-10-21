/** Only public information routes are part of this website. */
export const routes = new Set(['/', '/guide', '/legal', '/privacy', '/terms', '/cookies', '/unsubscribe']);
export const normalizePath = (pathname) => pathname.replace(/\/index\.html$/, '/').replace(/\/+$/, '') || '/';
export const routeFor = (pathname) => routes.has(normalizePath(pathname)) ? normalizePath(pathname) : null;
