#!/usr/bin/env node
// Live-test fixture: no caller configuration or provider credentials reach the
// TUI except its explicitly selected OpenCode API credential. Never log keys.
import {readFileSync,mkdirSync} from 'node:fs';
import {join,resolve,dirname,delimiter} from 'node:path';
import {spawn} from 'node:child_process';
const [binary,homeArgument,authFile,model,toolPath]=process.argv.slice(2);
if(!binary||!homeArgument||!authFile||!model) process.exit(2);
const home=resolve(homeArgument);
let credential;
try {
  const auth=JSON.parse(readFileSync(authFile,'utf8'));
  credential=auth['opencode-go']??auth.opencode;
  if(credential?.type!=='api'||typeof credential.key!=='string'||!credential.key) throw new Error();
} catch { console.error('OpenCode Go API credential unavailable in the selected auth file'); process.exit(2); }
const env={PATH:toolPath||[dirname(binary),dirname(process.execPath),'/usr/local/bin','/usr/bin','/bin'].join(delimiter),HOME:home,TERM:'xterm-256color',LANG:'C',OPENCODE_API_KEY:credential.key,OPENCODE_CONFIG_CONTENT:'{"permission":{"*":"allow"}}'};
for(const [name,part] of Object.entries({XDG_CONFIG_HOME:'config',XDG_DATA_HOME:'data',XDG_CACHE_HOME:'cache',XDG_STATE_HOME:'state',XDG_RUNTIME_DIR:'runtime',TMPDIR:'tmp'})) {
  env[name]=join(home,part);mkdirSync(env[name],{recursive:true,mode:0o700});
}
for(const name of ['TMUX','TMUX_PANE','EDITOR','VISUAL','FM_NATIVE_EDITOR_SNAPSHOT','FM_NATIVE_EDITOR_SEED']) if(process.env[name]) env[name]=process.env[name];
const child=spawn(binary,['--model',model,'--prompt','Reply native-ready. Do not run commands.'],{stdio:'inherit',env});
process.on('SIGINT',()=>{});
child.on('error',()=>{console.error('OpenCode fixture could not launch the selected binary');process.exitCode=2;});
child.on('exit',(code,signal)=>{process.exitCode=signal?1:(code??1);});
