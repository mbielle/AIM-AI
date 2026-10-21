// Minimal stdio MCP server for AIM tests. No network, no file access.
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin });
const notes = [];
const tools = [
  { name: 'echo', description: 'Echo text back.', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] }, annotations: { readOnlyHint: true, destructiveHint: false } },
  { name: 'add_note', description: 'Store a note in memory.', inputSchema: { type: 'object', properties: { note: { type: 'string' }, tags: { type: 'array', items: { type: 'string' } }, meta: { type: 'object', properties: { priority: { type: 'integer' } } } }, required: ['note'] }, annotations: { readOnlyHint: false, destructiveHint: false } },
  { name: 'list_notes', description: 'List stored notes.', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true, destructiveHint: false } },
  { name: 'token_present', description: 'Report whether FIXTURE_TOKEN reached the server.', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true, destructiveHint: false } },
  { name: 'hidden_admin', description: 'Must be filtered out by AIM.', inputSchema: { type: 'object', properties: {} } }
];
rl.on('line', (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.id === undefined) return;
  const reply = (result) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, result }) + '\n');
  const text = (value, isError = false) => reply({ content: [{ type: 'text', text: value }], isError });
  switch (message.method) {
    case 'initialize':
      return reply({ protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'aim-mcp-fixture', version: '1.0.0' } });
    case 'tools/list':
      return reply({ tools });
    case 'tools/call': {
      const { name, arguments: args = {} } = message.params || {};
      if (name === 'echo') return text(String(args.text));
      if (name === 'add_note') { notes.push({ note: args.note, tags: args.tags || [], priority: args.meta?.priority ?? null }); return reply({ content: [{ type: 'text', text: 'stored' }], structuredContent: { count: notes.length } }); }
      if (name === 'list_notes') return reply({ content: [{ type: 'text', text: JSON.stringify(notes) }] });
      if (name === 'token_present') return text(process.env.FIXTURE_TOKEN ? 'token:yes' : 'token:no');
      return text('unknown tool', true);
    }
    default:
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'method not found' } }) + '\n');
  }
});
