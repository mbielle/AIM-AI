// AIM-owned final fetch transport hook, loaded before the installed OpenClaw CLI.
// File descriptors 3/4 are pipes inherited from the confined AIM bridge.
import fs from 'node:fs';
import readline from 'node:readline';
import {Socket} from 'node:net';
import crypto from 'node:crypto';
let counter = 0;
const pending = new Map();
// Wrap the inherited pipe in libuv. fs.ReadStream uses a blocking worker
// read for this fd and can prevent an otherwise completed CLI from exiting.
const replies = new Socket({fd: 4, readable: true, writable: false});
replies.unref();
const input = readline.createInterface({input: replies});
input.on('line', line => {
  try {
    // AIM writes UUIDs in upper case; randomUUID() is lower case.
    const chunk = JSON.parse(line), id = String(chunk.requestID).toLowerCase(), entry = pending.get(id);
    if (!entry || chunk.index !== entry.index++) throw Error('Unknown or reordered AIM provider response');
    const bytes = Buffer.from(chunk.bytes, 'base64'); entry.size += bytes.length;
    // A streamed answer carries event framing around every token: bounded at 32 MB, not 2 MB.
    if (entry.size > 33554432) throw Error('AIM response too large');
    if (entry.kind === 'provider') {
      // The model's answer is handed to OpenClaw while AIM receives it (true streaming).
      if (!entry.controller) {
        const stream = new ReadableStream({start: controller => { entry.controller = controller; }});
        entry.resolve(new Response(stream, {status: chunk.status, headers: {'content-type': chunk.contentType}}));
      }
      if (bytes.length) entry.controller.enqueue(new Uint8Array(bytes));
      if (chunk.final) {
        entry.controller.close(); pending.delete(id);
        if (pending.size === 0) replies.unref();
      }
      return;
    }
    entry.parts.push(bytes);
    if (chunk.final) {
      pending.delete(id);
      if (pending.size === 0) replies.unref();
      entry.resolve(JSON.parse(Buffer.concat(entry.parts).toString()));
    }
  } catch (error) {
    for (const entry of pending.values()) { try { entry.controller ? entry.controller.error(error) : entry.reject(error); } catch {} }
    pending.clear(); process.exitCode = 1;
  }
});
input.on('close', () => {
  for (const entry of pending.values()) {
    const error = Error('AIM provider outcome unknown; no automatic retry');
    try { entry.controller ? entry.controller.error(error) : entry.reject(error); } catch {}
  }
  pending.clear();
});
globalThis.fetch = async (url, options = {}) => {
  const request = new Request(url, options);
  if (request.url !== 'https://aim.invalid/v1/chat/completions' || request.method !== 'POST') throw Error('OpenClaw attempted an unbound network route');
  // Sub-agents run in this process beside the main agent: requests may overlap, AIM serves each.
  const body = Buffer.from(await request.arrayBuffer());
  if (body.length > 524288) throw Error('Upstream provider body too large');
  const requestID = crypto.randomUUID(); counter++;
  return new Promise((resolve, reject) => {
    replies.ref();
    pending.set(requestID, {resolve, reject, index: 0, parts: [], size: 0, kind: 'provider'});
    // Only upstream data. The wrapper attaches the immutable host grant.
    fs.writeSync(3, JSON.stringify({requestID, body: body.toString('base64'), sha256: crypto.createHash('sha256').update(body).digest('hex')}) + '\n');
  });
};

globalThis[Symbol.for('aim.bridge.ipc.v1')] = {
  provider: globalThis.fetch,
  tool(name, jsonArguments, toolCallId) {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      replies.ref();
      pending.set(id, {resolve, reject, index: 0, parts: [], size: 0, kind: 'tool'});
      fs.writeSync(3, JSON.stringify({kind: 'tool', id, name, jsonArguments, toolCallId}) + '\n');
    });
  },
  // What OpenClaw reports while it works (text, reasoning, tools, sub-agents): display only.
  event(value) {
    try { fs.writeSync(3, JSON.stringify({kind: 'event', value}) + '\n'); } catch {}
  }
};
