// Official OpenClaw registerTool contract; no shell/file/network tool executes
// inside the plugin. All effects are awaited from AIM's durable host dispatcher.
import fs from 'node:fs';
import {createRequire} from 'node:module';
const require = createRequire(process.env.AIM_OPENCLAW_ENTRY);
// OpenClaw loads plugins with require(): no top-level await here, or Node refuses the module
// (ERR_REQUIRE_ASYNC_MODULE) and the run aborts. Node 26 requires ES modules synchronously.
const ai = require(require.resolve('@openclaw/ai'));
const ipc = globalThis[Symbol.for('aim.bridge.ipc.v1')];
if (!ipc || typeof ai.configureAiTransportHost !== 'function' || typeof ai.getAiTransportHost !== 'function') throw Error('Incompatible OpenClaw AIM transport binding');
// Override the embedding host's DNS/HTTP transport with the pipe transport.
// An unexpected host route throws; the OS continues to deny all child network.
ai.configureAiTransportHost({...ai.getAiTransportHost(), requiresManagedTransport: () => true,
  buildModelFetch: model => {
    if (model.baseUrl !== 'https://aim.invalid/v1') throw Error('Unbound OpenClaw model route');
    return ipc.provider;
  }});
export default {
  id: 'aim-host-tools', name: 'AIM host tools', description: 'Native AIM scoped file and approved command tools.',
  register(api) {
    if (typeof api.registerTool !== 'function') throw Error('Installed OpenClaw lacks registerTool');
    const schemas = JSON.parse(fs.readFileSync(process.env.AIM_TOOL_SCHEMAS, 'utf8'));
    for (const schema of schemas) {
      const fn = schema.function;
      if (!fn.name.startsWith('aim_')) throw Error('Only AIM host tool names may be registered');
      api.registerTool({name: fn.name, label: fn.name, description: fn.description, parameters: fn.parameters,
        execute: async (toolCallId, params, signal) => {
          if (signal?.aborted) throw Error('AIM tool cancelled');
          const result = await ipc.tool(fn.name, params, toolCallId);
          // OpenClaw marks a tool result as failed only when execute throws; a refusal or a
          // failed command must reach the model as an error, with AIM's explanation.
          if (result.isError) throw Error(result.content || 'AIM tool failed');
          return {content: [{type: 'text', text: result.content}], details: {isError: result.isError, aimReceipt: result.metadata}};
        }}, {name: fn.name});
    }
    // Live work for AIM's view: the agents' text and reasoning as they are written, tool
    // starts and results, and sub-agent lifecycle. Observation only, never authority.
    const events = api.agent?.events ?? api;
    const subscribe = events.registerAgentEventSubscription ?? api.registerAgentEventSubscription;
    if (typeof subscribe === 'function') {
      subscribe.call(events, {id: 'aim-live', streams: ['assistant', 'thinking', 'tool', 'lifecycle'],
        handle: event => ipc.event({type: 'agent', stream: event.stream, sessionKey: event.sessionKey, runId: event.runId, data: event.data})});
    }
    if (typeof api.on === 'function') {
      api.on('subagent_spawned', event => ipc.event({type: 'subagent_spawned', childSessionKey: event.childSessionKey, label: event.label}));
      api.on('subagent_ended', event => ipc.event({type: 'subagent_ended', childSessionKey: event.targetSessionKey, outcome: event.outcome, error: event.error}));
    }
  }
};
