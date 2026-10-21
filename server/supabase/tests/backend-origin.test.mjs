import test from 'node:test';
import assert from 'node:assert/strict';
import { backendOrigin } from '../functions/_shared/backend-origin.ts';
import { createRPC } from '../functions/_shared/push-worker.ts';
const env = values => name => values[name];

test('public backend configuration accepts only bare HTTPS origins', () => {
  assert.equal(backendOrigin(env({ SUPABASE_URL: 'https://backend.example:8443' })).origin, 'https://backend.example:8443');
  for (const value of ['http://backend.example', 'https://backend.example/api', 'https://backend.example/?x=1', 'https://backend.example/#fragment', 'https://backend.example:0']) {
    assert.throws(() => backendOrigin(env({ SUPABASE_URL: value })), /server_not_configured/);
  }
});

test('URL userinfo is rejected even in explicitly internal configuration', () => {
  const value = new URL('https://backend.example'); value.username = 'fixture';
  for (const key of ['SUPABASE_URL', 'AIM_INTERNAL_SUPABASE_ORIGIN']) {
    assert.throws(() => backendOrigin(env({ [key]: value.href, AIM_INTERNAL_SUPABASE_ALLOW_HTTP: 'true' })), /server_not_configured/);
  }
});

test('unencrypted private hop requires both explicit operator settings', () => {
  for (const value of ['http://127.0.0.1:3000', 'http://kong:8000']) {
    assert.throws(() => backendOrigin(env({ SUPABASE_URL: value })), /server_not_configured/);
    assert.throws(() => backendOrigin(env({ AIM_INTERNAL_SUPABASE_ORIGIN: value })), /server_not_configured/);
    assert.equal(backendOrigin(env({ AIM_INTERNAL_SUPABASE_ORIGIN: value, AIM_INTERNAL_SUPABASE_ALLOW_HTTP: 'true' })).origin, value);
  }
});

test('explicit HTTP override still refuses public destinations and URL extras', () => {
  for (const value of ['http://backend.example', 'http://8.8.8.8', 'http://169.254.169.254', 'http://10.0.0.1/path', 'http://kong:8000/?key=fixture']) {
    assert.throws(() => backendOrigin(env({ AIM_INTERNAL_SUPABASE_ORIGIN: value, AIM_INTERNAL_SUPABASE_ALLOW_HTTP: 'true' })), /server_not_configured/);
  }
});

test('private IPv4 ranges and numeric loopback support isolated/self-hosted services', () => {
  for (const value of ['http://10.2.3.4', 'http://172.16.0.2', 'http://172.31.255.2', 'http://192.168.1.2', 'http://[::1]:3000']) {
    assert.equal(backendOrigin(env({ AIM_INTERNAL_SUPABASE_ORIGIN: value, AIM_INTERNAL_SUPABASE_ALLOW_HTTP: 'true' })).origin, value);
  }
});

test('RPC preserves the auth header and forbids redirects with explicit internal transport', async () => {
  let observed;
  const rpc = createRPC({ env: env({ AIM_INTERNAL_SUPABASE_ORIGIN: 'http://kong:8000', AIM_INTERNAL_SUPABASE_ALLOW_HTTP: 'true' }), fetch: async (url, init) => {
    observed = { url: String(url), init }; return Response.json({ ok: true });
  } }, 'fixture', 'Bearer fixture');
  assert.deepEqual(await rpc('aim_maintenance_session'), { ok: true });
  assert.equal(observed.url, 'http://kong:8000/rest/v1/rpc/aim_maintenance_session');
  assert.equal(observed.init.headers.Authorization, 'Bearer fixture');
  assert.equal(observed.init.redirect, 'error');
});

test('oversized RPC response is cancelled before parsing', async () => {
  let cancelled = false;
  const rpc = createRPC({ env: env({ SUPABASE_URL: 'https://backend.example' }), fetch: async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(2 * 1024 * 1024 + 1)); },
    cancel() { cancelled = true; },
  })) }, 'fixture', 'Bearer fixture');
  await assert.rejects(rpc('aim_maintenance_session'), /request_too_large/);
  assert.equal(cancelled, true);
});
