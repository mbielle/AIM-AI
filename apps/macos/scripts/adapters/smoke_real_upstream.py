#!/usr/bin/env python3
"""Runs a real installed Hermes/OpenClaw through its AIM bridge against a fake AIM host that
answers model requests with a canned streamed completion (no network, no paid call).
Checks: handshake, streamed text reaching AIM before the end, final answer, model scope.
Usage: smoke_real_upstream.py hermes|openclaw <version dir> [bridge dir] [--delegate]
--delegate: the fake model makes the main agent start one sub-agent; checks its lifecycle."""
import base64, hashlib, json, os, pathlib, queue, subprocess, sys, tempfile, threading, time, uuid
engine, version = sys.argv[1], pathlib.Path(sys.argv[2])
delegate = '--delegate' in sys.argv
args = [a for a in sys.argv[1:] if a != '--delegate']
bridges = pathlib.Path(args[2]) if len(args) > 2 else pathlib.Path(__file__).parent / engine
state = pathlib.Path(tempfile.mkdtemp(prefix='aim-smoke-'))
if engine == 'hermes':
    command = [str(version / '.venv/bin/python'), str(bridges / 'aim_hermes_bridge.py'), '--upstream', str(version / 'upstream'), '--state', str(state)]
else:
    node = next((version / 'tools').glob('node-*/bin/node'))
    command = [str(node), str(bridges / 'aim_openclaw_bridge.mjs'), '--upstream', str(version / 'upstream/node_modules/openclaw'), '--state', str(state)]
env = {'PATH': '/usr/bin:/bin', 'HOME': str(state), 'PYTHONNOUSERSITE': '1', 'PYTHONDONTWRITEBYTECODE': '1'}
process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
lines = queue.Queue()
threading.Thread(target=lambda: [lines.put(l) for l in process.stdout] + [lines.put('')], daemon=True).start()
def read(timeout=120):
    line = lines.get(timeout=timeout)
    if not line: raise SystemExit('bridge exited: ' + process.stderr.read()[-3000:])
    return json.loads(line)
def send(frame): process.stdin.write(json.dumps(frame) + '\n'); process.stdin.flush()
nonce, run, convo, grant = (str(uuid.uuid4()) for _ in range(4))
base = {'version': 2, 'nonce': nonce, 'identity': 'aim.' + engine + '.bridge.v1'}
send(dict(base, kind='hello', engineVersion='smoke', readOnly=True, financeProtocolVersion=1, providerProtocolVersion=1))
assert read()['kind'] == 'hello_ack'
send(dict(base, kind='run', id=run, conversationID=convo, readOnly=True, financeGrant={'id': grant, 'modelID': 'fixture/model'},
          toolSchemas=base64.b64encode(b'[]').decode(),
          request={'provider': 'openrouter', 'modelID': 'fixture/model', 'text': 'Say hello.', 'conversationID': convo, 'contextLength': 200000}))
def call_sse(name, arguments):
    chunk = {'id': 'smoke', 'object': 'chat.completion.chunk', 'created': 1, 'model': 'fixture/model',
             'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': None, 'tool_calls': [{'index': 0, 'id': 'call_' + uuid.uuid4().hex[:8], 'type': 'function',
                          'function': {'name': name, 'arguments': json.dumps(arguments)}}]}, 'finish_reason': None}]}
    end = {'id': 'smoke', 'object': 'chat.completion.chunk', 'created': 1, 'model': 'fixture/model',
           'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}], 'usage': {'prompt_tokens': 10, 'completion_tokens': 2, 'total_tokens': 12}}
    return ('data: ' + json.dumps(chunk) + '\n\ndata: ' + json.dumps(end) + '\n\ndata: [DONE]\n\n').encode()
activities = []
def script(body):
    """The fake model's answer for this request."""
    names = {t.get('function', {}).get('name') for t in body.get('tools') or []}
    spawn = 'delegate_task' if 'delegate_task' in names else 'sessions_spawn' if 'sessions_spawn' in names else None
    roles = [m.get('role') for m in body.get('messages', [])]
    if not delegate: return [sse('Bon'), sse('jour'), sse('', final=True)]
    if spawn and 'tool' not in roles:
        args = {'tasks': [{'goal': 'Find the answer to 6 times 7.'}]} if spawn == 'delegate_task' else {'task': 'Find the answer to 6 times 7.', 'label': 'multiplier'}
        return [call_sse(spawn, args)]
    if not spawn and 'sessions_yield' not in names:
        return [sse('Child report: '), sse('42.'), sse('', final=True)]
    if 'sessions_yield' in names and roles.count('tool') == 1:
        return [call_sse('sessions_yield', {})]
    return [sse('Bon'), sse('jour'), sse('', final=True)]
def sse(text, final=False):
    chunk = {'id': 'smoke', 'object': 'chat.completion.chunk', 'created': 1, 'model': 'fixture/model',
             'choices': [{'index': 0, 'delta': {} if final else {'role': 'assistant', 'content': text}, 'finish_reason': 'stop' if final else None}]}
    if final: chunk['usage'] = {'prompt_tokens': 10, 'completion_tokens': 2, 'total_tokens': 12}
    return ('data: ' + json.dumps(chunk) + '\n\n' + ('data: [DONE]\n\n' if final else '')).encode()
streamed, final, models, before_end = '', None, set(), None
live_before_end = None
start = time.time()
while time.time() - start < 180:
    frame = read()
    if frame['kind'] == 'provider_request':
        body = json.loads(base64.b64decode(frame['providerRequest']['body'])); models.add(body.get('model'))
        rid = frame['providerRequest']['requestID'].upper()
        # Like AIM: the streamed pieces, then a separate empty closing frame.
        pieces = script(body) + [b'']
        for index, piece in enumerate(pieces):
            if index == 2 and not delegate:
                # Before closing the answer, let the first words come back: proof of live streaming.
                deadline = time.time() + 5
                while time.time() < deadline and not streamed:
                    try: pending = lines.get(timeout=0.2)
                    except queue.Empty: continue
                    if not pending: break
                    early = json.loads(pending)
                    if early.get('kind') == 'event' and 'textDelta' in early['event']: streamed += early['event']['textDelta']['text']
                live_before_end = bool(streamed)
            send(dict(base, kind='provider_response', id=run, conversationID=convo, providerProtocolVersion=1,
                      providerChunk={'version': 1, 'requestID': rid, 'index': index, 'final': index == len(pieces) - 1, 'status': 200,
                                     'contentType': 'text/event-stream', 'bytes': base64.b64encode(piece).decode()}))
            time.sleep(0.3)
    elif frame['kind'] == 'activity':
        activities.append(frame['activity'])
        if frame['activity']['kind'] == 'final': final = frame['activity'].get('text')
    elif frame['kind'] == 'event':
        event = frame['event']
        if 'textDelta' in event:
            streamed += event['textDelta']['text']
            if before_end is None: before_end = streamed
        if 'failed' in event: raise SystemExit('failed: ' + json.dumps(event) + '\n' + process.stderr.read()[-3000:] if False else 'failed: ' + json.dumps(event))
        if 'completed' in event: break
process.stdin.close(); process.wait(timeout=20)
print(json.dumps({'engine': engine, 'streamed': streamed, 'live_before_end': live_before_end, 'final': final, 'models': sorted(models),
                  'activities': [{k: (v[:80] if isinstance(v, str) and a.get('kind') != 'toolFinished' else v) for k, v in a.items()} for a in activities]}, ensure_ascii=False))
if delegate:
    kinds = [a['kind'] for a in activities]
    assert 'subagentStarted' in kinds and 'subagentFinished' in kinds and 'toolStarted' in kinds, kinds
assert final and 'Bonjour' in final, final
assert models == {'fixture/model'}, models
