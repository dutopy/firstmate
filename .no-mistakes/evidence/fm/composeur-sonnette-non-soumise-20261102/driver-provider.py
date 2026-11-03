import os,json,urllib.request,uuid,time,threading
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path
LAB=Path(__file__).parent
lock=threading.Lock()
last_call=0
calls={}
class Server(BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_POST(self):
  req=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  (LAB/'last-request.json').write_text(json.dumps(req))
  messages=[]
  if req.get('instructions'): messages.append({'role':'system','content':req['instructions']})
  for item in req.get('input',[]):
   typ=item.get('type','message')
   if typ=='message':
    content=item.get('content','')
    if isinstance(content,list):content='\n'.join(p.get('text','') for p in content)
    messages.append({'role':'system' if item['role']=='developer' else item['role'],'content':content})
   elif typ=='function_call':messages.append({'role':'assistant','tool_calls':[calls.get(item['call_id'],{'id':item['call_id'],'type':'function','function':{'name':item['name'],'arguments':item['arguments']}})]})
   elif typ=='function_call_output':messages.append({'role':'tool','tool_call_id':item['call_id'],'content':str(item['output'])})
  tools=[]
  for t in req.get('tools',[]):
   if t['type']=='function':tools.append({'type':'function','function':{k:v for k,v in t.items() if k in ['name','description','parameters']}})
  data={'model':'gemini-3.5-flash-lite','messages':messages,'max_tokens':4096}
  if tools:data['tools']=tools
  try:
   with lock:
    global last_call
    time.sleep(max(0,13-(time.time()-last_call)))
    last_call=time.time()
   r=urllib.request.Request('https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',data=json.dumps(data).encode(),headers={'Authorization':'Bearer '+os.environ['GEMINI_API_KEY'],'Content-Type':'application/json'})
   answer=json.load(urllib.request.urlopen(r,timeout=120))['choices'][0]['message']
  except Exception as e:
   self.send_response(502);self.end_headers();self.wfile.write(str(e).encode());return
  for call in answer.get('tool_calls',[]): calls[call['id']]=call
  rid='resp_'+uuid.uuid4().hex; output=[]
  for call in answer.get('tool_calls',[]):output.append({'type':'function_call','id':'fc_'+uuid.uuid4().hex,'call_id':call['id'],'name':call['function']['name'],'arguments':call['function']['arguments'],'status':'completed'})
  if answer.get('content'):output.append({'type':'message','id':'msg_'+uuid.uuid4().hex,'role':'assistant','status':'completed','content':[{'type':'output_text','text':answer['content'],'annotations':[]}]})
  base={'id':rid,'object':'response','created_at':int(time.time()),'model':req['model'],'status':'in_progress','output':[]}
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  def emit(typ,**kw): self.wfile.write(('event: '+typ+'\ndata: '+json.dumps({'type':typ,**kw})+'\n\n').encode());self.wfile.flush()
  emit('response.created',response=base)
  for i,item in enumerate(output):
   emit('response.output_item.added',output_index=i,item={**item,'status':'in_progress',**({'arguments':''} if item['type']=='function_call' else {'content':[]})})
   if item['type']=='function_call':
    emit('response.function_call_arguments.delta',item_id=item['id'],output_index=i,delta=item['arguments'])
    emit('response.function_call_arguments.done',item_id=item['id'],output_index=i,arguments=item['arguments'])
   else:
    emit('response.content_part.added',item_id=item['id'],output_index=i,content_index=0,part={'type':'output_text','text':'','annotations':[]})
    emit('response.output_text.delta',item_id=item['id'],output_index=i,content_index=0,delta=item['content'][0]['text'])
    emit('response.output_text.done',item_id=item['id'],output_index=i,content_index=0,text=item['content'][0]['text'])
    emit('response.content_part.done',item_id=item['id'],output_index=i,content_index=0,part=item['content'][0])
   emit('response.output_item.done',output_index=i,item=item)
  emit('response.completed',response={**base,'status':'completed','output':output,'usage':{'input_tokens':0,'output_tokens':0,'total_tokens':0}})
ThreadingHTTPServer(('127.0.0.1',18764),Server).serve_forever()
