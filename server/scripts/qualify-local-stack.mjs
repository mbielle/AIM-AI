/** Real HTTP checks against an explicitly disposable, numeric-loopback Supabase.
 * No remote deployments, database reset, model calls, or external emails.
 */
import { randomBytes, randomUUID, webcrypto } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { boundedBody } from '../supabase/functions/_shared/request-body.ts';

export function localConfiguration(status, confirmed) {
  if (confirmed !== true) throw new Error('disposable_confirmation_required');
  const values = status?.env ?? status;
  let origin;
  try { origin = new URL(values.API_URL); } catch { throw new Error('invalid_local_origin'); }
  if (!['127.0.0.1', '[::1]'].includes(origin.hostname) ||
      !['http:', 'https:'].includes(origin.protocol) || origin.username ||
      origin.password || origin.pathname !== '/' || origin.search || origin.hash) {
    throw new Error('numeric_loopback_origin_required');
  }
  if (typeof values.ANON_KEY !== 'string' || !values.ANON_KEY ||
      typeof values.SERVICE_ROLE_KEY !== 'string' || !values.SERVICE_ROLE_KEY) {
    throw new Error('local_status_keys_missing');
  }
  return { origin: origin.origin, anon: values.ANON_KEY, service: values.SERVICE_ROLE_KEY };
}

class CheckFailure extends Error {}
const check = (condition, step) => { if (!condition) throw new CheckFailure(step); };
const idPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;

export async function qualifyLocalStack(configuration, { fetch: http = fetch, progress = () => {} } = {}) {
  // Validate again at the transport boundary, even for programmatic callers.
  const { origin, anon, service } = localConfiguration({
    API_URL: configuration.origin, ANON_KEY: configuration.anon,
    SERVICE_ROLE_KEY: configuration.service,
  }, true);
  const completed = [], failures = [], users = [], objects = [];
  let uncertainAccountCreations = 0;
  const nonce = randomUUID();
  let currentStep = 'health';
  const advance = step => { currentStep = step; progress(step); };
  advance('health');
  async function request(path, { token = anon, privileged = false, method = 'GET', body, raw, headers = {} } = {}) {
    check(path.startsWith('/') && !path.startsWith('//'), 'invalid_internal_path');
    const result = await http(new URL(path, origin), {
      method, redirect: 'error', signal: AbortSignal.timeout(45_000),
      // Isolate REST from the experimental gateway's WebSocket upgrade pool.
      headers: { Connection: 'close', apikey: privileged ? service : anon, Authorization: `Bearer ${token}`,
        ...(raw === undefined ? { 'Content-Type': 'application/json' } : {}), ...headers },
      body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
    });
    const text = await boundedBody(result, 2 * 1024 * 1024);
    let value; try { value = JSON.parse(text); } catch { value = text; }
    return { status: result.status, ok: result.ok, value };
  }
  async function success(path, options) {
    const response = await request(path, options);
    check(response.ok, `${currentStep}_http_${response.status}`);
    return response.value;
  }
  async function rpc(user, name, body = {}) {
    return success(`/rest/v1/rpc/${name}`, { token: user.token, method: 'POST', body });
  }
  async function createUser(label) {
    const email = `aim-qualification-${label}-${nonce}@example.invalid`;
    const password = randomBytes(32).toString('base64url');
    // A timed-out response does not prove the transaction failed on the server.
    uncertainAccountCreations++;
    const created = await success('/auth/v1/admin/users', {
      token: service, privileged: true, method: 'POST',
      body: { email, password, email_confirm: true, user_metadata: { aim_qualification: nonce } },
    });
    check(idPattern.test(created.id ?? ''), 'invalid_created_user');
    users.push(created.id);
    uncertainAccountCreations--;
    return { id: created.id, email, password };
  }
  async function login(account, label) {
    const session = await success('/auth/v1/token?grant_type=password', {
      method: 'POST', body: { email: account.email, password: account.password },
    });
    check(session.user?.id === account.id && typeof session.access_token === 'string', 'invalid_auth_session');
    const user = { id: account.id, token: session.access_token };
    await rpc(user, 'aim_register_account_session', { p_device: `Qualification ${label}`, p_platform: 'synthetic-http' });
    check(await rpc(user, 'aim_maintenance_session') === true, 'session_not_live');
    return user;
  }
  try {
    await success('/auth/v1/health');
    advance('auth');
    const account = await createUser('owner'), other = await createUser('other');
    const phone = await login(account, 'phone'), host = await login(account, 'host');
    const outsider = await login(other, 'other');
    completed.push('real_auth_two_accounts_three_sessions');

    advance('content_rls');
    const projects = await success('/rest/v1/projects?select=id', {
      token: phone.token, method: 'POST', headers: { Prefer: 'return=representation' },
      body: { name: 'Disposable qualification', user_id: account.id },
    });
    check(idPattern.test(projects[0]?.id ?? ''), 'project_not_created');
    const project = projects[0].id;
    const hidden = await success(`/rest/v1/projects?id=eq.${project}&select=id`, { token: outsider.token });
    check(Array.isArray(hidden) && hidden.length === 0, 'foreign_project_visible');
    const forbidden = await request('/rest/v1/conversations', {
      token: outsider.token, method: 'POST', body: { user_id: other.id, project_id: project, title: 'Must fail' },
    });
    check(!forbidden.ok, 'foreign_parent_write_admitted');
    completed.push('postgrest_owner_rls_and_foreign_parent_rejection');

    advance('documents');
    const document = randomUUID();
    await rpc(phone, 'aim_put_account_document', { p_account_id: account.id,
      p_document: { id: document, kind: 'chat', payload: 'Synthetic text', revision: 0 } });
    const exported = await rpc(phone, 'aim_export_account_documents');
    check(Array.isArray(exported) && exported.some(row => row.id === document), 'document_missing');
    const foreignExport = await rpc(outsider, 'aim_export_account_documents');
    check(Array.isArray(foreignExport) && foreignExport.length === 0, 'foreign_document_exported');
    completed.push('scoped_document_rpc_and_export');

    advance('remote');
    const machine = randomUUID(), device = randomUUID();
    const machineProof = randomBytes(32).toString('hex'), deviceProof = randomBytes(32).toString('hex');
    check((await rpc(host, 'remote_register_machine', { p_machine_id: machine,
      p_name: 'Synthetic host', p_platform: 'test', p_app_version: 'qualification',
      p_secret: machineProof, p_capabilities: {} })).ok, 'machine_registration_failed');
    const pairing = await rpc(host, 'remote_create_pairing_code', { p_machine_id: machine, p_secret: machineProof });
    check(typeof pairing.code === 'string', 'pairing_code_missing');
    check((await rpc(phone, 'remote_pair_device', { p_code: pairing.code, p_device_id: device,
      p_device_secret: deviceProof, p_device_name: 'Synthetic phone', p_public_key: null })).ok, 'pairing_failed');
    await rpc(phone, 'remote_migrate_device_authorization', { p_device_id: device, p_device_secret: deviceProof });
    await rpc(host, 'aim_register_remote_host', { p_machine_id: machine, p_secret: machineProof });
    const grant = await rpc(phone, 'remote_authorize_device', { p_device_id: device, p_device_secret: deviceProof });
    check(typeof grant.token === 'string', 'device_grant_missing');
    const command = randomUUID();
    const args = { p_device_id: device, p_device_secret: deviceProof, p_command_id: command,
      p_machine_id: machine, p_session_id: null, p_type: 'get_mac_settings', p_payload: {},
      p_unlock_token: grant.token, p_mode: 'chat' };
    const unapproved = await rpc(phone, 'remote_send_command', { ...args, p_unlock_token: 'invalid', p_command_id: randomUUID() });
    check(unapproved.ok === false, 'unapproved_command_admitted');
    check((await rpc(phone, 'remote_send_command', args)).ok, 'authorized_command_refused');
    check(await rpc(host, 'aim_remote_command_authorized', { p_machine_id: machine,
      p_secret: machineProof, p_command_id: command, p_conversation_id: null }) === true, 'host_authorization_failed');
    const read = await success(`/rest/v1/remote_commands?id=eq.${command}&select=id,payload`, { token: host.token });
    check(read.length === 1 && read[0].id === command, 'host_command_read_failed');
    const key = await webcrypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    const iv = randomBytes(12), plaintext = new TextEncoder().encode('Synthetic encrypted response');
    const ciphertext = await webcrypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, plaintext);
    const sealed = { nonce: iv.toString('base64'), ciphertext: Buffer.from(ciphertext).toString('base64') };
    advance('realtime');
    let wroteCompletion = false;
    const completeCommand = async () => {
      check((await rpc(host, 'remote_update_command', { p_machine_id: machine, p_secret: machineProof,
        p_command_id: command, p_status: 'done', p_error: null, p_result: sealed })).ok, 'host_completion_failed');
      wroteCompletion = true;
    };
    try {
      await observeRealtime(origin, anon, phone.token, command, completeCommand);
      completed.push('authenticated_realtime_command_update');
    } catch (error) {
      if (!(error instanceof CheckFailure) || !error.message.startsWith('realtime_')) throw error;
      // Preserve this failure while still checking independent HTTP/Storage/Edge gates.
      failures.push({ step: 'realtime', reason: error.message });
      if (!wroteCompletion) await completeCommand();
    }
    const finished = await success(`/rest/v1/remote_commands?id=eq.${command}&select=status,result`, { token: phone.token });
    check(finished[0]?.status === 'done', 'completion_missing');
    const result = finished[0].result;
    const decoded = await webcrypto.subtle.decrypt({ name: 'AES-GCM', iv: Buffer.from(result.nonce, 'base64') }, key, Buffer.from(result.ciphertext, 'base64'));
    check(new TextDecoder().decode(decoded) === 'Synthetic encrypted response', 'encrypted_result_mismatch');
    completed.push('paired_authorized_http_command_and_encrypted_result_transport');

    advance('storage');
    const object = `${account.id}/${randomUUID()}/result`;
    const bytes = Buffer.from('89504e470d0a1a0a', 'hex'); // Synthetic payload, not a user file.
    objects.push(object);
    await success(`/storage/v1/object/account-media/${object}`, { token: phone.token,
      method: 'POST', raw: bytes, headers: { 'Content-Type': 'image/png' } });
    const downloaded = await http(new URL(`/storage/v1/object/authenticated/account-media/${object}`, origin), {
      redirect: 'error', signal: AbortSignal.timeout(45_000), headers: { apikey: anon, Authorization: `Bearer ${phone.token}` },
    });
    check(downloaded.ok, 'storage_download_failed');
    check(Buffer.from(await boundedBytes(downloaded, bytes.length)).equals(bytes), 'storage_bytes_mismatch');
    const denied = await request(`/storage/v1/object/authenticated/account-media/${object}`, { token: outsider.token });
    check(!denied.ok, 'foreign_storage_object_visible');
    completed.push('real_storage_upload_download_and_cross_account_denial');

    advance('edge_functions');
    const unauthenticated = await request('/functions/v1/export-user-data', { token: 'invalid', method: 'POST', body: {} });
    check(unauthenticated.status === 401, 'edge_unauthenticated_export_admitted');
    const data = await success('/functions/v1/export-user-data', { token: phone.token, method: 'POST', body: {} });
    check(data.accountID === account.id && data.tables?.projects?.length === 1 &&
      data.includesKeychainCredentials === false, 'edge_export_wrong_account');
    const wrongConfirmation = await request('/functions/v1/delete-account', { token: outsider.token, method: 'POST',
      body: { confirmEmail: account.email, confirmText: 'SUPPRIMER' } });
    check(wrongConfirmation.status === 400, 'edge_wrong_confirmation_admitted');
    const retired = await request('/functions/v1/remote-unlock', { token: phone.token, method: 'POST',
      body: { action: 'pin-set', deviceId: device, deviceSecret: deviceProof, pin: '123456' } });
    check(retired.value?.error === 'legacy_security_retired', 'edge_pin_retirement_missing');
    const deleted = await success('/functions/v1/delete-account', { token: outsider.token, method: 'POST',
      body: { confirmEmail: other.email, confirmText: 'SUPPRIMER' } });
    check(deleted.success === true, 'edge_account_deletion_failed');
    const stillPresent = await success('/rest/v1/profiles?select=id', { token: phone.token });
    check(stillPresent.some(row => row.id === account.id), 'edge_deletion_affected_other_account');
    completed.push('edge_export_confirmation_deletion_isolation_and_legacy_pin_retirement');

    advance('revocation');
    await rpc(phone, 'remote_revoke_device_authorization', { p_device_id: device, p_device_secret: deviceProof });
    const revoked = await rpc(phone, 'remote_send_command', { ...args, p_command_id: randomUUID() });
    check(revoked.ok === false, 'revoked_device_grant_admitted');
    await rpc(phone, 'aim_revoke_account_sessions', { p_scope: 'all', p_session_id: null });
    const stopped = await request('/rest/v1/rpc/aim_maintenance_session', { token: phone.token, method: 'POST', body: {} });
    check(!stopped.ok, 'revoked_session_admitted');
    const isolated = await success('/rest/v1/profiles?select=id', { token: phone.token });
    check(Array.isArray(isolated) && isolated.length === 0, 'revoked_session_can_read');
    completed.push('device_grant_and_auth_session_revocation');
  } catch (error) {
    // Only controlled step labels leave this process; no response, key, JWT or email.
    const known = error instanceof CheckFailure ? error.message : 'transport_or_assertion_failed';
    return { ok: false, failedStep: currentStep, reason: known, failures, completed, cleanup: await cleanup() };
  }
  const cleaned = await cleanup();
  return { ok: failures.length === 0 && cleaned === 'synthetic_accounts_and_objects_removed', failures, completed, cleanup: cleaned,
    limits: ['synthetic HTTP clients, not native applications', 'external OAuth, APNs and official-host migration not qualified by this command'] };

  async function cleanup() {
    let complete = uncertainAccountCreations === 0;
    if (objects.length) {
      try {
        const removed = await request('/storage/v1/object/account-media', { privileged: true,
          token: service, method: 'DELETE', body: { prefixes: objects } });
        complete &&= removed.ok;
      } catch { complete = false; }
    }
    for (const id of users.reverse()) {
      try {
        const existing = await request(`/auth/v1/admin/users/${id}`, { privileged: true, token: service });
        if (existing.status === 404) continue;
        if (existing.value?.user_metadata?.aim_qualification !== nonce) { complete = false; continue; }
        const deleted = await request(`/auth/v1/admin/users/${id}`, { privileged: true, token: service, method: 'DELETE' });
        complete &&= deleted.ok;
      } catch { complete = false; }
    }
    return complete ? 'synthetic_accounts_and_objects_removed' : 'incomplete_keep_disposable_instance_for_inspection';
  }
}

export async function boundedBytes(response, maximum) {
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader(), chunks = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      length += value.byteLength;
      if (length > maximum) { await reader.cancel(); throw new CheckFailure('unexpected_binary_response_size'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

async function observeRealtime(origin, anon, token, command, write) {
  const endpoint = new URL('/realtime/v1/websocket', origin);
  endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:';
  endpoint.searchParams.set('apikey', anon); endpoint.searchParams.set('vsn', '1.0.0');
  const socket = new WebSocket(endpoint);
  let joined, changed, phase = 'connect';
  const ready = new Promise((resolve, reject) => { joined = { resolve, reject }; });
  const update = new Promise((resolve, reject) => { changed = { resolve, reject }; });
  // Both can reject on a transport failure while the other is being awaited.
  ready.catch(() => {}); update.catch(() => {});
  const fail = () => { joined.reject(new CheckFailure('realtime_transport_failed')); changed.reject(new CheckFailure('realtime_transport_failed')); };
  const timer = setTimeout(() => { joined.reject(new CheckFailure(`realtime_${phase}_state_${socket.readyState}_timeout`)); changed.reject(new CheckFailure(`realtime_${phase}_state_${socket.readyState}_timeout`)); }, 45_000);
  const channel = `realtime:qualification-${command}`;
  socket.addEventListener('open', () => { phase = 'join'; socket.send(JSON.stringify({
    topic: channel, event: 'phx_join', ref: '1', payload: { access_token: token,
      config: { postgres_changes: [{ event: 'UPDATE', schema: 'public', table: 'remote_commands', filter: `id=eq.${command}` }] } },
  })); });
  socket.addEventListener('error', fail);
  socket.addEventListener('close', fail);
  socket.addEventListener('message', event => {
    try {
      const raw = String(event.data);
      if (Buffer.byteLength(raw) > 65536) { fail(); return; }
      const message = JSON.parse(raw);
      if (message.topic !== channel) return;
      if (message.event === 'phx_reply' && message.ref === '1') {
        if (message.payload?.status === 'ok') phase = 'subscription'; else fail();
      }
      if (message.event === 'system' && message.payload?.extension === 'postgres_changes') {
        if (message.payload.status === 'ok') { phase = 'change'; joined.resolve(); } else fail();
      }
      if (message.event === 'postgres_changes' && message.payload?.data?.record?.id === command &&
          message.payload.data.record.status === 'done') changed.resolve();
    } catch { fail(); }
  });
  try { await ready; await write(); await update; }
  finally { clearTimeout(timer); socket.close(); }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 3 || args[0] !== '--status-file' || args[2] !== '--confirm-disposable') {
    throw new Error('usage_status_file_and_confirm_disposable_required');
  }
  const info = await stat(args[1]);
  check(info.isFile() && info.size < 65536 && (info.mode & 0o077) === 0, 'private_local_status_file_required');
  const configuration = localConfiguration(JSON.parse(await readFile(args[1], 'utf8')), true);
  const result = await qualifyLocalStack(configuration, { progress: step => process.stderr.write(`LOCAL STACK: ${step}\n`) });
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  if (!result.ok || result.cleanup !== 'synthetic_accounts_and_objects_removed') process.exitCode = 1;
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => { process.stderr.write('LOCAL STACK: invalid private configuration or invocation. No credentials printed.\n'); process.exitCode = 1; });
}
