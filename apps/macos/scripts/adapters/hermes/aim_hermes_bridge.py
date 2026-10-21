#!/usr/bin/env python3
"""AIM-owned Hermes bridge. Hermes source is imported, never copied here.
HTTPX transports rendezvous with AIM over stdio; Seatbelt is the OS boundary.
This bridge deliberately offers no upstream tools or external credentials.
"""
import argparse, base64, contextlib, hashlib, json, os, queue, sys, threading, uuid
from pathlib import Path

WIRE = sys.stdout
LOCK = threading.RLock()
PENDING = {}
CURRENT = None
HELLO = None
ARGS = None
DELEGATE_SCHEMA = None
# Tools Hermes runs inside its own loop; an AIM tool of the same name would never reach AIM.
HERMES_INLINE = {'todo_list', 'message_agent', 'session_search', 'memory', 'clarify', 'read_terminal', 'desktop_preview',
                 'drive_preview', 'annotate_preview', 'read_window_below', 'gui_tour', 'manage_connections', 'manage_catalog',
                 'setup_mcp', 'delegate_task'}
GUI_PREFIXES = ('desktop_', 'bg_', 'browser_')
GUI_TOOLS = {'run_applescript', 'open_app', 'open_url', 'open_file', 'list_apps'}
# The parent's plan and questions to the person stay with the parent, as for AIM's own sub-agents.
CHILD_EXCLUDED = {'update_plan', 'ask_user'}
# Hermes sub-agent session ID -> the sub-agent key AIM shows.
SESSIONS = {}
# Requests whose answer Hermes finished reading (late closing frames are expected).
CLOSED = set()
LOCAL = threading.local()

def current_origin():
    return getattr(LOCAL, 'origin', None)

def activity(kind, **fields):
    """Something AIM shows beyond the text: the final answer, delegation, sub-agents."""
    value = {'kind': kind}
    value.update({key: item for key, item in fields.items() if item is not None})
    emit({'kind': 'activity', 'activity': value})

class Live:
    """Hermes callbacks -> AIM events: the main agent's text and reasoning as they are written,
    its delegation calls, and each sub-agent's start, text, reasoning and report."""
    def __init__(self, conversation):
        self.conversation = conversation; self.segment = ''; self.streamed = False
        self.lock = threading.Lock(); self.child_text = {}; self.child_reasoning = {}
        self.calls = []; self.children = {}; self.tasks = {}
        self.stop = threading.Event()
        threading.Thread(target=self.flusher, daemon=True).start()
    def text(self, piece):
        if piece is None:
            self.segment = ''; return
        if not piece: return
        self.segment += piece; self.streamed = True
        emit({'kind': 'event', 'event': {'textDelta': {'conversationID': self.conversation, 'text': piece}}})
    def reasoning(self, piece):
        if piece:
            emit({'kind': 'event', 'event': {'reasoningDelta': {'conversationID': self.conversation, 'text': piece}}})
    def key(self, kw):
        return str(kw.get('child_session_id') or kw.get('subagent_id') or ('task-%s' % kw.get('task_index', 0)))
    def flusher(self):
        while not self.stop.wait(0.4): self.flush()
    def flush(self, only=None):
        with self.lock:
            texts = {k: v for k, v in self.child_text.items() if v and (only is None or k == only)}
            thoughts = {k: v for k, v in self.child_reasoning.items() if v and (only is None or k == only)}
            for k in texts: self.child_text[k] = ''
            for k in thoughts: self.child_reasoning[k] = ''
        for k, v in thoughts.items(): activity('subagentReasoning', childID=k, text=v[:500000])
        for k, v in texts.items(): activity('subagentText', childID=k, text=v[:500000])
    def progress(self, event_type, tool_name=None, preview=None, args=None, **kw):
        try:
            if event_type == 'tool.started' and tool_name == 'delegate_task':
                call = str(uuid.uuid4()); self.calls.append(call)
                activity('toolStarted', callID=call, name='delegate_task', text=json.dumps(args if args is not None else preview, default=str)[:20000])
            elif event_type == 'tool.completed' and tool_name == 'delegate_task':
                call = self.calls.pop(0) if self.calls else str(uuid.uuid4())
                result = kw.get('result'); text = result if isinstance(result, str) else json.dumps(result, default=str)
                self.finish_from_result(text)
                activity('toolFinished', callID=call, name='delegate_task', text=(text or '')[:20000], isError=bool(kw.get('is_error')))
            elif event_type == 'subagent.start':
                key = self.key(kw)
                if kw.get('child_session_id'): SESSIONS[str(kw['child_session_id'])] = key
                self.children[key] = {'index': kw.get('task_index'), 'summary': None, 'failed': False}
                if kw.get('task_index') is not None: self.tasks[kw.get('task_index')] = key
                goal = kw.get('goal') or preview or ''
                activity('subagentStarted', childID=key, title=goal[:100], text=goal[:15000])
            elif event_type == 'subagent.text':
                key = self.key(kw)
                with self.lock: self.child_text[key] = self.child_text.get(key, '') + (preview or '')
            # 'subagent.thinking' carries Hermes's spinner captions, not reasoning: not shown.
            elif event_type == 'subagent.complete':
                key = self.key(kw)
                state = self.children.setdefault(key, {})
                state['summary'] = kw.get('summary') or preview
                state['failed'] = str(kw.get('status') or 'completed') not in ('completed', 'success', 'ok', 'done')
        except Exception:
            pass
    def finish_from_result(self, text):
        """The delegation result carries each sub-agent's complete report."""
        reports = {}
        try:
            for item in (json.loads(text or '{}').get('results') or []):
                reports[item.get('task_index')] = item
        except Exception:
            pass
        for index, item in reports.items():
            key = self.tasks.get(index)
            if not key: continue
            self.flush(key)
            status = str(item.get('status') or 'completed')
            activity('subagentFinished', childID=key, text=str(item.get('summary') or '')[:400000],
                     isError=status not in ('completed', 'success', 'ok', 'done'))
            self.children.pop(key, None)
    def close(self):
        self.stop.set(); self.flush()
        for key, state in list(self.children.items()):
            activity('subagentFinished', childID=key, text=(state.get('summary') or '')[:400000], isError=bool(state.get('failed')))
        self.children.clear()

def emit(frame):
    with LOCK:
        frame.update(version=2, nonce=HELLO['nonce'], identity=HELLO['identity'])
        if CURRENT and frame['kind'] != 'hello_ack':
            CURRENT['sequence'] += 1
            frame.update(id=CURRENT['id'], conversationID=CURRENT['conversationID'], sequence=CURRENT['sequence'])
        WIRE.write(json.dumps(frame, separators=(',', ':')) + '\n'); WIRE.flush()

def checkpoint(name, data):
    root = Path(ARGS.state)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temp = '.' + str(uuid.uuid4())
    try:
        out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(out, 'wb') as file:
            file.write(json.dumps(data, sort_keys=True).encode()); file.flush(); os.fsync(file.fileno())
        os.rename(temp, name, src_dir_fd=fd, dst_dir_fd=fd); os.fsync(fd)
    finally:
        os.close(fd)

def provider(body):
    """Sends one model request through AIM; returns (status, content type, chunk iterator).
    AIM passes the answer on while the model writes it, so Hermes streams it for real."""
    if not CURRENT or CURRENT['cancelled'].is_set(): raise RuntimeError('AIM run cancelled or unbound')
    if len(body) > 524288: raise RuntimeError('Upstream provider body exceeds AIM bound')
    # Hermes uses the custom/OpenAI-compatible wire vocabulary for our private
    # sentinel. The native host exclusively forwards to OpenRouter, whose
    # admitted vocabulary is reasoning, never reasoning_effort.
    payload = json.loads(body)
    if 'reasoning_effort' in payload:
        effort = payload.pop('reasoning_effort')
        if not isinstance(effort, str) or effort not in {'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'}:
            raise RuntimeError('Unsupported upstream reasoning effort')
        reasoning = {'enabled': False} if effort == 'none' else {'effort': effort}
        if 'reasoning' in payload and payload['reasoning'] != reasoning:
            raise RuntimeError('Conflicting upstream reasoning controls')
        payload['reasoning'] = reasoning
        body = json.dumps(payload, separators=(',', ':')).encode()
        if len(body) > 524288: raise RuntimeError('Normalized provider body exceeds AIM bound')
    request_id = str(uuid.uuid4()); digest = hashlib.sha256(body).hexdigest()
    receipt = {'version': 1, 'requestID': request_id, 'grantID': CURRENT['financeGrant']['id'],
               'body': base64.b64encode(body).decode(), 'sha256': digest}
    inbox = queue.Queue(); PENDING[request_id] = inbox
    run_id = CURRENT['id']
    checkpoint(request_id + '.json', {'requestID': request_id, 'runID': run_id, 'sha256': digest, 'phase': 'pending'})
    frame = {'kind': 'provider_request', 'providerProtocolVersion': 1, 'providerRequest': receipt}
    origin = current_origin()
    if origin: frame['origin'] = origin
    emit(frame)
    first = inbox.get()
    if first is None: PENDING.pop(request_id, None); raise RuntimeError('AIM provider outcome unknown; automatic retry forbidden')
    def chunks():
        response = bytearray(); expected = 0; chunk = first
        try:
            while True:
                if chunk is None: raise RuntimeError('AIM provider outcome unknown; automatic retry forbidden')
                if chunk['index'] != expected or chunk['requestID'].lower() != request_id: raise RuntimeError('AIM provider chunk reordered')
                expected += 1; piece = base64.b64decode(chunk['bytes'], validate=True); response.extend(piece)
                if len(response) > 33554432: raise RuntimeError('AIM response exceeds bound')  # streamed framing: 32 MB
                if piece: yield piece
                if chunk['final']:
                    checkpoint(request_id + '.json', {'requestID': request_id, 'runID': run_id, 'sha256': digest, 'phase': 'returned', 'responseSHA256': hashlib.sha256(response).hexdigest()})
                    return
                chunk = inbox.get()
        finally:
            PENDING.pop(request_id, None); CLOSED.add(request_id)
    return first['status'], first['contentType'], chunks()

def host_tool(function_name, arguments, *args, **kwargs):
    if not CURRENT or CURRENT['cancelled'].is_set(): raise RuntimeError('AIM tool owner revoked')
    schemas = json.loads(base64.b64decode(CURRENT.get('toolSchemas') or 'W10='))
    names = {item['function']['name'] for item in schemas}
    if function_name not in names: raise RuntimeError('No native AIM binding for this upstream tool')
    values = json.loads(arguments) if isinstance(arguments, str) else arguments
    if not isinstance(values, dict): raise RuntimeError('Invalid upstream tool arguments')
    request_id = str(uuid.uuid4()); inbox = queue.Queue(); PENDING[request_id] = inbox
    checkpoint(request_id + '.json', {'requestID': request_id, 'runID': CURRENT['id'], 'tool': function_name, 'phase': 'pending'})
    frame = {'kind': 'tool_request', 'toolCall': {'id': request_id, 'name': function_name, 'jsonArguments': values}}
    # A sub-agent's call is shown in that sub-agent's journal.
    session = kwargs.get('session_id')
    origin = SESSIONS.get(session) if session else None
    if origin: frame['origin'] = origin
    emit(frame)
    response = bytearray(); index = 0
    try:
        while True:
            chunk = inbox.get()
            if chunk is None: raise RuntimeError('AIM tool outcome unknown; no automatic retry')
            if chunk['index'] != index or chunk['requestID'].lower() != request_id: raise RuntimeError('AIM tool result reordered')
            index += 1; response.extend(base64.b64decode(chunk['bytes'], validate=True))
            if len(response) > 2097152: raise RuntimeError('AIM tool result exceeds bound')
            if chunk['final']:
                result = json.loads(response)
                checkpoint(request_id + '.json', {'requestID': request_id, 'runID': CURRENT['id'], 'phase': 'returned'})
                return json.dumps({'error' if result['isError'] else 'result': result['content'], 'aim_receipt': result.get('metadata', {})})
    finally:
        PENDING.pop(request_id, None)

def load_hermes():
    # Intercept the final HTTP transport, rather than observing cost after send.
    import httpx
    # No inherited/system proxy discovery or credential-bearing environment.
    # The only wire route is the pipe-backed final transport below.
    for cls in (getattr(httpx, 'Client', None), getattr(httpx, 'AsyncClient', None)):
        if cls is not None:
            original = cls.__init__
            def private_client(self, *args, _original=original, **kwargs):
                kwargs['trust_env'] = False
                _original(self, *args, **kwargs)
            cls.__init__ = private_client
    class PipeStream(httpx.SyncByteStream):
        def __init__(self, chunks): self.chunks = chunks
        def __iter__(self): yield from self.chunks
    class AsyncPipeStream(httpx.AsyncByteStream):
        def __init__(self, chunks): self.chunks = chunks
        async def __aiter__(self):
            import asyncio
            sentinel = object()
            while True:
                piece = await asyncio.to_thread(next, self.chunks, sentinel)
                if piece is sentinel: return
                yield piece
    def blocked_transport(self, request):
        if request.method != 'POST' or str(request.url) != 'https://aim.invalid/v1/chat/completions':
            raise RuntimeError('Hermes attempted an unbound network route')
        status, content_type, chunks = provider(request.read())
        return httpx.Response(status, headers={'content-type': content_type}, stream=PipeStream(chunks), request=request)
    async def blocked_async(self, request):
        body = await request.aread()
        if request.method != 'POST' or str(request.url) != 'https://aim.invalid/v1/chat/completions':
            raise RuntimeError('Hermes attempted an unbound network route')
        status, content_type, chunks = await __import__('asyncio').to_thread(provider, body)
        return httpx.Response(status, headers={'content-type': content_type}, stream=AsyncPipeStream(chunks), request=request)
    httpx.HTTPTransport.handle_request = blocked_transport
    httpx.AsyncHTTPTransport.handle_async_request = blocked_async
    sys.path.insert(0, ARGS.upstream)
    import model_tools
    global DELEGATE_SCHEMA
    # Hermes's own delegation (its sub-agents) stays available to the main agent; every other
    # tool is AIM's. Names Hermes handles inside its loop are never advertised as AIM tools.
    try:
        found = [item for item in model_tools.get_tool_definitions(enabled_toolsets=['delegation'], quiet_mode=True)
                 if item.get('function', {}).get('name') == 'delegate_task']
        if found:
            DELEGATE_SCHEMA = json.loads(json.dumps(found[0]))
            DELEGATE_SCHEMA['function']['description'] = (
                'Start sub-agents that work in parallel on separate parts of the task, each with the same tools as you '
                '(AIM tools), then return their reports. Give each a clear goal and the context it needs.')
    except Exception:
        DELEGATE_SCHEMA = None
    def definitions(*args, **kwargs):
        if not CURRENT: return []
        schemas = [item for item in json.loads(base64.b64decode(CURRENT.get('toolSchemas') or 'W10='))
                   if item['function']['name'] not in HERMES_INLINE]
        try:
            from agent.delegation_context import is_delegated_child_context
            child = is_delegated_child_context()
        except Exception:
            child = False
        if child:
            # Like AIM's own sub-agents: no screen, mouse, browser or script control, which several
            # children working at once would fight over.
            schemas = [item for item in schemas if not item['function']['name'].startswith(GUI_PREFIXES)
                       and item['function']['name'] not in GUI_TOOLS | CHILD_EXCLUDED]
        elif DELEGATE_SCHEMA: schemas.append(DELEGATE_SCHEMA)
        return schemas
    model_tools.get_tool_definitions = definitions
    model_tools.handle_function_call = host_tool
    from run_agent import AIAgent
    import inspect
    required = {'base_url', 'api_key', 'provider', 'api_mode', 'skip_memory', 'skip_background_review', 'load_soul_identity', 'max_tokens', 'reasoning_config',
                'stream_delta_callback', 'reasoning_callback', 'tool_progress_callback'}
    if not required.issubset(inspect.signature(AIAgent.__init__).parameters):
        raise RuntimeError('Installed Hermes API is incompatible with aim.hermes.bridge.v1')
    return AIAgent

def write_config(request):
    """Every Hermes model call uses the person's model through AIM: no auxiliary or sub-agent
    model of its own, no fallback, the real context window. JSON is valid YAML."""
    window = request.get('contextLength') or 200000
    config = {'model': {'context_length': window, 'streaming': True},
              'agent': {'api_max_retries': 1, 'auto_recovery_cycles': 0},
              'auxiliary': {'title_generation': {'enabled': False, 'model_upgrade_enabled': False}},
              'fallback_providers': [],
              'security': {'allow_lazy_installs': False},
              'delegation': {'model': '', 'provider': '', 'base_url': '', 'api_key': '', 'fallback_providers': [],
                             'max_concurrent_children': 3, 'max_spawn_depth': 1}}
    with open(Path(ARGS.state) / 'config.yaml', 'w') as file: json.dump(config, file)

def run(frame, agent_type):
    global CURRENT
    try:
        request = frame['request']; grant = frame['financeGrant']
        if request.get('provider') != 'openrouter' or grant['modelID'] != request['modelID']:
            raise RuntimeError('This bridge requires the host-bound OpenRouter route')
        # Never resume an opaque process or its pending request after interruption.
        run_path = Path(ARGS.state) / (frame['id'] + '.run.json')
        if run_path.exists(): raise RuntimeError('Existing upstream checkpoint requires explicit native review')
        checkpoint(run_path.name, {'runID': frame['id'], 'phase': 'started', 'engineVersion': HELLO['engineVersion']})
        write_config(request)
        try:
            # One-shot turn: delegation waits for its sub-agents and returns their reports in the same call.
            from gateway.session_context import declare_stateless_channel
            declare_stateless_channel()
        except Exception:
            pass
        live = Live(frame['conversationID'])
        agent = agent_type(model=request['modelID'], provider='custom', base_url='https://aim.invalid/v1',
            api_key='aim-pipe-sentinel', api_mode='chat_completions', quiet_mode=True,
            enabled_toolsets=['delegation'] if DELEGATE_SCHEMA else [], skip_context_files=True, skip_memory=True,
            skip_background_review=True, load_soul_identity=False, save_trajectories=False,
            fallback_model=None, credential_pool=None, checkpoints_enabled=False,
            max_tokens=request.get('anthropicOutputTokens') or 4096,
            reasoning_config=({'enabled': False} if request.get('openAIReasoningEffort') == 'none' else
                              {'effort': request['openAIReasoningEffort']} if request.get('openAIReasoningEffort') else None),
            stream_delta_callback=live.text, reasoning_callback=live.reasoning, tool_progress_callback=live.progress,
            session_id=frame['id'], cwd=ARGS.state)
        CURRENT['agent'] = agent
        try:
            result = agent.run_conversation(request['text'])
        finally:
            live.close()
        if result.get('failed') or result.get('error'): raise RuntimeError('Hermes turn failed: ' + str(result.get('error') or result.get('failed'))[:240])
        answer = result.get('final_response')
        if not isinstance(answer, str): raise RuntimeError('Hermes returned an incompatible result')
        # Streamed text is already on screen: send only what Hermes added after it, or the whole
        # answer when nothing was streamed. The final answer itself is the task's result.
        streamed = live.segment
        missing = answer if not live.streamed else (answer[len(streamed):] if streamed and answer.startswith(streamed) else '')
        if not live.streamed and not missing: missing = answer
        for start in range(0, len(missing), 4096):
            emit({'kind': 'event', 'event': {'textDelta': {'conversationID': frame['conversationID'], 'text': missing[start:start+4096]}}})
        activity('final', text=answer[:600000])
        checkpoint(run_path.name, {'runID': frame['id'], 'phase': 'completed', 'answerSHA256': hashlib.sha256(answer.encode()).hexdigest()})
        emit({'kind': 'event', 'event': {'completed': {'conversationID': frame['conversationID']}}})
    except Exception as error:
        import traceback
        traceback.print_exc(file=sys.stderr)
        # The cause (type and first words, no prompt content) tells the person and AIM what broke.
        cause = (type(error).__name__ + ': ' + str(error))[:300]
        emit({'kind': 'event', 'event': {'failed': {'conversationID': frame['conversationID'], 'diagnostic': {'code': 'hermes.bridge.failed', 'message': 'Hermes stopped: ' + cause, 'isRecoverable': True, 'timestamp': 0, 'details': {'cause': cause}}}}})
    finally:
        for inbox in list(PENDING.values()): inbox.put(None)
        CURRENT = None

def main():
    global ARGS, HELLO, CURRENT
    parser = argparse.ArgumentParser(); parser.add_argument('--upstream', required=True); parser.add_argument('--state', required=True)
    ARGS = parser.parse_args()
    # Preserve the protocol pipe; upstream prints go to stderr, never authority.
    sys.stdout = sys.stderr
    first = sys.stdin.readline(); HELLO = json.loads(first)
    if HELLO['version'] != 2 or HELLO['kind'] != 'hello' or HELLO.get('financeProtocolVersion') != 1 or HELLO.get('providerProtocolVersion') != 1 or HELLO.get('readOnly') is not True:
        raise RuntimeError('This bridge requires confined AIM v2 / finance v1 / provider v1 read-only binding')
    os.environ['HERMES_HOME'] = ARGS.state
    # Only AIM's pipe reaches a model: no inherited keys or proxies, no package installs, no
    # system-wide managed scope, and Hermes does not resend a request AIM already sent.
    for name in ('OPENAI_API_KEY', 'OPENAI_BASE_URL', 'OPENROUTER_API_KEY', 'ANTHROPIC_API_KEY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
                 'http_proxy', 'https_proxy', 'all_proxy'):
        os.environ.pop(name, None)
    os.environ['HERMES_DISABLE_LAZY_INSTALLS'] = '1'
    os.environ['HERMES_STREAM_RETRIES'] = '0'
    # An AIM action may wait for the person's approval: allow it an hour, not Hermes's 7 minutes.
    os.environ['HERMES_CONCURRENT_TOOL_TIMEOUT_S'] = '3600'
    managed = Path(ARGS.state) / 'managed'; managed.mkdir(exist_ok=True)
    os.environ['HERMES_MANAGED_DIR'] = str(managed)
    agent_type = load_hermes()
    emit({'kind': 'hello_ack', 'engineVersion': HELLO['engineVersion'], 'readOnly': True, 'financeProtocolVersion': 1, 'providerProtocolVersion': 1})
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('nonce') != HELLO['nonce'] or frame.get('identity') != HELLO['identity'] or frame.get('version') != 2: raise RuntimeError('Stale AIM host frame')
        if frame['kind'] == 'run':
            if CURRENT: raise RuntimeError('One upstream turn per process')
            CURRENT = dict(frame, sequence=0, cancelled=threading.Event())
            threading.Thread(target=run, args=(frame, agent_type), daemon=True).start()
        elif frame['kind'] in ('provider_response', 'tool_response'):
            if not CURRENT or frame.get('id') != CURRENT['id']: raise RuntimeError('Unknown response owner')
            # AIM writes UUIDs in upper case; this bridge creates them in lower case. Hermes may stop
            # reading a streamed answer at its end marker, before AIM's closing frame: that frame is dropped.
            chunk = frame['providerChunk']; key = chunk['requestID'].lower()
            if key in PENDING: PENDING[key].put(chunk)
            elif key not in CLOSED: raise RuntimeError('AIM response for an unknown request')
        elif frame['kind'] == 'cancel':
            if CURRENT:
                CURRENT['cancelled'].set()
                try: CURRENT.get('agent') and CURRENT['agent'].interrupt('AIM cancel')
                except Exception: pass
            for inbox in list(PENDING.values()): inbox.put(None)
        else: raise RuntimeError('Unsupported host frame')
    if CURRENT: CURRENT['cancelled'].set()
    for inbox in list(PENDING.values()): inbox.put(None)

if __name__ == '__main__': main()
