import { isReleasePath } from '../lib/releaseAssets.js';
import { releaseBucketResponse } from '../lib/releaseBucket.js';
/** Reserved binary/feed routes never fall back to the SPA or to unapproved static files. */
export async function onRequest(context) {
  const path = new URL(context.request.url).pathname;
  if (!isReleasePath(path)) return context.next();
  if (!['GET', 'HEAD'].includes(context.request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  return await releaseBucketResponse(context.request, context.env) ?? new Response('Release asset not found.', { status: 404, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
}
