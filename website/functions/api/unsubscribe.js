/** Isolated compatibility proxy. No project identifiers or service keys are bundled into the browser. */
const endpoint = (base, name) => {
  try {
    const url = new URL(base);
    if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash || (url.port && url.port !== '443')) return null;
    return `${url.origin}/functions/v1/${name}`;
  } catch { return null; }
};
export async function onRequest({ request, env = {}, fetch: injectedFetch }) {
  const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  const result = (status, body) => new Response(JSON.stringify(body), { status, headers });
  if (request.method !== 'POST') return new Response(null, { status: 405, headers: { ...headers, Allow: 'POST' } });
  if (request.headers.has('Origin') && request.headers.get('Origin') !== new URL(request.url).origin) return result(403, { success: false });
  const monitor = endpoint(env.AIM_EMAIL_SERVICE_URL, 'aim-monitor-unsubscribe');
  const recovery = endpoint(env.AIM_EMAIL_SERVICE_URL, 'handle-email-unsubscribe');
  if (!monitor || !recovery) return result(503, { success: false });
  let token;
  try { token = (await request.json()).token; } catch { return result(400, { success: false }); }
  if (typeof token !== 'string' || !token || token.length > 4096) return result(400, { success: false });
  const send = injectedFetch ?? fetch;
  try {
    const invoke = async (url) => {
      const upstream = await send(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(env.AIM_EMAIL_PUBLIC_API_KEY ? { apikey: env.AIM_EMAIL_PUBLIC_API_KEY, Authorization: `Bearer ${env.AIM_EMAIL_PUBLIC_API_KEY}` } : {}) }, body: JSON.stringify({ token }), redirect: 'error', signal: AbortSignal.timeout(10000) });
      return { status: upstream.status, body: await upstream.json() };
    };
    let response = await invoke(monitor);
    // Preserve the old monitor -> recovery fallback, without importing the legacy app.
    if (response.status === 400) response = await invoke(recovery);
    if (response.body?.reason === 'already_unsubscribed') return result(200, { success: true, reason: 'already_unsubscribed' });
    return response.status >= 200 && response.status < 300 && response.body?.success === true ? result(200, { success: true }) : result(400, { success: false });
  } catch { return result(502, { success: false }); }
}
