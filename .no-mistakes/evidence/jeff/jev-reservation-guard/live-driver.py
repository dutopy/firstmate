import os, json, pathlib, subprocess, threading, http.server, time, shutil
ROOT=pathlib.Path.cwd()
W=ROOT/'.local-test'
E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M5YGMKBJR7A39JAP6SB4F46F')
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path':self.path,'body':body})
        response={'model':'disposable-jev','answers':{'rule':{'type':'choice','choice':'rule_1','confidence':0.99,'probabilities':{'rule_1':0.99,'default':0.01}}},'usage':{'input_tokens':1,'output_tokens':1}}
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(response).encode())
    def log_message(self,*a): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
bin=W/'bin'; bin.mkdir(exist_ok=True)
real_curl=shutil.which('curl')
# Only reroute the fixed API URL; execute the installed curl for all HTTP I/O.
(bin/'curl').write_text('#!'+shutil.which('python3')+'\nimport os,sys\na=[x.replace("https://api.typesafe.ai/v1/systemone",'+repr('http://127.0.0.1:'+str(server.server_port)+'/v1/systemone')+') for x in sys.argv[1:]]\nos.execv('+repr(real_curl)+',['+repr(real_curl)+']+a)\n')
quota={'schemaVersion':5,'generatedAt':'2030-01-01T00:00:00Z','providers':[{'provider':'claude','state':{'status':'fresh'},'quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':90,'runway':{'status':'through_reset'},'selection':{'spendPriority':1}}]}}]}
(bin/'quota-axi').write_text('#!/bin/sh\nprintf \'%s\\n\' '+"'"+json.dumps(quota)+"'\n")
for f in bin.iterdir(): f.chmod(0o755)
profile={'harness':'claude','model':'sonnet','provider':'claude'}
rules={'rules':[{'when':'Fix a bug','use':profile}],'default':profile,'classes':{'volume_cheap':profile}}
results=[]
def run(name,record,expected,fragment='',extra=None,args=None,raw=False,ledger_bad=False,allowed=False):
    home=W/name
    if home.exists(): shutil.rmtree(home)
    (home/'data').mkdir(parents=True); (home/'config').mkdir()
    (home/'config/crew-dispatch.json').write_text(json.dumps(rules))
    brief=home/'brief.md'; brief.write_text('Fix the pager off-by-one bug.\n')
    if record is not None: (home/'data/jev-reservation.json').write_text(record if raw else json.dumps(record))
    env=os.environ.copy()
    for key in ['FM_JEV_RESERVATION','FM_JEV_LEDGER','FM_CONFIG_OVERRIDE','FM_ROOT_OVERRIDE','FM_JEV_RESERVATION_MAX_AGE_MIN']:
        env.pop(key,None)
    env.update(FM_HOME=str(home),TMPDIR=str(W/'tmp'),TYPESAFE_API_KEY='disposable-local-key',PATH=str(bin)+os.pathsep+os.environ['PATH'],NO_PROXY='127.0.0.1',no_proxy='127.0.0.1')
    if ledger_bad:
        (home/'regular-file').write_text('not a directory')
        env['FM_JEV_LEDGER']=str(home/'regular-file/calls.tsv')
    if extra: env.update(extra)
    before=len(requests)
    cmd=[str(ROOT/'bin/fm-dispatch-resolve.sh'),str(brief),'--project','isolated-pager']+(args or [])
    p=subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=20)
    ledger=home/'data/jev-calls.tsv'
    ledger_text=ledger.read_text() if ledger.exists() else ''
    sent=requests[before:]
    checks=[p.returncode==0,('status: '+expected) in p.stdout,fragment in p.stdout,len(sent)==(1 if allowed else 0)]
    if args:
        checks += ['class: volume_cheap' in p.stdout,"profile: --harness 'claude' --model 'sonnet'" in p.stdout,not ledger_text]
    elif name=='missing-curl-before-reservation':
        checks += [not ledger_text]
    elif ledger_bad:
        checks += ['cannot write the Jev ledger' in p.stderr]
    else:
        rows=[r.split('\t') for r in ledger_text.splitlines()]
        checks += [len(rows)==1,all(len(r)==4 and r[1]==('allowed' if allowed else 'blocked') for r in rows)]
    if allowed: checks += [sent[0]['body']['state']['task']['brief']==brief.read_text()]
    result={'name':name,'result':'pass' if all(checks) else 'fail','exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'ledger':ledger_text,'http_requests':sent,'checks':checks}
    results.append(result)
    print(name,result['result'])
now=int(time.time()); valid={'task':'T-live','reserved_at':now-30,'cap_usd':0.5}
try:
    no_curl=W/'no-curl'; no_curl.mkdir()
    for command in ['bash','chmod','cp','dirname','jq','mktemp','rm']:
        (no_curl/command).symlink_to(shutil.which(command))
    run('missing-curl-before-reservation',None,'error','curl not installed',extra={'PATH':str(no_curl)})
    run('missing-reservation',None,'error','missing or unreadable')
    for name,changes,reason in [('missing-task',{'task':''},'no task id'),('missing-cap',{'cap_usd':None},'no positive cap_usd'),('zero-cap',{'cap_usd':0},'no positive cap_usd'),('negative-cap',{'cap_usd':-1},'no positive cap_usd'),('missing-timestamp',{'reserved_at':None},'no reserved_at epoch'),('stale-default',{'reserved_at':now-7201},'stale or dated in the future'),('future',{'reserved_at':now+600},'stale or dated in the future'),('twelve-digit-timestamp',{'reserved_at':100000000000},'malformed reserved_at'),('overflow-timestamp',{'reserved_at':9223372036854775808},'malformed reserved_at')]:
        run(name,dict(valid,**changes),'error',reason)
    for name,raw in [('invalid-json','not json'),('empty-json',''),('array-json','[]'),('null-json','null'),('concatenated-invalid',json.dumps(dict(valid,cap_usd=0))+'\n'+json.dumps({'task':'T-other','cap_usd':1})),('concatenated-valid',json.dumps(valid)+'\n'+json.dumps(valid))]:
        run(name,raw,'error','exactly one object',raw=True)
    run('custom-expiry',dict(valid,reserved_at=now-121),'error','stale or dated in the future',extra={'FM_JEV_RESERVATION_MAX_AGE_MIN':'2'})
    run('unwritable-ledger',valid,'error','ledger not writable',ledger_bad=True)
    run('valid-request',valid,'clear',allowed=True)
    run('declared-class-no-reservation',None,'clear',args=['--class','volume_cheap'])
finally:
    server.shutdown(); server.server_close()
    (E/'live-scenarios.json').write_text(json.dumps(results,indent=2)+'\n')
    text=['Real resolver CLI; real curl routed only to disposable localhost HTTP server; synthetic quota command; no paid service or operator data.\n']
    for r in results:
        text += ['=== '+r['name']+' ===\n','exit: '+str(r['exit_code'])+'\n',r['stdout'],'stderr:\n'+r['stderr'],'persisted TSV:\n'+r['ledger'],'HTTP requests: '+json.dumps(r['http_requests'])+'\n']
    (E/'cli-transcript.log').write_text('\n'.join(text))
if any(r['result']!='pass' for r in results): raise SystemExit(1)
