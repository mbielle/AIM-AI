#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
import readline from 'node:readline';
import {fileURLToPath} from 'node:url';
const args = process.argv.slice(2), upstream = args[args.indexOf('--upstream') + 1], state = args[args.indexOf('--state') + 1];
if (!args.includes('--upstream') || !args.includes('--state')) throw Error('Explicit upstream/state paths required');
const packageJSON = JSON.parse(fs.readFileSync(path.join(upstream, 'package.json')));
if (packageJSON.name !== 'openclaw' || !fs.existsSync(path.join(upstream, 'openclaw.mjs'))) throw Error('Installed upstream is not OpenClaw');
const preload = path.join(path.dirname(fileURLToPath(import.meta.url)), 'aim_openclaw_preload.mjs');
let hello, current, child, sequence = 0, output = '', requests = new Set();
function emit(frame) {
  Object.assign(frame, {version: 2, nonce: hello.nonce, identity: hello.identity});
  if (current && frame.kind !== 'hello_ack') Object.assign(frame, {id: current.id, conversationID: current.conversationID, sequence: ++sequence});
  process.stdout.write(JSON.stringify(frame) + '\n');
}
function checkpoint(name, value) {
  const temp = path.join(state, '.' + crypto.randomUUID()), dest = path.join(state, name);
  const fd = fs.openSync(temp, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeSync(fd, JSON.stringify(value)); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temp, dest);
  const dir = fs.openSync(state, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
  try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
}
function failed(details = {}) {
  if (!current) return;
  const reason = details.signal ? `signal ${details.signal}` : details.exitCode ? `code ${details.exitCode}` : 'arrêt ou réponse incompatible';
  emit({kind: 'event', event: {failed: {conversationID: current.conversationID, diagnostic: {code: 'openclaw.bridge.failed', message: `OpenClaw n’a pas terminé cette exécution confinée (${reason}). L’installation seule ne qualifie pas une mission. Vérifiez le reçu AIM avant une nouvelle tentative.`, isRecoverable: true, timestamp: 0, details}}}});
  current = undefined; requests.clear();
}
function activity(kind, fields = {}) {
  const value = {kind};
  for (const [key, item] of Object.entries(fields)) if (item !== undefined && item !== null) value[key] = item;
  emit({kind: 'activity', activity: value});
}
const isChild = key => typeof key === 'string' && key.includes(':subagent:');
function run(frame) {
  if (current) throw Error('One upstream turn per process');
  if (frame.request.provider !== 'openrouter' || frame.financeGrant.modelID !== frame.request.modelID) throw Error('A host-bound OpenRouter model is required');
  if (fs.existsSync(path.join(state, frame.id + '.run.json'))) throw Error('Existing upstream checkpoint requires explicit native review');
  current = frame; sequence = 0; output = '';
  // OpenClaw's live work, translated for AIM: the main agent's text and reasoning as written,
  // its delegation calls, and each sub-agent's text, reasoning and report.
  const live = {segment: '', streamed: false, item: null, toolSessions: new Map(), spawns: [],
    childText: new Map(), childThinking: new Map(), childItem: new Map(), childLast: new Map()};
  const flushChildren = only => {
    for (const [map, kind] of [[live.childThinking, 'subagentReasoning'], [live.childText, 'subagentText']]) {
      for (const [key, text] of map) {
        if (!text || (only && key !== only)) continue;
        map.set(key, ''); activity(kind, {childID: key, text: text.slice(0, 500000)});
      }
    }
  };
  const flusher = setInterval(() => { if (current) flushChildren(); }, 400);
  live.handle = value => {
    if (value.type === 'agent') {
      const data = value.data || {};
      if (value.stream === 'tool' && data.toolCallId && value.sessionKey) live.toolSessions.set(data.toolCallId, value.sessionKey);
      if (isChild(value.sessionKey)) {
        const key = value.sessionKey;
        if (value.stream === 'assistant' && typeof data.delta === 'string') {
          if (data.itemId !== live.childItem.get(key)) { live.childItem.set(key, data.itemId); live.childLast.set(key, ''); }
          live.childLast.set(key, (live.childLast.get(key) || '') + data.delta);
          live.childText.set(key, (live.childText.get(key) || '') + data.delta);
        } else if (value.stream === 'thinking' && typeof data.delta === 'string') {
          live.childThinking.set(key, (live.childThinking.get(key) || '') + data.delta);
        }
        return;
      }
      if (value.stream === 'assistant' && typeof data.delta === 'string' && data.delta) {
        if (data.itemId !== live.item) { live.item = data.itemId; live.segment = ''; }
        live.segment += data.delta; live.streamed = true;
        emit({kind: 'event', event: {textDelta: {conversationID: frame.conversationID, text: data.delta}}});
      } else if (value.stream === 'thinking' && typeof data.delta === 'string' && data.delta) {
        emit({kind: 'event', event: {reasoningDelta: {conversationID: frame.conversationID, text: data.delta}}});
      } else if (value.stream === 'tool' && data.name === 'sessions_spawn' && data.toolCallId) {
        if (data.phase === 'start') {
          live.spawns.push(data.args || {});
          activity('toolStarted', {callID: data.toolCallId, name: 'delegate_task', text: JSON.stringify(data.args ?? {}).slice(0, 20000)});
        } else if (data.phase === 'result') {
          activity('toolFinished', {callID: data.toolCallId, name: 'delegate_task', text: JSON.stringify(data.result ?? '').slice(0, 20000), isError: !!data.isError});
        }
      }
    } else if (value.type === 'subagent_spawned' && value.childSessionKey) {
      const args = live.spawns.shift() || {};
      const task = String(args.task ?? args.message ?? args.prompt ?? args.goal ?? '');
      activity('subagentStarted', {childID: value.childSessionKey, title: String(value.label || args.label || task || 'Sub-agent').slice(0, 100), text: task.slice(0, 15000)});
    } else if (value.type === 'subagent_ended' && value.childSessionKey) {
      flushChildren(value.childSessionKey);
      activity('subagentFinished', {childID: value.childSessionKey, text: (live.childLast.get(value.childSessionKey) || String(value.error || '')).slice(0, 400000),
        isError: !!value.outcome && value.outcome !== 'ok'});
    }
  };
  live.close = () => { clearInterval(flusher); flushChildren(); };
  checkpoint(frame.id + '.run.json', {runID: frame.id, phase: 'started', upstreamVersion: packageJSON.version});
  const workspace = path.join(state, 'workspace'); fs.mkdirSync(workspace, {recursive: true, mode: 0o700});
  const schemas = JSON.parse(Buffer.from(frame.toolSchemas || 'W10=', 'base64'));
  const pluginRoot = path.join(state, 'aim-plugin'); fs.mkdirSync(pluginRoot, {mode: 0o700});
  fs.copyFileSync(path.join(path.dirname(preload), 'aim_openclaw_plugin.mjs'), path.join(pluginRoot, 'index.mjs'));
  const toolNames = schemas.map(item => item.function.name);
  checkpoint('tool-schemas.json', schemas);
  const effort = frame.request.openAIReasoningEffort && frame.request.openAIReasoningEffort !== 'none' ? frame.request.openAIReasoningEffort : null;
  const pluginManifest = {id: 'aim-host-tools', name: 'AIM host tools', activation: {onStartup: true},
    contracts: {tools: toolNames}, configSchema: {type: 'object', properties: {}, additionalProperties: false}};
  fs.writeFileSync(path.join(pluginRoot, 'openclaw.plugin.json'), JSON.stringify(pluginManifest), {mode: 0o600});
  fs.writeFileSync(path.join(pluginRoot, 'package.json'), JSON.stringify({name: 'aim-host-tools', type: 'module', openclaw: {extensions: ['./index.mjs']}}), {mode: 0o600});
  const config = {plugins: {enabled: true, allow: ['aim-host-tools'], load: {paths: [pluginRoot]}, entries: {'aim-host-tools': {enabled: true}}},
    // AIM sends its own tool list; OpenClaw's tool search would advertise a tool AIM does not grant.
    // AIM's tools only. OpenClaw's own sub-agents (sessions_spawn) need its Gateway server, which a
    // confined one-shot `agent --local` run does not have; tool search would advertise a tool AIM
    // does not grant. Sub-agent events stay translated should a later version run them locally.
    tools: {allow: toolNames, toolSearch: false, codeMode: {enabled: false},
      deny: ['gateway', 'cron', 'message', 'sessions_*', 'subagents', 'agents_*', 'conversations_*']},
    // Every call runs on the person's model through AIM: no fallback, utility, decision or memory model.
    agents: {defaults: {workspace, model: {primary: 'aim/' + frame.request.modelID, fallbacks: []}, skipBootstrap: true,
      utilityModel: '', decisionModel: '', compaction: {model: 'aim/' + frame.request.modelID},
      subagents: {model: 'aim/' + frame.request.modelID, maxSpawnDepth: 1, maxConcurrent: 3}},
      list: [{id: 'main', default: true, workspace}]},
    memory: {search: {enabled: false}},
    update: {checkOnStart: false},
    models: {mode: 'replace', providers: {aim: {baseUrl: 'https://aim.invalid/v1', api: 'openai-completions', apiKey: 'aim-pipe-sentinel',
      timeoutSeconds: 600,
      models: [{id: frame.request.modelID, name: frame.request.modelID, contextWindow: frame.request.contextLength || 32768, maxTokens: frame.request.anthropicOutputTokens || 4096,
        input: ['text'], reasoning: !!effort}]}}}};
  checkpoint('openclaw.json', config);
  const thinking = effort ? ['--thinking', ['minimal', 'low', 'medium', 'high'].includes(effort) ? effort : 'high'] : [];
  // A minimal environment: no inherited keys, proxies or login-shell imports reach OpenClaw.
  const base = {PATH: process.env.PATH || '/usr/bin:/bin', HOME: state, OPENCLAW_HOME: state, TMPDIR: process.env.TMPDIR || '/tmp', LANG: process.env.LANG || 'en_US.UTF-8'};
  child = spawn(process.execPath, ['--import', preload, path.join(upstream, 'openclaw.mjs'), 'agent', '--local', '--agent', 'main', '--session-id', frame.id, '--message', frame.request.text, '--json', ...thinking],
    {cwd: state, env: {...base, OPENCLAW_NO_RESPAWN: '1', OPENCLAW_STATE_DIR: state, OPENCLAW_CONFIG_PATH: path.join(state, 'openclaw.json'), NODE_DISABLE_COMPILE_CACHE: '1', AIM_OPENCLAW_ENTRY: path.join(upstream, 'openclaw.mjs'), AIM_TOOL_SCHEMAS: path.join(state, 'tool-schemas.json')}, stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe']});
  child.stdout.on('data', bytes => { output += bytes.toString(); if (Buffer.byteLength(output) > 2097152) { child.kill('SIGTERM'); failed(); } });
  // Untrusted logs remain stderr, never AIM protocol or authorization.
  child.stderr.pipe(process.stderr);
  // A copy of the upstream log stays in this run's private state folder, for diagnosis only.
  const errorLog = fs.createWriteStream(path.join(state, 'openclaw-stderr.log'), {flags: 'a', mode: 0o600});
  child.stderr.pipe(errorLog);
  readline.createInterface({input: child.stdio[3]}).on('line', line => {
    try {
      const req = JSON.parse(line);
      if (req.kind === 'event') { if (current) live.handle(req.value || {}); return; }
      const requestID = req.kind === 'tool' ? req.id : req.requestID;
      if (!current || requests.has(requestID)) throw Error('Repeated or unbound upstream attempt');
      requests.add(requestID);
      if (req.kind === 'tool') {
        checkpoint(requestID + '.json', {requestID, runID: frame.id, tool: req.name, phase: 'pending'});
        // A sub-agent's call is shown in that sub-agent's journal.
        const session = req.toolCallId ? live.toolSessions.get(req.toolCallId) : undefined;
        emit({kind: 'tool_request', toolCall: {id: requestID, name: req.name, jsonArguments: req.jsonArguments}, ...(isChild(session) ? {origin: session} : {})});
        return;
      }
      checkpoint(req.requestID + '.json', {requestID: req.requestID, runID: frame.id, sha256: req.sha256, phase: 'pending'});
      emit({kind: 'provider_request', providerProtocolVersion: 1, providerRequest: {version: 1, ...req, grantID: frame.financeGrant.id}});
    } catch { child.kill('SIGTERM'); failed(); }
  });
  child.on('error', () => failed({stage: 'upstream-launch'}));
  child.on('close', (code, signal) => {
    live.close();
    if (!current) return;
    try {
      if (code !== 0) throw Error('Upstream failed');
      const value = JSON.parse(output), payloads = value.payloads || value.result?.payloads;
      if (!Array.isArray(payloads)) throw Error('Incompatible upstream output');
      const answer = payloads.map(p => p.text || '').join('\n');
      // Streamed text is already on screen: send only what is missing, then the final answer.
      const missing = !live.streamed ? answer : (live.segment && answer.startsWith(live.segment) ? answer.slice(live.segment.length) : '');
      let chunk = '', chunkBytes = 0;
      for (const point of missing) {
        const bytes = Buffer.byteLength(point, 'utf8');
        if (chunkBytes + bytes > 4096) {
          emit({kind: 'event', event: {textDelta: {conversationID: frame.conversationID, text: chunk}}});
          chunk = ''; chunkBytes = 0;
        }
        chunk += point; chunkBytes += bytes;
      }
      if (chunk) emit({kind: 'event', event: {textDelta: {conversationID: frame.conversationID, text: chunk}}});
      activity('final', {text: answer.slice(0, 600000)});
      checkpoint(frame.id + '.run.json', {runID: frame.id, phase: 'completed', answerSHA256: crypto.createHash('sha256').update(answer).digest('hex')});
      emit({kind: 'event', event: {completed: {conversationID: frame.conversationID}}}); current = undefined; requests.clear();
    } catch { failed({stage: 'upstream-exit', ...(code !== null ? {exitCode: String(code)} : {}), ...(signal ? {signal} : {})}); }
  });
}
for await (const line of readline.createInterface({input: process.stdin})) {
  const frame = JSON.parse(line);
  if (!hello) {
    if (frame.kind !== 'hello' || frame.version !== 2 || frame.financeProtocolVersion !== 1 || frame.providerProtocolVersion !== 1 || frame.readOnly !== true) throw Error('AIM v2 read-only financial/provider binding required');
    hello = frame; emit({kind: 'hello_ack', engineVersion: frame.engineVersion, readOnly: true, financeProtocolVersion: 1, providerProtocolVersion: 1}); continue;
  }
  if (frame.version !== 2 || frame.nonce !== hello.nonce || frame.identity !== hello.identity) throw Error('Stale AIM host frame');
  if (frame.kind === 'run') run(frame);
  else if (frame.kind === 'provider_response' || frame.kind === 'tool_response') {
    const requestID = String(frame.providerChunk.requestID).toLowerCase();
    if (!current || frame.id !== current.id || !requests.has(requestID)) throw Error('Unknown upstream response owner');
    child.stdio[4].write(JSON.stringify(frame.providerChunk) + '\n');
    if (frame.providerChunk.final) checkpoint(requestID + '.json', {requestID, runID: current.id, phase: 'returned'});
  } else if (frame.kind === 'cancel') { child?.kill('SIGTERM'); failed(); }
  else throw Error('Unsupported AIM host frame');
}
child?.kill('SIGTERM');
