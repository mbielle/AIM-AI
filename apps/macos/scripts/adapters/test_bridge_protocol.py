#!/usr/bin/env python3
"""Offline contract check. Uses only generated mock upstreams and mock receipts.
No installed Hermes/OpenClaw code, provider endpoint, credential or model runs.
"""
import base64, hashlib, json, os, pathlib, queue, shutil, subprocess, sys, tempfile, threading, uuid
ROOT = pathlib.Path(__file__).parent

def read(process):
    try: line = process.lines.get(timeout=5)
    except queue.Empty: raise AssertionError('Bridge frame timeout')
    if not line: raise AssertionError('Bridge exited: ' + process.stderr.read())
    return json.loads(line)

def send(process, frame):
    process.stdin.write(json.dumps(frame) + '\n'); process.stdin.flush()

def check(engine):
    with tempfile.TemporaryDirectory(prefix='aim-bridge-fixture-') as folder:
        root = pathlib.Path(folder); upstream = root / 'upstream'; state = root / 'state'
        upstream.mkdir(); state.mkdir()
        if engine == 'hermes':
            (upstream / 'httpx.py').write_text('''class HTTPTransport: pass\nclass AsyncHTTPTransport: pass\nclass SyncByteStream: pass\nclass AsyncByteStream: pass\nclass Response:\n def __init__(self,status,headers,content=None,request=None,stream=None): self.content=content if stream is None else b"".join(stream)\n''')
            (upstream / 'model_tools.py').write_text('get_tool_definitions=lambda: []\nhandle_function_call=lambda: None\n')
            (upstream / 'run_agent.py').write_text('''import json, httpx, model_tools
class AIAgent:
 def __init__(self, base_url, api_key, provider, api_mode, skip_memory, skip_background_review, load_soul_identity, max_tokens, reasoning_config, stream_delta_callback=None, reasoning_callback=None, tool_progress_callback=None, **kwargs):
  self.model=kwargs['model']; assert reasoning_config == {'effort':'low'}; self.delta=stream_delta_callback
 def run_conversation(self,text):
  class Req:
   method='POST'; url='https://aim.invalid/v1/chat/completions'
   def read(inner): return json.dumps({'model':self.model,'messages':[{'role':'user','content':text}],'reasoning_effort':'medium'}).encode()
  response=httpx.HTTPTransport().handle_request(Req())
  assert b'choices' in response.content
  tool=model_tools.handle_function_call('read_file', {'path':'fixture.txt'})
  self.delta('fixture:')
  return {'final_response':'fixture:'+json.loads(tool)['result']}
''')
            command = [sys.executable, str(ROOT / 'hermes/aim_hermes_bridge.py'), '--upstream', str(upstream), '--state', str(state)]
            tools = [{'type':'function','function':{'name':'read_file','description':'fixture','parameters':{'type':'object','properties':{'path':{'type':'string'}},'required':['path']}}}]
            # Mock HTTPX is resolved in an isolated fixture directory before any
            # real third-party package import. No network transport exists.
            env = {'PATH':'/usr/bin:/bin', 'HOME':str(state), 'PYTHONPATH':str(upstream), 'PYTHONDONTWRITEBYTECODE':'1'}
        else:
            node = shutil.which('node'); assert node
            (upstream / 'package.json').write_text(json.dumps({'name':'openclaw','version':'fixture'}))
            module = upstream / 'node_modules/@openclaw/ai'; module.mkdir(parents=True)
            (module / 'package.json').write_text(json.dumps({'name':'@openclaw/ai','type':'module','exports':'./index.mjs'}))
            (module / 'index.mjs').write_text('let host={};export const configureAiTransportHost=value=>host=value;export const getAiTransportHost=()=>host;')
            (upstream / 'openclaw.mjs').write_text('''import fs from 'node:fs';import path from 'node:path';import {pathToFileURL} from 'node:url';
const state=process.env.OPENCLAW_STATE_DIR;const config=JSON.parse(fs.readFileSync(process.env.OPENCLAW_CONFIG_PATH));
const tools=[];const plugin=await import(pathToFileURL(path.join(state,'aim-plugin/index.mjs')));plugin.default.register({registerTool:tool=>tools.push(tool)});
const ai=await import('@openclaw/ai');const model=config.models.providers.aim.models[0].id;
const response=await ai.getAiTransportHost().buildModelFetch({baseUrl:'https://aim.invalid/v1'})('https://aim.invalid/v1/chat/completions',{method:'POST',body:JSON.stringify({model,messages:[{role:'user',content:'fixture'}]})});
await response.text(); const tool=await tools[0].execute('original-upstream-id',{path:'fixture.txt'});
console.log(JSON.stringify({payloads:[{text:'fixture:'+tool.content[0].text}]}));process.exit(0);
''')
            command = [node, str(ROOT / 'openclaw/aim_openclaw_bridge.mjs'), '--upstream', str(upstream), '--state', str(state)]
            tools = [{'type':'function','function':{'name':'aim_read_file','description':'fixture','parameters':{'type':'object','properties':{'path':{'type':'string'}},'required':['path']}}}]
            env = {'PATH':'/usr/bin:/bin', 'HOME':str(state)}
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        process.lines = queue.Queue()
        def pump():
            for line in process.stdout: process.lines.put(line)
            process.lines.put('')
        threading.Thread(target=pump, daemon=True).start()
        try:
            nonce=str(uuid.uuid4()); run=str(uuid.uuid4()); convo=str(uuid.uuid4()); grant=str(uuid.uuid4())
            base={'version':2,'nonce':nonce,'identity':'aim.'+engine+'.bridge.v1'}
            send(process,dict(base,kind='hello',engineVersion='fixture+bridge-v1',readOnly=True,financeProtocolVersion=1,providerProtocolVersion=1))
            assert read(process)['kind']=='hello_ack'
            send(process,dict(base,kind='run',id=run,conversationID=convo,readOnly=True,financeGrant={'id':grant,'modelID':'fixture/model'},toolSchemas=base64.b64encode(json.dumps(tools).encode()).decode(),request={'provider':'openrouter','modelID':'fixture/model','text':'fixture','conversationID':convo,'openAIReasoningEffort':'low'}))
            sequence=0; provider=tool=False; streamed=''; final=None
            while True:
                frame=read(process); sequence+=1
                assert frame['sequence']==sequence and frame['id']==run and frame['nonce']==nonce
                if frame['kind']=='provider_request':
                    provider=True; wire=frame['providerRequest']; body=base64.b64decode(wire['body'])
                    assert wire['grantID']==grant and hashlib.sha256(body).hexdigest()==wire['sha256']
                    assert json.loads(body)['model']=='fixture/model'; requestID=wire['requestID']; content=b'{"choices":[]}'
                    if engine == 'hermes':
                        payload = json.loads(body)
                        assert 'reasoning_effort' not in payload and payload['reasoning'] == {'effort':'medium'}
                    kind='provider_response'
                elif frame['kind']=='tool_request':
                    tool=True; call=frame['toolCall']; assert call['jsonArguments']=={'path':'fixture.txt'}
                    assert call['name']==('read_file' if engine=='hermes' else 'aim_read_file'); requestID=call['id']
                    content=json.dumps({'requestID':requestID,'content':'native fixture receipt','isError':False,'metadata':{'fixture':'true'}}).encode(); kind='tool_response'
                elif frame['kind']=='activity':
                    if frame['activity']['kind']=='final': final=frame['activity']['text']
                    continue
                elif frame['kind']=='event':
                    assert 'failed' not in frame['event'], frame
                    if 'textDelta' in frame['event']: streamed+=frame['event']['textDelta']['text']
                    if 'completed' in frame['event']: break
                    continue
                else: raise AssertionError(frame)
                # AIM streams the answer: a first piece, then the rest with the final frame (IDs in upper case).
                pieces=[content[:5],content[5:]] if kind=='provider_response' else [content]
                for index,piece in enumerate(pieces):
                    send(process,dict(base,kind=kind,id=run,conversationID=convo,providerProtocolVersion=1,providerChunk={'version':1,'requestID':requestID.upper(),'index':index,'final':index==len(pieces)-1,'status':200,'contentType':'application/json','bytes':base64.b64encode(piece).decode()}))
            assert provider and tool
            if engine=='hermes':
                assert final=='fixture:native fixture receipt', final
                assert streamed==final, streamed   # streamed prefix + the suffix Hermes added after it
            print(engine+': handshake/provider/native-tool/sequence/checkpoint fixture PASS')
        finally:
            process.stdin.close(); process.wait(timeout=5)
            assert process.returncode==0, process.stderr.read()

check('hermes'); check('openclaw')
