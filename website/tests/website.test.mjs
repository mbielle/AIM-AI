import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { publicLinks, externalHttpsUrl, sourceRepositoryUrl } from '../src/config/publicLinks.js';
import { routes, routeFor } from '../src/routes.js';
import { releaseBucketResponse } from '../lib/releaseBucket.js';
import { releaseAssetResponse } from '../lib/releaseAssets.js';
import { onRequest as middleware } from '../functions/_middleware.js';
import { onRequest as unsubscribe } from '../functions/api/unsubscribe.js';
const sha = 'a'.repeat(64);
const request = (path, options) => new Request(`https://example.test${path}`, options);
const asset = { customMetadata: { sha256: sha }, httpMetadata: { contentType: 'application/x-apple-diskimage' }, etag: 'approved', httpEtag: '"approved"', size: 10 };
const env = (overrides = {}) => ({ AIM_RELEASE_MAC_FILENAME: 'AIM.dmg', AIM_RELEASE_MAC_SHA256: sha, AIM_RELEASE_BUCKET: { head: async () => asset, get: async (_key, options) => ({ ...asset, body: new Uint8Array(options?.range?.length ?? 10) }) }, ...overrides });

test('default public links contain no downloadable artifact, internal invitation or support beneficiary', () => {
  assert.deepEqual(publicLinks(), { macDownload: null, iphone: null, supportUrl: null, sourceUrl: null });
  assert.deepEqual(publicLinks({ supportUrl: '   ' }).supportUrl, null);
});
test('downloads need owner release approval, digest and same-origin allowlisted path', () => {
  assert.equal(publicLinks({ macPath: '/downloads/AIM.dmg', macSha256: sha }).macDownload, null);
  assert.equal(publicLinks({ macPath: '/downloads/AIM.dmg', releaseApproved: 'true' }).macDownload, null);
  const valid = { macPath: '/downloads/AIM.dmg', releaseApproved: 'true', macSha256: sha };
  assert.equal(publicLinks(valid).macDownload, '/downloads/AIM.dmg');
  for (const macPath of ['https://other.test/AIM.dmg', '//other.test/AIM.dmg', '/downloads/../AIM.dmg', '/downloads/AIM.dmg?token=x', '/downloads/AIM.dmg#hash', '/downloads/AIM.zip']) assert.equal(publicLinks({ ...valid, macPath }).macDownload, null);
});
test('optional support is hidden when absent and accepts explicit HTTPS destinations only', () => {
  assert.equal(publicLinks({ supportUrl: 'https://support.example.test/owner' }).supportUrl, 'https://support.example.test/owner');
  for (const value of [undefined, '', 'http://example.test', 'javascript:alert(1)', 'https://user:pass@example.test', 'https://example.test:8443']) assert.equal(externalHttpsUrl(value), null);
});
test('legacy app, billing and account routes are outside the route table', () => {
  for (const path of ['/chat', '/credits', '/admin', '/advertise', '/account', '/auth/callback', '/stripe', '/projects']) assert.equal(routeFor(path), null);
  for (const path of routes) assert.equal(routeFor(path), path);
  assert.equal(routeFor('/privacy/'), '/privacy');
});
test('free copy describes actual provider and Remote infrastructure costs', async () => {
  const content = await readFile(new URL('../src/components/landing/content.ts', import.meta.url), 'utf8');
  assert.match(content, /Free and open source/);
  assert.match(content, /Chat, Code, Agent and Remote have no AIM subscription/);
  assert.match(content, /API usage is billed by your provider/);
  assert.match(content, /Remote is not serverless/);
  assert.doesNotMatch(content, /€17|€20|Activate trial|AIM Premium|14-day Premium/);
});
test('source closure has no old app integrations, payment SDKs or ad trackers', async () => {
  const walk = async dir => (await Promise.all((await readdir(dir, { withFileTypes: true })).map(async entry => entry.isDirectory() ? walk(new URL(`${entry.name}/`, dir)) : [new URL(entry.name, dir)]))).flat();
  const files = await walk(new URL('../src/', import.meta.url));
  const content = (await Promise.all(files.map(file => readFile(file, 'utf8')))).join('\n');
  assert.doesNotMatch(content, /from ['"](?:@supabase|react-router|@tanstack)|oldnativewebapp|fbq\(|connect\.facebook|stripe\.com|testflight\.apple\.com|useAnalytics|integrations\/supabase/);
  const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url)));
  assert.doesNotMatch(JSON.stringify(packageJson.dependencies), /supabase|stripe|lovable|react-query|router/);
});
test('unknown release route and absent binding fail closed without invoking SPA fallback', async () => {
  let called = false;
  const response = await middleware({ request: request('/downloads/AIM.dmg'), env: {}, next: async () => { called = true; return new Response('<html>'); } });
  assert.equal(response.status, 404); assert.equal(called, false);
  assert.equal((await middleware({ request: request('/downloads/file.zip'), env: env(), next: async () => new Response('<html>') })).status, 404);
});
test('reserved release methods are limited to GET and HEAD', async () => {
  const response = await middleware({ request: request('/updates/appcast.xml', { method: 'POST' }), env: env(), next: async () => { throw Error('unexpected'); } });
  assert.equal(response.status, 405); assert.equal(response.headers.get('Allow'), 'GET, HEAD');
});
test('R2 only serves exact approved names with matching digest metadata and content type', async () => {
  assert.equal((await releaseBucketResponse(request('/downloads/AIM.dmg'), env())).status, 200);
  assert.equal((await releaseBucketResponse(request('/downloads/unknown.dmg'), env())).status, 404);
  assert.equal((await releaseBucketResponse(request('/downloads/AIM.dmg'), env({ AIM_RELEASE_MAC_SHA256: 'b'.repeat(64) }))).status, 404);
  assert.equal((await releaseBucketResponse(request('/downloads/AIM.dmg'), env({ AIM_RELEASE_BUCKET: { head: async () => ({ ...asset, httpMetadata: { contentType: 'text/html' } }) } }))).status, 404);
  assert.equal((await releaseBucketResponse(request('/downloads/AIM.dmg'), env({ AIM_RELEASE_MAC_ARCHIVES: '{broken' }))).status, 503);
});
test('retained archive allowlist and collisions fail closed', async () => {
  assert.equal((await releaseBucketResponse(request('/downloads/old.dmg'), env({ AIM_RELEASE_MAC_ARCHIVES: JSON.stringify({ 'old.dmg': sha }) }))).status, 200);
  assert.equal((await releaseBucketResponse(request('/downloads/AIM.dmg'), env({ AIM_RELEASE_MAC_ARCHIVES: JSON.stringify({ 'AIM.dmg': 'b'.repeat(64) }) }))).status, 503);
  assert.equal((await releaseBucketResponse(request('/downloads/AIM.dmg'), env({ AIM_RELEASE_MAC_ARCHIVES: JSON.stringify({ '../escape.dmg': sha }) }))).status, 503);
});
test('HEAD, ranges, invalid ranges and changed object identity retain safe behavior', async () => {
  const head = await releaseBucketResponse(request('/downloads/AIM.dmg', { method: 'HEAD' }), env());
  assert.equal(head.status, 200); assert.equal(await head.text(), ''); assert.equal(head.headers.get('Content-Length'), '10');
  const range = await releaseBucketResponse(request('/downloads/AIM.dmg', { headers: { Range: 'bytes=2-4' } }), env());
  assert.equal(range.status, 206); assert.equal(range.headers.get('Content-Range'), 'bytes 2-4/10'); assert.equal((await range.arrayBuffer()).byteLength, 3);
  const invalid = await releaseBucketResponse(request('/downloads/AIM.dmg', { headers: { Range: 'bytes=30-40' } }), env());
  assert.equal(invalid.status, 416);
  const changed = env({ AIM_RELEASE_BUCKET: { head: async () => asset, get: async () => ({ ...asset, etag: 'changed', body: 'unsafe' }) } });
  assert.equal((await releaseBucketResponse(request('/downloads/AIM.dmg'), changed)).status, 503);
});
test('feed requires its own reviewed hash and XML content type', async () => {
  assert.equal((await releaseBucketResponse(request('/updates/appcast.xml'), env())).status, 404);
  assert.equal((await releaseBucketResponse(request('/updates/appcast.xml'), env({ AIM_RELEASE_FEED_SHA256: sha }))).status, 404);
  const feed = { ...asset, httpMetadata: { contentType: 'application/xml' } };
  assert.equal((await releaseBucketResponse(request('/updates/appcast.xml'), env({ AIM_RELEASE_FEED_SHA256: sha, AIM_RELEASE_BUCKET: { head: async () => feed, get: async () => ({ ...feed, body: '<rss />' }) } }))).status, 200);
  assert.equal(releaseAssetResponse('/updates/appcast.xml', new Response('<html>', { headers: { 'Content-Type': 'text/html' } })).status, 404);
});
test('unsubscribe has no side effects from GET, malformed tokens or missing configuration', async () => {
  let calls = 0; const send = async () => { calls++; throw Error('unexpected'); };
  assert.equal((await unsubscribe({ request: request('/api/unsubscribe'), fetch: send })).status, 405);
  assert.equal((await unsubscribe({ request: request('/api/unsubscribe', { method: 'POST', body: '{}' }), fetch: send })).status, 503);
  assert.equal((await unsubscribe({ request: request('/api/unsubscribe', { method: 'POST', body: '{}' }), env: { AIM_EMAIL_SERVICE_URL: 'https://email.example.test' }, fetch: send })).status, 400);
  assert.equal(calls, 0);
});
test('unsubscribe preserves monitor and recovery flows using stubbed calls only', async () => {
  const calls = [];
  const response = await unsubscribe({ request: request('/api/unsubscribe', { method: 'POST', body: JSON.stringify({ token: 'sample-token' }) }), env: { AIM_EMAIL_SERVICE_URL: 'https://email.example.test' }, fetch: async (url, options) => {
    calls.push(url); assert.deepEqual(JSON.parse(options.body), { token: 'sample-token' });
    return calls.length === 1 ? new Response('{}', { status: 400 }) : new Response(JSON.stringify({ success: true }));
  } });
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), { success: true });
  assert.deepEqual(calls, ['https://email.example.test/functions/v1/aim-monitor-unsubscribe', 'https://email.example.test/functions/v1/handle-email-unsubscribe']);
});
test('unsubscribe rejects cross-origin requests and does not report upstream failure as success', async () => {
  const config = { AIM_EMAIL_SERVICE_URL: 'https://email.example.test' };
  assert.equal((await unsubscribe({ request: request('/api/unsubscribe', { method: 'POST', headers: { Origin: 'https://other.test' } }), env: config })).status, 403);
  const response = await unsubscribe({ request: request('/api/unsubscribe', { method: 'POST', body: JSON.stringify({ token: 'sample' }) }), env: config, fetch: async () => new Response('{"success":false}', { status: 500 }) });
  assert.equal(response.status, 400); assert.deepEqual(await response.json(), { success: false });
});

test('source repository stays hidden until a real public HTTPS destination is configured', () => {
  assert.equal(sourceRepositoryUrl('https://github.com/fixture-owner/fixture-repository'), 'https://github.com/fixture-owner/fixture-repository');
  assert.equal(publicLinks({sourceUrl:'https://gitlab.com/fixture-owner/fixture-repository'}).sourceUrl, 'https://gitlab.com/fixture-owner/fixture-repository');
  const credentialUrl = new URL('https://github.com/fixture-owner/fixture-repository');
  credentialUrl.username = 'fixture-user';
  for (const value of [undefined, '', 'http://github.com/fixture-owner/fixture-repository', credentialUrl.href,
    'https://localhost/aim', 'https://localhost.localdomain/aim', 'https://github.com/fixture-owner', 'https://github.com/%6fwner/your-repo', 'https://127.0.0.1/repo', 'https://[::1]/repo', 'https://127.1/repo',
    'https://10.0.0.1/repo', 'https://example.com/aim', 'https://source.example.invalid/aim',
    'https://github.com/owner/your-repo', 'https://github.com', 'https://github.com/fixture-owner/fixture-repository?token=fixture',
    'https://github.com/fixture-owner/fixture-repository#readme']) assert.equal(sourceRepositoryUrl(value), null);
});
