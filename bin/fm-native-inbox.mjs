#!/usr/bin/env node
// Native steering-inbox transport. The inbox move remains the only delivery proof.
// arm <state> <id> <pi|codex|opencode> <cwd> creates a fresh launch generation.
// request <backend> <target> <record> <doorbell> returns 0 accepted, 1 unbound,
// or 2 native transport failed. Unbound callers retain their existing policy.
// codex <config> -- <codex argv...> anchors the native launch and owns notify.
// codex-notify <config> <native JSON> binds ONLY the exact initial launch prompt;
// title-generation and subagent notifications cannot select a different thread.
// retire <state> <id> removes this task's transport files, never a process.
//
// Only tmux currently supplies a verified kernel endpoint binding: socket + pane
// id + pane root PID, with the native actor proven in that root's ancestry.
// Other backends remain unbound, never inferred from cwd or rendered text.
// Pi/OpenCode actors live inside the harness, keep one native session binding,
// and deliver through the API without reading, clearing, or submitting editors.
// Session changes and launch generations invalidate old bindings and requests.
import { randomUUID, createHash } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, unlinkSync, realpathSync, accessSync, constants } from 'node:fs';
import { dirname, basename, join, resolve, delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
const modulePath = fileURLToPath(import.meta.url);
const supported = new Set(['pi', 'codex', 'opencode']);
const pause = ms => new Promise(resolvePause => setTimeout(resolvePause, ms));
const hash = text => createHash('sha256').update(text).digest('hex');
const load = path => { try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; } };
const remove = path => { try { unlinkSync(path); } catch (error) { if (error.code !== 'ENOENT') throw error; } };
function save(path, value) {
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
    renameSync(temporary, path);
  } finally { remove(temporary); }
}
function paths(state, id) {
  if (!/^[A-Za-z0-9._-]+$/.test(id)) throw new Error('invalid native-inbox task id');
  const base = join(realpathSync(state), `${id}.native-inbox.`);
  return Object.fromEntries(['config', 'binding', 'launch', 'request', 'response'].map(key => [key, `${base}${key}.json`]));
}
function metadata(config) {
  try {
    const entries = readFileSync(join(config.state, `${config.id}.meta`), 'utf8').split('\n').filter(line => line.includes('='));
    const meta = {};
    for (const line of entries) {
      const at = line.indexOf('='), key = line.slice(0, at);
      if (Object.hasOwn(meta, key)) return null;
      meta[key] = line.slice(at + 1);
    }
    return meta;
  } catch { return null; }
}
function current(config) {
  if (!config || !supported.has(config.harness)) return false;
  const armed = load(paths(config.state, config.id).config), meta = metadata(config);
  return armed?.generation === config.generation && meta?.harness === config.harness && (meta.backend || 'tmux') === 'tmux';
}
function processStart(pid) {
  try { return execFileSync('ps', ['-p', String(pid), '-o', 'lstart='], { encoding: 'utf8' }).trim(); } catch { return ''; }
}
function descendant(pid, root) {
  for (let depth = 0; depth < 32 && pid > 1; depth++) {
    if (pid === root) return true;
    try { pid = Number(execFileSync('ps', ['-p', String(pid), '-o', 'ppid='], { encoding: 'utf8' }).trim()); } catch { return false; }
  }
  return false;
}
function endpoint(target, socket) {
  try {
    const args = socket ? ['-S', socket] : [];
    const result = execFileSync('tmux', [...args, 'display-message', '-p', '-t', target, '#{socket_path}|#{pane_id}|#{pane_pid}'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim().split('|');
    if (result.length !== 3 || !result[0] || !/^%[0-9]+$/.test(result[1]) || !/^[0-9]+$/.test(result[2])) return null;
    // Bun rejects realpath on Unix sockets (EOPNOTSUPP). Resolve the directory,
    // preserving the socket name returned by this actual tmux server.
    return { socket: join(realpathSync(dirname(result[0])), basename(result[0])), pane: result[1], root: Number(result[2]) };
  } catch { return null; }
}
function sameEndpoint(a, b) { return !!a && !!b && a.socket === b.socket && a.pane === b.pane && a.root === b.root; }
function actorIdentity(config) {
  if (!current(config) || realpathSync(process.cwd()) !== config.cwd || !process.env.TMUX_PANE || !process.env.TMUX) return null;
  const own = endpoint(process.env.TMUX_PANE, process.env.TMUX.split(',')[0]);
  const target = endpoint(metadata(config).window, own?.socket);
  if (!sameEndpoint(own, target) || !descendant(process.pid, own.root)) return null;
  return { ...own, pid: process.pid, started: processStart(process.pid) };
}
function live(binding, config, target) {
  const meta = metadata(config);
  return current(config) && meta?.window === target && binding?.generation === config.generation && binding.harness === config.harness
    && typeof binding.session === 'string' && binding.session.length > 0 && binding.started
    && processStart(binding.pid) === binding.started && descendant(binding.pid, binding.root)
    && sameEndpoint(binding, endpoint(target));
}
export async function arm(state, id, harness, cwd) {
  if (!supported.has(harness)) throw new Error('unsupported native-inbox harness');
  state = realpathSync(state);
  const files = paths(state, id);
  const config = { version: 1, state, id, harness, cwd: realpathSync(cwd), generation: randomUUID() };
  for (const key of ['binding', 'launch', 'request', 'response']) remove(files[key]);
  save(files.config, config);
  return files.config;
}
export function retire(state, id) {
  const files = paths(state, id);
  for (const path of Object.values(files)) remove(path);
}
export async function startNativeInbox({ config: configPath, session, deliver }) {
  const config = load(configPath), identity = config && actorIdentity(config);
  const sessionID = session();
  if (!identity || !sessionID || typeof sessionID !== 'string') return null;
  const files = paths(config.state, config.id);
  const binding = { ...identity, generation: config.generation, harness: config.harness, session: sessionID };
  save(files.binding, binding);
  let running = false, stopped = false;
  const close = () => {
    stopped = true;
    clearInterval(timer);
    const existing = load(files.binding);
    if (existing?.generation === binding.generation && existing?.session === sessionID && existing?.pid === binding.pid) remove(files.binding);
  };
  const tick = async () => {
    if (running || stopped) return;
    if (!current(config) || session() !== sessionID) { close(); return; }
    const request = load(files.request);
    if (!request || request.generation !== binding.generation || request.session !== sessionID) return;
    running = true;
    try {
      if (!live(binding, config, request.target) || !validRecord(config, request.record) || typeof request.text !== 'string') throw new Error('native request lost its binding');
      // No await between the session check and invoking the harness API.
      if (session() !== sessionID) throw new Error('native session changed');
      await deliver(request.text);
      save(files.response, { nonce: request.nonce, accepted: true });
    } catch (error) {
      save(files.response, { nonce: request.nonce, accepted: false, error: String(error) });
    } finally {
      if (load(files.request)?.nonce === request.nonce) remove(files.request);
      running = false;
    }
  };
  const timer = setInterval(() => { void tick(); }, 200);
  timer.unref();
  return { close };
}
export function installPiNativeInbox(pi, config) {
  let actor = null;
  pi.on('session_start', async (_event, ctx) => {
    actor?.close();
    actor = await startNativeInbox({
      config,
      session: () => ctx.sessionManager.getSessionId(),
      deliver: text => pi.sendUserMessage(text, { deliverAs: 'followUp' }),
    });
  });
  pi.on('session_shutdown', () => { actor?.close(); actor = null; });
}
export function openCodeNativeInbox(client, config) {
  let actor = null, active = '';
  const close = () => { actor?.close(); actor = null; active = ''; };
  return {
    message: async ({ sessionID }) => {
      if (active === sessionID) return;
      const response = await client.session.get({ path: { id: sessionID } });
      const info = response.data;
      const settings = load(config);
      if (!settings || info?.id !== sessionID || info.parentID || realpathSync(info.directory) !== settings.cwd) return;
      close();
      active = sessionID;
      actor = await startNativeInbox({
        config,
        session: () => active,
        deliver: text => client.session.promptAsync({ path: { id: sessionID }, body: { parts: [{ type: 'text', text }] } }),
      });
    },
    event: event => {
      if ((event.type === 'tui.session.select' && event.properties.sessionID !== active)
          || (event.type === 'session.deleted' && event.properties.info.id === active)
          || event.type === 'server.instance.disposed') close();
    },
  };
}

function validRecord(config, record) {
  try {
    return /^[0-9]+\.msg$/.test(basename(record)) && dirname(realpathSync(record)) === realpathSync(join(config.state, `${config.id}.inbox`));
  } catch { return false; }
}
export async function request(backend, target, record, text) {
  if (backend !== 'tmux' || !/\.inbox$/.test(dirname(record))) return 1;
  const state = dirname(dirname(record)), id = basename(dirname(record)).slice(0, -6), files = paths(state, id);
  const config = load(files.config), binding = load(files.binding);
  if (!config || !validRecord(config, record) || !live(binding, config, target)) return 1;
  if (config.harness === 'codex') {
    const launch = load(files.launch);
    if (!launch || launch.pid !== binding.pid || launch.promptHash !== binding.promptHash || !sameEndpoint(launch, binding)) return 1;
    try {
      await run(launch.command, ['queue', '--thread', binding.session, '--message', text], { cwd: config.cwd, env: { ...process.env, CODEX_HOME: launch.codexHome }, timeout: 15000 });
      return 0;
    } catch (error) { console.error(`native codex queue failed: ${error.message}`); return 2; }
  }
  const nonce = randomUUID();
  save(files.request, { generation: config.generation, session: binding.session, nonce, target, record: realpathSync(record), text });
  for (let attempt = 0; attempt < 100; attempt++) {
    const response = load(files.response);
    if (response?.nonce === nonce) return response.accepted ? 0 : 2;
    if (!live(binding, config, target)) return 1;
    await pause(50);
  }
  return 2;
}
function executable(command) {
  for (const directory of (process.env.PATH || '').split(delimiter)) {
    const path = resolve(directory, command);
    try { accessSync(path, constants.X_OK); return path; } catch { /* try the next PATH entry */ }
  }
  throw new Error(`native executable absent: ${command}`);
}
export async function prepareCodexLaunch(configPath, prompt, command = 'codex') {
  const config = load(configPath), identity = config && actorIdentity(config);
  if (!identity || config.harness !== 'codex') return null;
  const launch = { ...identity, generation: config.generation, promptHash: hash(prompt), command: executable(command), codexHome: resolve(process.env.CODEX_HOME || join(process.env.HOME, '.codex')) };
  save(paths(config.state, config.id).launch, launch);
  return launch;
}
export async function notifyCodex(configPath, event) {
  const config = load(configPath);
  if (!config || config.harness !== 'codex' || !current(config)) return false;
  const files = paths(config.state, config.id), launch = load(files.launch);
  if (!launch || launch.generation !== config.generation || processStart(launch.pid) !== launch.started || !descendant(process.ppid, launch.pid)
      || !sameEndpoint(launch, endpoint(metadata(config).window, launch.socket))) return false;
  if (event.type !== 'agent-turn-complete' || event.client !== 'codex-tui' || event.cwd !== config.cwd
      || !Array.isArray(event['input-messages']) || typeof event['input-messages'][0] !== 'string'
      || hash(event['input-messages'][0]) !== launch.promptHash || !/^[0-9a-f-]{36}$/.test(event['thread-id'] || '')) return false;
  const previous = load(files.binding);
  if (launch.ambiguous || (previous && previous.session !== event['thread-id'])) {
    save(files.launch, { ...launch, ambiguous: true });
    remove(files.binding);
    return false;
  }
  save(files.binding, { ...launch, harness: 'codex', session: event['thread-id'] });
  writeFileSync(join(config.state, `${config.id}.turn-ended`), '');
  return true;
}
async function launchCodex(configPath, args) {
  const prompt = args.at(-1);
  const launch = await prepareCodexLaunch(configPath, prompt, args[0]);
  const config = load(configPath);
  // An unsupported backend retains its existing terminal transport and notify.
  const notify = launch ? [process.execPath, modulePath, 'codex-notify', configPath] : ['touch', join(config.state, `${config.id}.turn-ended`)];
  const child = spawn(args[0], ['-c', `notify=${JSON.stringify(notify)}`, ...args.slice(1)], { stdio: 'inherit' });
  process.on('SIGINT', () => { /* the foreground process group also receives SIGINT */ });
  child.on('error', error => { console.error(error.message); process.exitCode = 1; });
  child.on('exit', (code, signal) => {
    const files = paths(config.state, config.id);
    if (load(files.launch)?.pid === process.pid) { remove(files.binding); remove(files.launch); }
    process.exitCode = signal ? 1 : (code ?? 1);
  });
}
async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === 'arm') { console.log(await arm(...args)); return; }
  if (command === 'retire') { retire(...args); return; }
  if (command === 'request') { process.exitCode = await request(...args); return; }
  if (command === 'codex-notify') { process.exitCode = await notifyCodex(args[0], JSON.parse(args[1])) ? 0 : 1; return; }
  if (command === 'codex' && args[1] === '--') { await launchCodex(args[0], args.slice(2)); return; }
  throw new Error('usage: fm-native-inbox.mjs arm|request|codex|codex-notify|retire (see header)');
}
if (process.argv[1] && resolve(process.argv[1]) === modulePath) {
  main().catch(error => { console.error(`native inbox: ${error.message}`); process.exitCode = 1; });
}
