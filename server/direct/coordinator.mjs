import { createServer } from 'node:http';
import { createHash, createHmac, createPublicKey, randomBytes, timingSafeEqual, verify } from 'node:crypto';
import { closeSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const canonical = value => { if (!uuid(value)) throw new Error('invalid_message'); return value.toUpperCase(); };
function bytes(value, maximum = 196608) {
  if (typeof value !== 'string' || value.length > maximum * 1.4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw new Error('invalid_message');
  const result = Buffer.from(value, 'base64');
  if (!result.length || result.length > maximum) throw new Error('invalid_message');
  return result;
}
function identity(value, role) {
  if (!value || value.version !== 1 || value.role !== role || !uuid(value.id) || !uuid(value.localProfileID)
      || typeof value.name !== 'string' || value.name.length > 160) throw new Error('invalid_identity');
  const signing = bytes(value.signingKey, 65), agreement = bytes(value.agreementKey, 65);
  if (signing.length !== 65 || agreement.length !== 65 || signing[0] !== 4 || agreement[0] !== 4) throw new Error('invalid_identity');
  const key = raw => createPublicKey({ format: 'jwk', key: { kty: 'EC', crv: 'P-256', x: raw.subarray(1, 33).toString('base64url'), y: raw.subarray(33).toString('base64url') } });
  key(agreement); key(signing);
  return value;
}
const sameIdentity = (a, b) => a && b && ['version', 'id', 'localProfileID', 'role', 'name', 'agreementKey', 'signingKey'].every(k => a[k] === b[k]);
function validSignature(signature, payload, signer) {
  try {
    const raw = bytes(signer.signingKey, 65);
    const publicKey = createPublicKey({ format: 'jwk', key: { kty: 'EC', crv: 'P-256', x: raw.subarray(1, 33).toString('base64url'), y: raw.subarray(33).toString('base64url') } });
    return verify('sha256', payload, publicKey, bytes(signature, 80));
  } catch { return false; }
}
function constantEqual(a, b) {
  const x = Buffer.from(a ?? ''), y = Buffer.from(b ?? ''); return x.length === y.length && timingSafeEqual(x, y);
}
function integer(value, fallback, low, high) {
  const n = Number(value ?? fallback); if (!Number.isSafeInteger(n) || n < low || n > high) throw new Error('invalid_configuration'); return n;
}

export function configuration(env = process.env) {
  const urls = (env.AIM_DIRECT_TURN_URLS ?? '').split(',').map(s => s.trim()).filter(Boolean);
  if (urls.some(url => !/^(?:stun|turn|turns):[a-zA-Z0-9.-]+(?::[0-9]+)?(?:\?transport=(?:udp|tcp))?$/.test(url))) throw new Error('invalid_turn_url');
  const config = {
    host: env.AIM_DIRECT_BIND ?? '127.0.0.1', port: integer(env.AIM_DIRECT_PORT, 8789, 0, 65535),
    statePath: env.AIM_DIRECT_STATE ?? './data/coordinator.json',
    maxRooms: integer(env.AIM_DIRECT_MAX_ROOMS, 128, 1, 8192),
    allowedOrigins: new Set((env.AIM_DIRECT_ALLOWED_ORIGINS ?? '').split(',').filter(Boolean)),
    adminToken: env.AIM_DIRECT_ADMIN_TOKEN ?? '',
    turnURLs: urls, turnSecret: env.AIM_DIRECT_TURN_SECRET ?? '',
    turnTTL: integer(env.AIM_DIRECT_TURN_TTL, 120, 30, 300),
    turnBps: integer(env.AIM_DIRECT_TURN_BPS, 131072, 1024, 1048576),
    turnAllocations: integer(env.AIM_DIRECT_TURN_USER_QUOTA, 2, 1, 4),
    monthlyBytes: integer(env.AIM_DIRECT_RELAY_MONTHLY_BYTES, 10737418240, 0, Number.MAX_SAFE_INTEGER),
    quote: null,
  };
  if (!config.statePath.trim()) throw new Error('state_path_required');
  if (env.AIM_DIRECT_HOSTING_QUOTE) config.quote = JSON.parse(readFileSync(env.AIM_DIRECT_HOSTING_QUOTE, 'utf8'));
  return config;
}

export function approvedRelayQuote(quote, now = Date.now()) {
  return quote?.currency === 'EUR' && Number.isFinite(quote.monthlyTotalEUR) && quote.monthlyTotalEUR > 0
    && quote.monthlyTotalEUR <= 20 && quote.billableOverage === false && quote.automaticTopUps === false
    && typeof quote.reviewedBy === 'string' && quote.reviewedBy.trim().length > 0
    && typeof quote.validUntil === 'string' && Date.parse(quote.validUntil) > now;
}

/** Pair identities and conservative relay allocations only. No SDP, commands, QR token or model data is stored. */
export function startCoordinator(config = configuration()) {
  const now = () => Date.now(), rooms = new Map(), rates = new Map(), sockets = new Set();
  const counters = { websocketBytes: 0, forwardedSignals: 0, rejected: 0, authenticated: 0 };
  let durable = { version: 1, pairs: {}, relay: {} }, stateHealthy = true;
  if (config.statePath && existsSync(config.statePath)) {
    if (lstatSync(config.statePath).isSymbolicLink()) throw new Error('unsafe_state_path');
    durable = JSON.parse(readFileSync(config.statePath, 'utf8'));
    if (durable.version !== 1 || !durable.pairs || !durable.relay || Object.keys(durable.pairs).length > config.maxRooms) throw new Error('invalid_state');
    for (const [id, pair] of Object.entries(durable.pairs)) {
      if (canonical(id) !== id || canonical(pair.id) !== id || pair.version !== 1 || !Number.isSafeInteger(pair.revision) || pair.revision < 1) throw new Error('invalid_state');
      identity(pair.host, 'mac'); identity(pair.client, 'phone');
    }
  }
  let stateLock;
  if (config.statePath) {
    mkdirSync(dirname(resolve(config.statePath)), { recursive: true, mode: 0o700 });
    stateLock = resolve(config.statePath) + '.lock';
    const lock = openSync(stateLock, 'wx', 0o600);
    try { writeFileSync(lock, String(process.pid)); fsyncSync(lock); } finally { closeSync(lock); }
  }
  const persist = () => {
    if (!config.statePath) return;
    stateHealthy = false;
    const file = resolve(config.statePath); mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    const temporary = file + '.tmp-' + randomBytes(6).toString('hex');
    const output = openSync(temporary, 'wx', 0o600);
    try { writeFileSync(output, JSON.stringify(durable)); fsyncSync(output); } finally { closeSync(output); }
    renameSync(temporary, file);
    const parent = openSync(dirname(file), 'r');
    try { fsyncSync(parent); } finally { closeSync(parent); }
    stateHealthy = true;
  };
  const send = (ws, message) => {
    if (ws?.readyState !== WebSocket.OPEN) return;
    // A slow peer must not turn bounded frames into an unbounded server queue.
    if (ws.bufferedAmount > 1048576) { ws.close(1009, 'slow_peer'); return; }
    ws.send(JSON.stringify(message));
  };
  const error = (ws, code, close = false) => { counters.rejected++; send(ws, { type: 'error', code }); if (close) ws.close(1008, code); };
  const roomFor = id => {
    let room = rooms.get(id);
    if (!room) {
      if (rooms.size >= config.maxRooms) throw new Error('capacity');
      room = { id, pair: durable.pairs[id], claims: new Map(), host: null, phone: null, createdAt: now() }; rooms.set(id, room);
    }
    return room;
  };
  const metrics = () => ({ ...counters, rooms: rooms.size, connections: sockets.size,
    relayReservedBytes: durable.relay[new Date(now()).toISOString().slice(0, 7)] ?? 0,
    relayMonthlyBytes: config.monthlyBytes, stateHealthy,
    relayEnabled: stateHealthy && approvedRelayQuote(config.quote) && !!config.turnSecret });
  const http = createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') { res.writeHead(stateHealthy ? 200 : 503, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify({ ok: stateHealthy, version: 1 })); }
    else if (req.method === 'GET' && req.url === '/metrics' && config.adminToken.length >= 32 && constantEqual(req.headers.authorization, 'Bearer ' + config.adminToken)) {
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(metrics()));
    } else { res.writeHead(404); res.end(); }
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 262144, perMessageDeflate: false });
  http.on('upgrade', (req, socket, head) => {
    const origin = req.headers.origin;
    const ip = req.socket.remoteAddress ?? 'unknown', minute = Math.floor(now() / 60000), rate = rates.get(ip);
    const count = rate?.minute === minute ? rate.count + 1 : 1; rates.set(ip, { minute, count });
    if (req.url !== '/v1/direct' || (origin && !config.allowedOrigins.has(origin)) || count > 30 || sockets.size >= config.maxRooms * 4) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return;
    }
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws));
  });
  wss.on('connection', ws => {
    sockets.add(ws); let pending = null, authenticated = null, count = 0, window = now(); ws.alive = true;
    ws.createdAt = now(); ws.authenticated = false;
    ws.on('pong', () => { ws.alive = true; });
    ws.on('error', () => {});
    ws.on('close', () => {
      sockets.delete(ws);
      for (const room of rooms.values()) {
        if (room.host === ws) { room.host = null; send(room.phone, { type: 'peerOffline', room: room.id }); }
        if (room.phone === ws) { room.phone = null; send(room.host, { type: 'peerOffline', room: room.id }); }
        for (const [id, claim] of room.claims) if (claim.ws === ws) room.claims.delete(id);
      }
    });
    ws.on('message', (raw, binary) => {
      try {
        counters.websocketBytes += raw.length;
        if (binary) throw new Error('invalid_message');
        if (now() - window > 60000) { window = now(); count = 0; }
        if (++count > 240) throw new Error('rate_limit');
        if (!stateHealthy) throw new Error('state_unavailable');
        const message = JSON.parse(raw.toString('utf8'));
        if (!message || typeof message.type !== 'string') throw new Error('invalid_message');
        const id = canonical(message.room);
        if (message.type === 'host' || message.type === 'join') {
          if (authenticated || pending) throw new Error('already_started');
          identity(message.identity, message.type === 'host' ? 'mac' : 'phone');
        }
        if (!rooms.has(id) && !durable.pairs[id] && message.type !== 'host') throw new Error('unknown_room');
        const room = roomFor(id);
        if (room.pair?.revoked) throw new Error('revoked');
        if (message.type === 'host' || message.type === 'join') {
          if (authenticated || pending) throw new Error('already_started');
          const role = message.type === 'host' ? 'mac' : 'phone', who = identity(message.identity, role);
          if (room.pair && !sameIdentity(role === 'mac' ? room.pair.host : room.pair.client, who)) throw new Error('unauthorized');
          if (!room.pair && role === 'phone') throw new Error('not_paired');
          pending = { room: id, identity: who, nonce: randomBytes(32).toString('base64'), expires: now() + 30000 };
          send(ws, { type: 'challenge', room: id, nonce: pending.nonce }); return;
        }
        if (message.type === 'auth') {
          if (!pending || pending.room !== id || pending.expires < now()
              || !validSignature(message.signature, Buffer.from('aim-direct-auth/v1/' + id + '/' + pending.nonce), pending.identity)) throw new Error('unauthorized');
          const role = pending.identity.role;
          if (room.pair && !sameIdentity(role === 'mac' ? room.pair.host : room.pair.client, pending.identity)) throw new Error('unauthorized');
          if (!room.pair && room.identity && !sameIdentity(room.identity, pending.identity)) throw new Error('unauthorized');
          authenticated = { room: id, identity: pending.identity }; pending = null; counters.authenticated++; ws.authenticated = true;
          if (role === 'mac') { room.host?.close(4000, 'reconnected'); room.host = ws; room.identity = authenticated.identity; }
          else { room.phone?.close(4000, 'reconnected'); room.phone = ws; }
          send(ws, { type: 'authenticated', room: id });
          if (room.host && room.phone) { send(room.host, { type: 'peerReady', room: id }); send(room.phone, { type: 'peerReady', room: id }); }
          return;
        }
        if (message.type === 'claim') {
          if (authenticated || pending || room.pair || !room.host || room.claims.size >= 8) throw new Error('host_unavailable');
          const claimBytes = bytes(message.claim, 16384), claim = JSON.parse(claimBytes.toString('utf8'));
          identity(claim.client, 'phone'); if (canonical(claim.inviteID) !== id || bytes(claim.proof, 32).length !== 32) throw new Error('invalid_claim');
          const clientID = canonical(claim.client.id);
          room.claims.set(clientID, { claim, bytes: message.claim, ws, expires: now() + 120000 });
          send(room.host, { type: 'claim', room: id, claim: message.claim }); return;
        }
        if (!authenticated || authenticated.room !== id) throw new Error('unauthorized');
        if (message.type === 'confirm') {
          if (authenticated.identity.role !== 'mac' || room.pair) throw new Error('unauthorized');
          if (Object.keys(durable.pairs).length >= config.maxRooms) throw new Error('capacity');
          const confirmation = JSON.parse(bytes(message.confirmation, 32768).toString('utf8'));
          const pairBytes = bytes(confirmation.pairBytes, 16384), pair = JSON.parse(pairBytes.toString('utf8'));
          const claim = room.claims.get(canonical(pair.client?.id));
          identity(pair.client, 'phone'); identity(pair.host, 'mac');
          const confirmedAt = Number(pair.confirmedAt) * 1000 + 978307200000; // Swift Date reference epoch.
          if (!claim || claim.expires < now() || !sameIdentity(claim.claim.client, pair.client)
              || !sameIdentity(authenticated.identity, pair.host) || canonical(pair.id) !== id || pair.version !== 1
              || pair.revision !== 1 || pair.revoked !== false || !Array.isArray(pair.permissions) || !pair.permissions.length
              || pair.permissions.some(p => !['read', 'chat', 'code', 'agent', 'control', 'approve', 'settings', 'terminal'].includes(p))
              || !Number.isFinite(confirmedAt) || Math.abs(now() - confirmedAt) > 180000
              || !validSignature(confirmation.hostSignature, pairBytes, authenticated.identity)) throw new Error('invalid_confirmation');
          room.pair = pair; durable.pairs[id] = pair; persist();
          send(claim.ws, { type: 'confirm', room: id, confirmation: message.confirmation }); room.claims.clear(); return;
        }
        if (!room.pair) throw new Error('not_paired');
        if (message.type === 'grant') {
          if (authenticated.identity.role !== 'mac') throw new Error('unauthorized');
          const confirmation = JSON.parse(bytes(message.confirmation, 32768).toString('utf8'));
          const pairBytes = bytes(confirmation.pairBytes, 16384), pair = JSON.parse(pairBytes.toString('utf8'));
          const prior = room.pair;
          const permissions = value => [...new Set(value)].sort().join(',');
          if (pair.version !== prior.version || canonical(pair.id) !== id
              || !sameIdentity(pair.host, prior.host) || !sameIdentity(pair.client, prior.client)
              || pair.confirmedAt !== prior.confirmedAt || pair.revoked !== false
              || !Number.isSafeInteger(pair.revision) || pair.revision < prior.revision
              || !Array.isArray(pair.permissions) || !pair.permissions.includes('read')
              || pair.permissions.some(p => !['read', 'chat', 'code', 'agent', 'control', 'approve', 'settings', 'terminal'].includes(p))
              || (pair.revision === prior.revision && permissions(pair.permissions) !== permissions(prior.permissions))
              || !validSignature(confirmation.hostSignature, pairBytes, prior.host)) throw new Error('invalid_confirmation');
          if (pair.revision > prior.revision) { room.pair = pair; durable.pairs[id] = pair; persist(); }
          send(room.phone, { type: 'grant', room: id, confirmation: message.confirmation }); return;
        }
        if (message.type === 'signal') {
          const packet = JSON.parse(bytes(message.payload, 196608).toString('utf8'));
          const peer = authenticated.identity.role === 'mac' ? room.pair.client : room.pair.host;
          if (packet.version !== 1 || canonical(packet.pairID) !== id || packet.revision !== room.pair.revision
              || canonical(packet.sender) !== canonical(authenticated.identity.id) || canonical(packet.recipient) !== canonical(peer.id)
              || packet.kind !== 'signal' || !uuid(packet.id) || !Number.isSafeInteger(packet.sequence) || packet.sequence < 1
              || typeof packet.ciphertext !== 'string' || packet.ciphertext.length > 120000) throw new Error('invalid_signal');
          const other = authenticated.identity.role === 'mac' ? room.phone : room.host;
          if (!other) { error(ws, 'peer_offline'); return; }
          send(other, { type: 'signal', room: id, payload: message.payload }); counters.forwardedSignals++; return;
        }
        if (message.type === 'revoke') {
          if (authenticated.identity.role !== 'mac') throw new Error('unauthorized');
          room.pair = { ...room.pair, revoked: true, revision: room.pair.revision + 1 }; durable.pairs[id] = room.pair; persist();
          send(room.phone, { type: 'revoked', room: id }); room.phone?.close(4001, 'revoked'); room.phone = null; return;
        }
        if (message.type === 'turn') {
          if (!approvedRelayQuote(config.quote) || config.turnSecret.length < 32 || !config.turnURLs.length) { error(ws, 'relay_unavailable'); return; }
          if (ws.ice && ws.ice.expiresAtUnix * 1000 > now() + 10000) { send(ws, ws.ice); return; }
          const month = new Date(now()).toISOString().slice(0, 7);
          // Both directions, and a final allocation lifetime overlapping credential expiry.
          const reserved = 4 * config.turnBps * config.turnTTL * config.turnAllocations;
          const prior = durable.relay[month] ?? 0;
          if (!Number.isSafeInteger(prior) || prior + reserved > config.monthlyBytes) { error(ws, 'relay_quota'); return; }
          const expiresAtUnix = Math.floor(now() / 1000) + config.turnTTL;
          const username = expiresAtUnix + ':' + createHash('sha256').update(id + '/' + authenticated.identity.id).digest('hex').slice(0, 24);
          const credential = createHmac('sha1', config.turnSecret).update(username).digest('base64');
          durable.relay[month] = prior + reserved; persist();
          ws.ice = { type: 'ice', room: id, expiresAtUnix, servers: config.turnURLs.map(url => ({ url, username, credential, expiresAtUnix })) };
          send(ws, ws.ice); return;
        }
        throw new Error('invalid_message');
      } catch (e) {
        const code = !stateHealthy ? 'state_unavailable' : ['invalid_message', 'invalid_identity', 'capacity', 'unknown_room', 'revoked', 'already_started', 'unauthorized', 'not_paired', 'host_unavailable', 'invalid_claim', 'invalid_confirmation', 'invalid_signal', 'rate_limit'].includes(e.message) ? e.message : 'invalid_message';
        error(ws, code, ['unauthorized', 'revoked', 'rate_limit', 'state_unavailable'].includes(code));
      }
    });
  });
  const timer = setInterval(() => {
    for (const ws of sockets) {
      if (!ws.alive || (!ws.authenticated && now() - ws.createdAt > 180000)) ws.terminate();
      else { ws.alive = false; ws.ping(); }
    }
    for (const [id, room] of rooms) {
      for (const [key, claim] of room.claims) if (claim.expires < now()) { error(claim.ws, 'claim_expired', true); room.claims.delete(key); }
      if (!room.host && !room.phone && !room.claims.size && now() - room.createdAt > 180000) rooms.delete(id);
    }
    for (const [ip, rate] of rates) if (rate.minute < Math.floor(now() / 60000) - 1) rates.delete(ip);
  }, 15000); timer.unref();
  http.listen(config.port, config.host);
  let closing;
  return { http, metrics, address: () => http.address(), close: () => closing ??= (async () => {
    clearInterval(timer); for (const ws of sockets) ws.terminate();
    await new Promise(resolve => wss.close(resolve)); await new Promise(resolve => http.close(resolve));
    if (stateLock) {
      try { unlinkSync(stateLock); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      stateLock = undefined;
    }
  })() };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const service = startCoordinator();
  for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, async () => { await service.close(); process.exit(0); });
  console.log('AIM direct coordinator started; use TLS reverse proxy for public connections.');
}
