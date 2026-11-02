from http.server import HTTPServer, BaseHTTPRequestHandler
import json,pathlib
base=pathlib.Path.cwd()/'.local-test'
class H(BaseHTTPRequestHandler):
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  with (base/'received.jsonl').open('a') as f: f.write(json.dumps(body)+'\n')
  self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
  for data in [{'id':'local','object':'chat.completion.chunk','choices':[{'index':0,'delta':{'role':'assistant','content':'Doorbell received by disposable pane.'},'finish_reason':None}]},{'id':'local','object':'chat.completion.chunk','choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}]:
   self.wfile.write(('data: '+json.dumps(data)+'\n\n').encode())
  self.wfile.write(b'data: [DONE]\n\n')
 def log_message(self,*args): pass
server=HTTPServer(('127.0.0.1',0),H); (base/'model-port').write_text(str(server.server_port)); (base/'model-pid').write_text(str(__import__('os').getpid())); server.serve_forever()
