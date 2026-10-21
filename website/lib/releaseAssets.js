/** Prevent reserved release URLs from returning the SPA when no actual asset exists. */
export const isReleasePath = (pathname) => pathname.startsWith('/updates/') || pathname.startsWith('/downloads/');
export const releaseAssetResponse = (pathname, response) => {
 const type = (response.headers.get('Content-Type') || '').split(';')[0].trim().toLowerCase();
 const feed = pathname === '/updates/appcast.xml';
 const dmg = /^\/(updates|downloads)\/[A-Za-z0-9._-]+\.dmg$/.test(pathname);
 const validType = feed ? ['application/xml', 'text/xml', 'application/rss+xml'].includes(type) : dmg && ['application/octet-stream', 'application/x-apple-diskimage', 'application/x-dmg'].includes(type);
 if ((response.status === 200 || response.status === 206) && validType) return response;
 return new Response('Release asset not found.', { status: 404, headers: { 'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff' } });
};
