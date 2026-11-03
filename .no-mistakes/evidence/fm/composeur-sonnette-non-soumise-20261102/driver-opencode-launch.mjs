import {mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
const [binary,home]=process.argv.slice(2);
const env={PATH:process.env.PATH,HOME:home,TERM:'xterm-256color',LANG:'C',GOOGLE_GENERATIVE_AI_API_KEY:process.env.GEMINI_API_KEY,OPENCODE_CONFIG_CONTENT:JSON.stringify({permission:{'*':'allow'},autoupdate:false})};
for(const [name,part] of Object.entries({XDG_CONFIG_HOME:'config',XDG_DATA_HOME:'data',XDG_CACHE_HOME:'cache',XDG_STATE_HOME:'state',XDG_RUNTIME_DIR:'runtime',TMPDIR:'tmp'})){env[name]=join(home,part);mkdirSync(env[name],{recursive:true});}
for(const name of ['TMUX','TMUX_PANE','TMUX_TMPDIR','EDITOR','VISUAL','FM_NATIVE_EDITOR_SNAPSHOT','FM_NATIVE_EDITOR_SEED']) if(process.env[name])env[name]=process.env[name];
const child=spawn(binary,['--model','google/gemini-3.5-flash-lite','--prompt','Reply native-ready. Do not run commands.'],{stdio:'inherit',env});
process.on('SIGINT',()=>{});child.on('exit',code=>process.exit(code??1));
