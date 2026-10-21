import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

/** Reservation alerts are not invoices or measurements of actual TURN bytes. */
export function alerts(metrics) {
  if (!metrics || metrics.stateHealthy !== true) return ['coordinator_unavailable'];
  const result = [];
  if (metrics.relayEnabled) {
    const used = metrics.relayReservedBytes, cap = metrics.relayMonthlyBytes;
    if (!Number.isSafeInteger(used) || !Number.isSafeInteger(cap) || used < 0 || cap < 0) return ['metrics_invalid'];
    if (used >= cap) result.push('relay_reservations_exhausted');
    else if (used >= cap * .9) result.push('relay_reservations_90_percent');
    else if (used >= cap * .75) result.push('relay_reservations_75_percent');
  }
  return result;
}

export async function monitorOnce(url, token) {
  const response = await fetch(url, { headers: { Authorization: 'Bearer ' + token },
    redirect: 'error', signal: AbortSignal.timeout(5000) });
  if (!response.ok || Number(response.headers.get('content-length') ?? 0) > 16384) throw new Error('metrics_unavailable');
  const data = new Uint8Array(16385); let length = 0;
  for await (const chunk of response.body) {
    if (length + chunk.length > 16384) throw new Error('metrics_too_large');
    data.set(chunk, length); length += chunk.length;
  }
  return alerts(JSON.parse(new TextDecoder().decode(data.subarray(0, length))));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const url = new URL(process.env.AIM_DIRECT_METRICS_URL ?? 'http://127.0.0.1:8789/metrics');
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname))) throw new Error('secure_metrics_url_required');
  const token = process.env.AIM_DIRECT_ADMIN_TOKEN ?? '';
  if (token.length < 32 || url.username || url.password) throw new Error('private_admin_token_required');
  let prior = new Set();
  const poll = async () => {
    let current;
    try { current = new Set(await monitorOnce(url, token)); } catch { current = new Set(['coordinator_unavailable']); }
    for (const code of current) if (!prior.has(code)) process.stderr.write(JSON.stringify({ time: new Date().toISOString(), level: 'alert', code }) + '\n');
    for (const code of prior) if (!current.has(code)) process.stderr.write(JSON.stringify({ time: new Date().toISOString(), level: 'resolved', code }) + '\n');
    prior = current;
  };
  await poll(); setInterval(poll, 30000);
}
