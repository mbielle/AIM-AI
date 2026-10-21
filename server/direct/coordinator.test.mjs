import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, randomUUID, sign, createHmac } from 'node:crypto';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { configuration, approvedRelayQuote, startCoordinator } from './coordinator.mjs';

const id = () => randomUUID().toUpperCase();
const encoded = v => Buffer.from(JSON.stringify(v)).toString('base64');
function who(role) {
  const keys = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwk = keys.publicKey.export({ format: 'jwk' });
  const publicKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64');
  return { identity: { version: 1, id: id(), localProfileID: id(), role, name: 'Synthetic ' + role,
    signingKey: publicKey, agreementKey: publicKey }, sign: b => sign('sha256', b, keys.privateKey).toString('base64') };
}
const approved = () => ({ currency: 'EUR', monthlyTotalEUR: 10, billableOverage: false, automaticTopUps: false,
  reviewedBy: 'Synthetic reviewer', validUntil: new Date(Date.now() + 86400000).toISOString() });
async function fixture(t, overrides = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'aim-direct-server-test-'));
  const config = { ...configuration({}), port: 0, statePath: join(dir, 'state.json'), ...overrides };
  const server = startCoordinator(config); if (!server.http.listening) await once(server.http, 'listening');
  t.after(async () => { await server.close(); rmSync(dir, { force: true, recursive: true }); });
  return { ...server, config, dir, base: 'http://127.0.0.1:' + server.address().port,
    ws: 'ws://127.0.0.1:' + server.address().port + '/v1/direct' };
}
async function connection(url) {
  const ws = new WebSocket(url), inbox = [], waiting = []; ws.on('error', () => {});
  ws.on('message', data => {
    const message = JSON.parse(data.toString());
    const index = waiting.findIndex(w => w.type === message.type);
    if (index < 0) inbox.push(message); else { const [w] = waiting.splice(index, 1); clearTimeout(w.timer); w.resolve(message); }
  });
  await once(ws, 'open');
  return { ws, send: value => ws.send(JSON.stringify(value)),
    next: type => {
      const index = inbox.findIndex(m => m.type === type);
      if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
      return new Promise((resolve, reject) => {
        const item = { type, resolve }; item.timer = setTimeout(() => {
          waiting.splice(waiting.indexOf(item), 1); reject(new Error('Timed out waiting for ' + type));
        }, 3000); waiting.push(item);
      });
    } };
}
async function authenticate(peer, role, room, keys) {
  peer.send({ type: role === 'mac' ? 'host' : 'join', room, identity: keys.identity });
  const challenge = await peer.next('challenge');
  peer.send({ type: 'auth', room, signature: keys.sign(Buffer.from('aim-direct-auth/v1/' + room + '/' + challenge.nonce)) });
  assert.equal((await peer.next('authenticated')).room, room);
}
async function pair(f, beforeConfirm = () => {}, expectedError) {
  const room = id(), hostKeys = who('mac'), phoneKeys = who('phone');
  const host = await connection(f.ws), phone = await connection(f.ws);
  await authenticate(host, 'mac', room, hostKeys);
  const claim = { inviteID: room, client: phoneKeys.identity, proof: randomBytes(32).toString('base64') };
  phone.send({ type: 'claim', room, claim: encoded(claim) });
  assert.deepEqual(JSON.parse(Buffer.from((await host.next('claim')).claim, 'base64')), claim);
  const pair = { version: 1, id: room, host: hostKeys.identity, client: phoneKeys.identity, permissions: ['read'],
    revision: 1, revoked: false, confirmedAt: (Date.now() - 978307200000) / 1000 };
  const pairBytes = Buffer.from(JSON.stringify(pair));
  const confirmation = { pairBytes: pairBytes.toString('base64'), hostSignature: hostKeys.sign(pairBytes) };
  beforeConfirm();
  host.send({ type: 'confirm', room, confirmation: encoded(confirmation) });
  if (expectedError) { assert.equal((await host.next('error')).code, expectedError); return; }
  assert.deepEqual(JSON.parse(Buffer.from((await phone.next('confirm')).confirmation, 'base64')), confirmation);
  await authenticate(phone, 'phone', room, phoneKeys);
  assert.equal((await host.next('peerReady')).room, room); await phone.next('peerReady');
  return { room, host, phone, hostKeys, phoneKeys, pair };
}
function signal(p, ciphertext = 'Opaque encrypted bytes') {
  return { type: 'signal', room: p.room, payload: encoded({ version: 1, pairID: p.room, revision: 1,
    sender: p.hostKeys.identity.id, recipient: p.phoneKeys.identity.id, id: id(), sequence: 1, kind: 'signal', ciphertext }) };
}

test('host confirmation and both key challenges precede opaque signalling; no QR token stored', async t => {
  const f = await fixture(t), p = await pair(f), frame = signal(p);
  p.host.send(frame); const forwarded = await p.phone.next('signal'); assert.equal(forwarded.payload, frame.payload);
  const state = readFileSync(f.config.statePath, 'utf8');
  assert.ok(!state.includes('Opaque encrypted bytes')); assert.ok(!state.includes('proof'));
  assert.equal(statSync(f.config.statePath).mode & 0o777, 0o600);
  assert.equal(f.metrics().forwardedSignals, 1);
});

test('unpaired and wrongly signed peers do not get a transport grant', async t => {
  const f = await fixture(t), room = id(), keys = who('mac'); const peer = await connection(f.ws);
  peer.send({ type: 'host', room, identity: keys.identity }); await peer.next('challenge');
  peer.send({ type: 'auth', room, signature: who('mac').sign(Buffer.from('not the challenge')) });
  assert.equal((await peer.next('error')).code, 'unauthorized');
  const unknown = await connection(f.ws); unknown.send({ type: 'signal', room: id(), payload: encoded({}) });
  assert.equal((await unknown.next('error')).code, 'unknown_room');
  assert.equal(f.metrics().authenticated, 0);
});

test('signal sender/recipient/revision must match the authenticated pair', async t => {
  const f = await fixture(t), p = await pair(f), original = signal(p);
  const packet = JSON.parse(Buffer.from(original.payload, 'base64')); packet.sender = id();
  p.host.send({ ...original, payload: encoded(packet) });
  assert.equal((await p.host.next('error')).code, 'invalid_signal'); assert.equal(f.metrics().forwardedSignals, 0);
  p.host.send(original); await p.phone.next('signal');
});

test('only host revokes; revocation survives restart and closes the phone route', async t => {
  const f = await fixture(t), p = await pair(f);
  p.phone.send({ type: 'revoke', room: p.room }); assert.equal((await p.phone.next('error')).code, 'unauthorized');
  p.host.send({ type: 'revoke', room: p.room });
  const saved = () => JSON.parse(readFileSync(f.config.statePath, 'utf8'));
  for (let i = 0; i < 10 && !saved().pairs[p.room].revoked; i++) await new Promise(r => setTimeout(r, 5));
  assert.equal(saved().pairs[p.room].revoked, true);
  await f.close();
  const server = startCoordinator({ ...f.config, port: 0 }); if (!server.http.listening) await once(server.http, 'listening');
  t.after(() => server.close()); const phone = await connection('ws://127.0.0.1:' + server.address().port + '/v1/direct');
  phone.send({ type: 'join', room: p.room, identity: p.phoneKeys.identity }); assert.equal((await phone.next('error')).code, 'revoked');
});

test('TURN credentials are temporary, HMAC authenticated, conservatively quota limited and cached', async t => {
  const secret = 'synthetic-turn-secret-'.repeat(3), ttl = 120, bps = 1024, allocations = 2;
  const f = await fixture(t, { turnURLs: ['turn:relay.example.com:3478', 'turns:relay.example.com:443?transport=tcp'], turnSecret: secret,
    quote: approved(), turnTTL: ttl, turnBps: bps, turnAllocations: allocations, monthlyBytes: 4 * bps * ttl * allocations });
  const p = await pair(f); p.host.send({ type: 'turn', room: p.room }); const ice = await p.host.next('ice');
  assert.equal(ice.servers.length, 2); const first = ice.servers[0];
  assert.equal(first.credential, createHmac('sha1', secret).update(first.username).digest('base64'));
  assert.ok(first.expiresAtUnix * 1000 <= Date.now() + 121000);
  const reserved = f.metrics().relayReservedBytes;
  p.host.send({ type: 'turn', room: p.room }); assert.deepEqual(await p.host.next('ice'), ice); assert.equal(f.metrics().relayReservedBytes, reserved);
  p.phone.send({ type: 'turn', room: p.room }); assert.equal((await p.phone.next('error')).code, 'relay_quota');
  p.host.send(signal(p)); await p.phone.next('signal');
});

test('unreviewed or over-budget hosting never issues relay credentials; direct signalling stays usable', async t => {
  const f = await fixture(t, { turnURLs: ['turn:relay.example.com:3478'], turnSecret: 'synthetic-'.repeat(8) });
  const p = await pair(f); p.host.send({ type: 'turn', room: p.room }); assert.equal((await p.host.next('error')).code, 'relay_unavailable');
  p.host.send(signal(p)); await p.phone.next('signal');
  for (const quote of [null, { ...approved(), monthlyTotalEUR: 21 }, { ...approved(), billableOverage: true },
    { ...approved(), automaticTopUps: true }, { ...approved(), validUntil: '2000-01-01' }]) assert.equal(approvedRelayQuote(quote), false);
  assert.equal(approvedRelayQuote(approved()), true);
});

test('health has no identity data and metrics require the administrative token', async t => {
  const f = await fixture(t, { adminToken: 'synthetic-admin-token-'.repeat(3) });
  const health = await fetch(f.base + '/health'); assert.equal(health.status, 200); assert.deepEqual(await health.json(), { ok: true, version: 1 });
  assert.equal((await fetch(f.base + '/metrics')).status, 404);
  const metrics = await fetch(f.base + '/metrics', { headers: { Authorization: 'Bearer ' + f.config.adminToken } });
  assert.equal(metrics.status, 200); assert.equal((await metrics.json()).relayEnabled, false);
});

test('unknown rooms cannot allocate unbounded room state and claim never grants pairing alone', async t => {
  const f = await fixture(t), peer = await connection(f.ws);
  for (let i = 0; i < 5; i++) {
    peer.send({ type: 'claim', room: id(), claim: encoded({}) }); assert.equal((await peer.next('error')).code, 'unknown_room');
  }
  assert.equal(f.metrics().rooms, 0);
});

test('invalid host frames cannot consume rooms after a valid challenge', async t => {
  const f = await fixture(t, { maxRooms: 2 }), peer = await connection(f.ws);
  peer.send({ type: 'host', room: id(), identity: who('mac').identity }); await peer.next('challenge');
  peer.send({ type: 'host', room: id() }); assert.equal((await peer.next('error')).code, 'already_started');
  assert.equal(f.metrics().rooms, 1);
  const other = await connection(f.ws); other.send({ type: 'host', room: id() });
  assert.equal((await other.next('error')).code, 'invalid_identity'); assert.equal(f.metrics().rooms, 1);
});

test('durable pair capacity refuses confirmation and another process cannot open the same state', async t => {
  const f = await fixture(t, { maxRooms: 2 }); await pair(f);
  assert.throws(() => startCoordinator({ ...f.config, port: 0 }), /EEXIST/);
  await pair(f, () => { f.config.maxRooms = 1; }, 'capacity');
  assert.equal(Object.keys(JSON.parse(readFileSync(f.config.statePath, 'utf8')).pairs).length, 1);
});

test('state persistence failures fail closed and change health to unavailable', async t => {
  const f = await fixture(t); const blocker = join(f.dir, 'ordinary-file'); writeFileSync(blocker, 'fixture');
  const config = { ...f.config, port: 0, statePath: join(f.dir, 'second-state.json') };
  const server = startCoordinator(config); if (!server.http.listening) await once(server.http, 'listening');
  config.statePath = join(blocker, 'state.json');
  t.after(() => server.close());
  const hostKeys = who('mac'), phoneKeys = who('phone'), room = id();
  const url = 'ws://127.0.0.1:' + server.address().port + '/v1/direct';
  const host = await connection(url), phone = await connection(url); await authenticate(host, 'mac', room, hostKeys);
  const claim = { inviteID: room, client: phoneKeys.identity, proof: randomBytes(32).toString('base64') };
  phone.send({ type: 'claim', room, claim: encoded(claim) }); await host.next('claim');
  const pairBytes = Buffer.from(JSON.stringify({ version: 1, id: room, host: hostKeys.identity, client: phoneKeys.identity,
    permissions: ['read'], revision: 1, revoked: false, confirmedAt: (Date.now() - 978307200000) / 1000 }));
  host.send({ type: 'confirm', room, confirmation: encoded({ pairBytes: pairBytes.toString('base64'), hostSignature: hostKeys.sign(pairBytes) }) });
  assert.equal((await host.next('error')).code, 'state_unavailable'); assert.equal(server.metrics().stateHealthy, false);
  assert.equal((await fetch('http://127.0.0.1:' + server.address().port + '/health')).status, 503);
});

function signedGrant(p, pair, signer = p.hostKeys) {
  const pairBytes = Buffer.from(JSON.stringify(pair));
  return { type: 'grant', room: p.room, confirmation: encoded({ pairBytes: pairBytes.toString('base64'), hostSignature: signer.sign(pairBytes) }) };
}
test('host permission update is durable, signed, and fences old signal revisions', async t => {
  const f = await fixture(t), p = await pair(f);
  const updated = { ...p.pair, permissions: ['read', 'chat'], revision: 2 };
  p.host.send(signedGrant(p, updated));
  const forwarded = await p.phone.next('grant');
  assert.deepEqual(JSON.parse(Buffer.from(JSON.parse(Buffer.from(forwarded.confirmation, 'base64')).pairBytes, 'base64')), updated);
  assert.deepEqual(JSON.parse(readFileSync(f.config.statePath, 'utf8')).pairs[p.room], updated);
  p.host.send(signal(p)); assert.equal((await p.host.next('error')).code, 'invalid_signal');
  const frame = signal(p), packet = JSON.parse(Buffer.from(frame.payload, 'base64')); packet.revision = 2;
  p.host.send({ ...frame, payload: encoded(packet) }); await p.phone.next('signal');
  p.host.send(signedGrant(p, updated)); await p.phone.next('grant'); // idempotent refresh
});
test('grant updates reject phone authorship, invalid signatures, rollback, and changed pinned fields', async t => {
  const f = await fixture(t), p = await pair(f), updated = { ...p.pair, permissions: ['read', 'chat'], revision: 2 };
  p.phone.send(signedGrant(p, updated)); assert.equal((await p.phone.next('error')).code, 'unauthorized');
  await p.host.next('peerOffline');
  p.phone = await connection(f.ws); await authenticate(p.phone, 'phone', p.room, p.phoneKeys);
  await p.host.next('peerReady'); await p.phone.next('peerReady');
  p.host.send(signedGrant(p, updated, p.phoneKeys)); assert.equal((await p.host.next('error')).code, 'invalid_confirmation');
  p.host.send(signedGrant(p, updated)); await p.phone.next('grant');
  const rejected = [p.pair, { ...updated, permissions: ['read', 'terminal'] },
    { ...updated, revision: 3, confirmedAt: updated.confirmedAt + 1 },
    { ...updated, revision: 3, client: who('phone').identity },
    { ...updated, revision: 3, permissions: ['terminal'] }];
  for (const value of rejected) {
    p.host.send(signedGrant(p, value)); assert.equal((await p.host.next('error')).code, 'invalid_confirmation');
  }
  assert.deepEqual(JSON.parse(readFileSync(f.config.statePath, 'utf8')).pairs[p.room], updated);
});
