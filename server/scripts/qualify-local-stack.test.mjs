import test from 'node:test';
import assert from 'node:assert/strict';
import { boundedBytes, localConfiguration, qualifyLocalStack } from './qualify-local-stack.mjs';

const fixture = { API_URL: 'http://127.0.0.1:54321', ANON_KEY: 'fixture-anon', SERVICE_ROLE_KEY: 'fixture-admin' };

test('qualification requires confirmation before accepting local credentials', () => {
  assert.throws(() => localConfiguration(fixture, false), /disposable_confirmation_required/);
  assert.equal(localConfiguration({ env: fixture }, true).origin, fixture.API_URL);
});

test('local qualifier refuses production, hostname, path, and userinfo targets', () => {
  const credentialURL = new URL(fixture.API_URL); credentialURL.username = 'fixture';
  for (const url of ['https://backend.example', 'http://localhost:54321', 'http://127.0.0.1:54321/other', 'http://127.0.0.1:54321/?x=1', credentialURL.href]) {
    assert.throws(() => localConfiguration({ ...fixture, API_URL: url }, true), /numeric_loopback_origin_required/);
  }
});

test('programmatic entry point also refuses an external target before any fetch', async () => {
  let calls = 0;
  await assert.rejects(qualifyLocalStack({ origin: 'https://backend.example', anon: 'fixture', service: 'fixture' }, {
    fetch: async () => { calls++; return Response.json({}); },
  }), /numeric_loopback_origin_required/);
  assert.equal(calls, 0);
});

test('cleanup deletes only fixture accounts whose creation marker still matches', async () => {
  const ids = ['10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002'];
  let marker, count = 0, deleted = [];
  const result = await qualifyLocalStack(localConfiguration(fixture, true), { fetch: async (url, init) => {
    const path = new URL(url).pathname;
    if (path.endsWith('/health')) return Response.json({});
    if (path === '/auth/v1/admin/users' && init.method === 'POST') {
      marker = JSON.parse(init.body).user_metadata.aim_qualification;
      return Response.json({ id: ids[count++] });
    }
    if (path === '/auth/v1/token') return Response.json({ error: 'Injected test failure' }, { status: 503 });
    if (path.startsWith('/auth/v1/admin/users/') && init.method === 'GET') {
      return Response.json({ user_metadata: { aim_qualification: path.endsWith(ids[0]) ? 'changed' : marker } });
    }
    if (init.method === 'DELETE') { deleted.push(path.split('/').at(-1)); return Response.json({}); }
    throw new Error('unexpected');
  } });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'auth_http_503');
  assert.deepEqual(deleted, [ids[1]]);
  assert.equal(result.cleanup, 'incomplete_keep_disposable_instance_for_inspection');
  assert.doesNotMatch(JSON.stringify(result), /fixture-admin|fixture-anon|Injected test failure/);
});

test('unexpected upstream error contents never escape the qualifier receipt', async () => {
  const result = await qualifyLocalStack(localConfiguration(fixture, true), {
    fetch: async () => { throw new Error('Do not print credentials or backend errors'); },
  });
  assert.equal(result.reason, 'transport_or_assertion_failed');
  assert.doesNotMatch(JSON.stringify(result), /credentials|backend errors/);
});

test('foreign underscore-only errors are never treated as controlled diagnostic codes', async () => {
  const result = await qualifyLocalStack(localConfiguration(fixture, true), {
    fetch: async () => { throw new Error('fixture_private_credential'); },
  });
  assert.equal(result.reason, 'transport_or_assertion_failed');
  assert.doesNotMatch(JSON.stringify(result), /fixture_private_credential/);
});

test('uncertain committed account creation cannot be reported as cleaned', async () => {
  let attempted = false;
  const result = await qualifyLocalStack(localConfiguration(fixture, true), { fetch: async (url, init) => {
    if (new URL(url).pathname.endsWith('/health')) return Response.json({});
    assert.equal(init.method, 'POST'); attempted = true;
    throw new Error('Simulated response loss after an admin create');
  } });
  assert.equal(attempted, true);
  assert.equal(result.ok, false);
  assert.equal(result.cleanup, 'incomplete_keep_disposable_instance_for_inspection');
});

test('download comparison cancels oversized binary streams before buffering', async () => {
  let cancelled = false;
  const response = new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(9)); },
    cancel() { cancelled = true; },
  }));
  await assert.rejects(boundedBytes(response, 8), /unexpected_binary_response_size/);
  assert.equal(cancelled, true);
});
