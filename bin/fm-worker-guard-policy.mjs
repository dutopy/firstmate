#!/usr/bin/env node
// Destructive-command policy for Firstmate-launched task workers.
//
// Decision owner for bin/fm-worker-guard-pretool-check.sh; docs/worker-guard.md
// owns the contract, the false-positive catalogue, and the enforcement limits.
// The policy only READS: it lexes the submitted command with the shared shell
// lexer owned by bin/fm-arm-command-policy.mjs, resolves paths, and inspects
// process facts with `ps`/`lsof`. It never executes, sources, or expands any
// byte of the submitted command or script.
//
// A worker may:
//   - kill a literal PID whose ancestry reaches this worker's agent process or
//     whose current working directory is inside the worker's own copy;
//   - kill its own job (`$!`, `%N`, `$$`);
//   - `rm -r` paths that resolve inside its own copy (or an extra task root).
// A worker may not:
//   - run pkill/killall/fuser -k/xargs kill, or kill a PID it cannot prove;
//   - `rm -r` outside its copy, or through an unresolvable expansion;
//   - reach either primitive through bash -c, eval, a script, a heredoc, or an
//     interpreter's inline code (python, node, ruby, perl, ...).
import path from "node:path";
import { execFileSync } from "node:child_process";
import { accessSync, appendFileSync, constants as fsConstants, readFileSync, realpathSync, readlinkSync, statSync, lstatSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

const extraSystemPrefixes = (process.env.FM_WORKER_GUARD_SYSTEM_PREFIXES || "").split(":").filter(Boolean).map((p) => (p.endsWith("/") ? p : `${p}/`));
const SYSTEM_PREFIXES = ["/usr/", "/bin/", "/sbin/", "/opt/", "/etc/", "/Library/", "/System/", "/Applications/", "/nix/", "/snap/", ...extraSystemPrefixes];
const MAX_DEPTH = 10;
const MAX_SCRIPT_BYTES = 1024 * 1024;
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh", "ash", "fish", "csh", "tcsh", "pwsh", "powershell"]);
const INTERPRETER_NAME = /^(?:python[0-9.]*|pypy[0-9.]*|node(?:js)?|bun|deno|tsx|ts-node|ruby[0-9.]*|perl[0-9.]*|php[0-9.]*|lua[0-9.]*|luajit|osascript|n?awk|gawk|mawk|tclsh[0-9.]*|expect|Rscript|julia|groovy|jshell|swift)$/;
const isInterpreter = (name) => INTERPRETER_NAME.test(name);
const KEYWORDS_PREFIX = new Set(["if", "then", "else", "elif", "while", "until", "do", "!", "time", "{", "}"]);
const KEYWORDS_SKIP = new Set(["fi", "done", "esac", "for", "case", "select", "in"]);
const DANGER_RAW = /(?:pkill|killall|\bkill\b|\brm\b|xargs|-delete|unlink|rmtree|rimraf|rm_rf|rmSync|os\.kill|process\.kill|fuser|tmux|herdr|launchctl)/;

export class Deny extends Error {
  constructor(code, reason) {
    super(reason);
    this.code = code;
  }
}

const HINT = "Allowed: kill a literal PID you started yourself (its cwd or ancestry is proven to be yours), and rm -r on paths inside your own copy. For anything else append `blocked: <what you need stopped or removed>` to your status file and let firstmate act.";

function deny(code, detail) {
  throw new Deny(code, `worker-guard [${code}]: ${detail}. ${HINT}`);
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function isDynamicText(value) {
  return /\$|`|\{[^}]*\}|%[sdr]|\bformat\(|\+\s*\w/.test(value);
}

// ---------------------------------------------------------------- paths

class Roots {
  constructor(root, extraRoots, home) {
    this.real = [];
    for (const r of [root, ...extraRoots]) {
      if (!r) continue;
      try {
        this.real.push(realpathSync(r));
      } catch {
        this.real.push(path.resolve(r));
      }
    }
    this.primary = this.real[0];
    this.home = home;
  }

  // Deepest existing ancestor resolved through symlinks, plus the unresolved tail.
  physical(absolute) {
    let current = path.resolve(absolute);
    const tail = [];
    for (;;) {
      try {
        return path.join(realpathSync(current), ...tail.reverse());
      } catch {
        const parent = path.dirname(current);
        if (parent === current) return path.resolve(absolute);
        tail.push(path.basename(current));
        current = parent;
      }
    }
  }

  // rm removes a trailing symlink itself, not what it points at.
  physicalForDelete(absolute, trailingSlash) {
    if (trailingSlash) return this.physical(absolute);
    let isLink = false;
    try {
      isLink = lstatSync(absolute).isSymbolicLink();
    } catch {}
    if (!isLink) return this.physical(absolute);
    return path.join(this.physical(path.dirname(absolute)), path.basename(absolute));
  }

  contains(physicalPath) {
    return this.real.some((r) => physicalPath === r || physicalPath.startsWith(r.endsWith("/") ? r : `${r}/`));
  }

  isPrimaryRoot(physicalPath) {
    return physicalPath === this.primary || this.real.includes(physicalPath);
  }
}

// ---------------------------------------------------------------- processes

let tableCache = null;
function processTable() {
  if (tableCache) return tableCache;
  const table = new Map();
  try {
    const out = execFileSync("ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    for (const line of out.split("\n")) {
      const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
      if (m) table.set(Number(m[1]), { ppid: Number(m[2]), comm: m[3] });
    }
  } catch {}
  tableCache = table;
  return table;
}

function ancestors(pid) {
  const table = processTable();
  const chain = [];
  let current = pid;
  for (let i = 0; i < 64 && table.has(current); i += 1) {
    current = table.get(current).ppid;
    if (!current || chain.includes(current)) break;
    chain.push(current);
  }
  return chain;
}

function resolveOwnerPid(spec) {
  if (spec === "" || spec === undefined || spec === null) return null;
  if (spec !== "auto") return Number(spec) || null;
  const table = processTable();
  for (const pid of ancestors(process.pid)) {
    const entry = table.get(pid);
    if (entry && /(^|\/)(claude|omp)$/.test(entry.comm)) return pid;
  }
  return null;
}

function processCwd(pid) {
  try {
    return readlinkSync(`/proc/${pid}/cwd`);
  } catch {}
  try {
    const out = execFileSync("lsof", ["-a", "-d", "cwd", "-Fn", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const line = out.split("\n").find((l) => l.startsWith("n"));
    return line ? line.slice(1) : "";
  } catch {
    return "";
  }
}

// The argument vector of a live process: the kernel's NUL-separated list where
// it exists, otherwise `ps`, whose whitespace splitting can only make a path
// look wrong (which is refused), never right.
function processArgv(pid) {
  try {
    const raw = readFileSync(`/proc/${pid}/cmdline`, "utf8");
    if (raw) return raw.split("\0").filter((a, index, all) => a !== "" || index < all.length - 1);
  } catch {}
  try {
    const text = execFileSync("ps", ["-ww", "-o", "command=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    return text ? text.split(/\s+/) : [];
  } catch {
    return [];
  }
}

function processUid(pid) {
  try {
    const text = execFileSync("ps", ["-o", "uid=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    return /^\d+$/.test(text) ? Number(text) : null;
  } catch {
    return null;
  }
}

const ARGUMENT_TRUSTED_PREFIXES = ["/usr/", "/bin/", "/sbin/", "/opt/", "/etc/", "/System/", "/Library/", "/dev/", "/nix/", "/snap/"];

// A command line is coherent with ownership when no path-shaped argument
// points outside the worker's copy: the executable itself (argv[0]) may live
// anywhere, but every later path argument must resolve, physically and
// relative to the process's own cwd, inside the copy, a task root, or a system
// location. Anything else means the process works on someone else's tree.
function commandlineProblem(argv, cwd, ctx) {
  for (const arg of argv.slice(1)) {
    let value = arg;
    const eq = arg.match(/^--?[A-Za-z0-9_-]+=(.*)$/s);
    if (arg.startsWith("-")) {
      if (!eq) continue;
      value = eq[1];
    }
    if (!value || /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(value)) continue;
    if (!/[/\\]|^\.|^~/.test(value)) continue;
    const expanded = expandTilde(value, ctx.roots);
    const abs = path.isAbsolute(expanded) ? expanded : path.join(cwd, expanded);
    const physical = ctx.roots.physical(abs);
    if (ctx.roots.contains(physical)) continue;
    if (ARGUMENT_TRUSTED_PREFIXES.some((prefix) => physical.startsWith(prefix))) continue;
    return `its command line names ${JSON.stringify(value)}, which resolves to ${physical}, outside your isolated copy`;
  }
  return "";
}

// Returns null when the PID is proven owned (or provably gone), else the
// reason. Ownership is a JOINT proof, all of it required: the PID is a live
// process of this user, its physical cwd is inside the worker's copy, and its
// command line is coherent with that (no path argument reaching outside).
// Ancestry alone and a shared cwd alone are not proof, and anything unreadable
// or contradictory is refused.
function ownershipProblem(pid, ctx) {
  if (pid <= 1) return `PID ${pid} is a system or process-group target`;
  // "Dead" is decided by the kernel, never by a process listing that may be
  // empty or unparsable: only ESRCH proves the PID is gone.
  try {
    process.kill(pid, 0);
  } catch (error) {
    if (error?.code === "ESRCH") return null;
  }
  const self = ctx.ownerPid;
  if (self && (pid === self || ancestors(self).includes(pid))) return `PID ${pid} is this worker's own agent or its supervisor chain`;
  const argv = processArgv(pid);
  const shown = argv.join(" ").slice(0, 120) || "unknown";
  const uid = processUid(pid);
  if (uid === null || (typeof process.getuid === "function" && uid !== process.getuid())) {
    return `PID ${pid} is not provably a process of your own user (uid=${uid ?? "unknown"}, command=${shown})`;
  }
  const cwd = processCwd(pid);
  if (!cwd) return `PID ${pid} has an unreadable working directory, so ownership is unproven (command=${shown})`;
  const physicalCwd = ctx.roots.physical(cwd);
  if (!ctx.roots.contains(physicalCwd)) return `PID ${pid} is not proven yours: its cwd ${physicalCwd} is outside your isolated copy (command=${shown})`;
  if (argv.length === 0) return `PID ${pid} has an unreadable command line, so ownership is unproven (cwd=${physicalCwd})`;
  const contradiction = commandlineProblem(argv, physicalCwd, ctx);
  if (contradiction) return `PID ${pid} is not proven yours: its cwd is inside your copy but ${contradiction} (command=${shown})`;
  return null;
}

// ---------------------------------------------------------------- state

function cloneState(st) {
  return { ...st, vars: new Map(st.vars), ownPids: new Set(st.ownPids), aliases: new Map(st.aliases), functions: new Set(st.functions), vfiles: st.vfiles };
}

function lexWords(text) {
  const lexed = new Lexer(text).tokenize();
  if (lexed.error) return null;
  return lexed.tokens.filter((t) => t.type === "word");
}

// Value of a word when it can be proven without running anything, else null.
function wordValue(word, st) {
  if (word.subs.length > 0 || word.value.includes("\u0001")) return null;
  if (word.literal) return word.value;
  let unresolved = false;
  const value = word.value.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (whole, name) => {
    if (st.vars.has(name)) return st.vars.get(name);
    unresolved = true;
    return whole;
  });
  if (unresolved || /[$`]/.test(value)) return null;
  return value;
}

function expandTilde(value, roots) {
  if (value === "~") return roots.home;
  if (value.startsWith("~/")) return path.join(roots.home, value.slice(2));
  return value;
}

// ---------------------------------------------------------------- rm / find

function checkDeleteTarget(rawValue, st, ctx, label, allowRoot = false) {
  let value = expandTilde(rawValue, ctx.roots);
  if (/\{[^}]*\}/.test(value)) {
    const brace = value.match(/\{([^{}]*)\}/);
    if (brace && brace[1].includes(",") && !brace[1].includes("..")) {
      for (const alt of brace[1].split(",")) checkDeleteTarget(value.replace(brace[0], alt), st, ctx, label);
      return;
    }
    deny("RM_UNPROVABLE", `${label} target ${JSON.stringify(rawValue)} contains an expansion that cannot be resolved without running it`);
  }
  const globAt = value.search(/[*?[]/);
  let prefix = value;
  if (globAt !== -1) {
    const slash = value.lastIndexOf("/", globAt);
    prefix = slash === -1 ? "" : value.slice(0, slash + 1);
    const rest = value.slice(slash + 1);
    if (/(^|\/)\.\.(\/|$)/.test(rest) || /(^|\/)\.[*?[]/.test(rest)) {
      deny("RM_DOTGLOB", `${label} target ${JSON.stringify(rawValue)} can match "." or ".." entries`);
    }
    if (prefix === "") prefix = "./";
  }
  if (!path.isAbsolute(prefix)) {
    if (!st.cwd) deny("RM_UNPROVABLE", `${label} target ${JSON.stringify(rawValue)} is relative to a working directory that cannot be resolved`);
    prefix = path.join(st.cwd, prefix);
  }
  const trailing = /\/$/.test(value) || globAt !== -1;
  const physical = ctx.roots.physicalForDelete(prefix, trailing);
  if (!ctx.roots.contains(physical)) {
    deny("RM_OUTSIDE", `${label} target ${JSON.stringify(rawValue)} resolves to ${physical}, outside your isolated copy`);
  }
  if (globAt === -1 && !allowRoot && ctx.roots.isPrimaryRoot(physical)) {
    deny("RM_ROOT", `${label} target ${JSON.stringify(rawValue)} is the root of your isolated copy itself`);
  }
}

function recursiveFlag(args) {
  let end = false;
  let recursive = false;
  let noPreserve = false;
  const targets = [];
  for (const word of args) {
    const v = word.value;
    if (!end && v === "--") {
      end = true;
      continue;
    }
    if (!end && v.startsWith("--")) {
      if (v === "--recursive") recursive = true;
      if (v === "--no-preserve-root") noPreserve = true;
      continue;
    }
    if (!end && /^-[A-Za-z]+$/.test(v)) {
      if (/[rR]/.test(v)) recursive = true;
      continue;
    }
    targets.push(word);
  }
  return { recursive, noPreserve, targets };
}

function checkRm(args, st, ctx, label = "rm") {
  const { recursive, noPreserve, targets } = recursiveFlag(args);
  if (noPreserve) deny("RM_OUTSIDE", "rm --no-preserve-root is never allowed");
  if (!recursive) return;
  if (targets.length === 0 && ctx.embedded) deny("RM_UNPROVABLE", "recursive rm without targets inside embedded code cannot be resolved");
  for (const word of targets) {
    const value = wordValue(word, st);
    if (value === null) deny("RM_UNPROVABLE", `${label} -r target ${JSON.stringify(word.value)} depends on a variable or substitution that cannot be resolved without running it`);
    if (ctx.embedded && isDynamicText(value)) deny("RM_UNPROVABLE", `${label} -r target ${JSON.stringify(value)} is built dynamically`);
    checkDeleteTarget(value, st, ctx, `${label} -r`);
  }
}

const FIND_EXEC = new Set(["-exec", "-execdir", "-ok", "-okdir"]);

function checkFind(args, st, ctx) {
  const roots = [];
  let i = 0;
  for (; i < args.length; i += 1) {
    const v = args[i].value;
    if (v.startsWith("-") && v !== "-") {
      if (["-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d", "-f"].includes(v) && (v === "-f")) {
        i += 1;
        continue;
      }
      if (["-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d"].includes(v)) continue;
      break;
    }
    if (v === "(" || v === "!") break;
    roots.push(args[i]);
  }
  const rest = args.slice(i);
  let deletes = rest.some((w) => w.value === "-delete");
  const execs = [];
  for (let j = 0; j < rest.length; j += 1) {
    if (!FIND_EXEC.has(rest[j].value)) continue;
    const cmd = [];
    for (j += 1; j < rest.length && rest[j].value !== ";" && rest[j].value !== "+"; j += 1) cmd.push(rest[j]);
    execs.push(cmd);
  }
  let destructive = deletes;
  for (const cmd of execs) {
    const name = basename(cmd[0]?.value || "");
    if (name === "kill" || name === "pkill" || name === "killall") deny("KILL_XARGS", `find -exec ${name} feeds PIDs the guard cannot prove`);
    if (name === "rm") destructive = true;
    if (SHELLS.has(name) || isInterpreter(name)) {
      const pos = { words: cmd, index: 0, command: cmd[0] };
      dispatch(cmd, st, { ...ctx, embedded: true }, pos, { find: true });
    }
  }
  if (!destructive) return;
  if (roots.length === 0) roots.push({ value: ".", literal: true, subs: [] });
  for (const word of roots) {
    const value = wordValue(word, st);
    if (value === null) deny("RM_UNPROVABLE", `find start path ${JSON.stringify(word.value)} cannot be resolved before a -delete or -exec rm`);
    checkDeleteTarget(value.endsWith("/") ? value : `${value}/`, st, ctx, "find -delete", true);
  }
}

// ---------------------------------------------------------------- kill

function checkKill(args, st, ctx) {
  let signalSeen = false;
  let end = false;
  const targets = [];
  for (let i = 0; i < args.length; i += 1) {
    const v = args[i].value;
    if (!end && v === "--") {
      end = true;
      continue;
    }
    if (!end && (v === "-l" || v === "-L" || v === "-t")) return;
    if (!end && (v === "-s" || v === "-n" || v === "--signal")) {
      signalSeen = true;
      if (/^(0|EXIT)$/.test(args[i + 1]?.value || "")) return;
      i += 1;
      continue;
    }
    if (!end && !signalSeen && /^-(\d+|[A-Za-z][A-Za-z0-9]*)$/.test(v)) {
      signalSeen = true;
      if (v === "-0") return;
      continue;
    }
    targets.push(args[i]);
  }
  if (targets.length === 0) return;
  for (const word of targets) {
    const raw = word.value;
    if (/^%/.test(raw) || raw === "$!" || raw === "$$" || raw === "${!}") continue;
    const ref = raw.match(/^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/);
    if (ref && st.ownPids.has(ref[1])) continue;
    const value = wordValue(word, st);
    if (value === null || !/^-?\d+$/.test(value)) {
      const shown = word.subs.length > 0 ? `$(${word.subs[0].content})` : raw;
      deny("KILL_UNPROVABLE", `kill target ${JSON.stringify(shown)} is not a literal PID, so its owner cannot be proven (run \`ps -o pid,ppid,command -p <pid>\` yourself, then kill the literal PID)`);
    }
    const pid = Number(value);
    if (pid <= 0) deny("KILL_GROUP", `kill target ${value} addresses a process group or every process`);
    const problem = ownershipProblem(pid, ctx);
    if (problem) deny("KILL_FOREIGN", problem);
  }
}

// ---------------------------------------------------------------- code scan

const KILL_PRIMITIVE = /\bos\.(?:kill|killpg)\s*\(|\bsignal\.pthread_kill|\bpsutil\b[^\n]*\b(?:kill|terminate)\b|\bprocess\.kill\s*\(|\bProcess\.(?:kill|detach)\b|\blibc\.kill|\bkillpg\b|\bkill\s*\(\s*-?\w|\bkill\s+-?\d|\.kill\s*\(|\.terminate\s*\(/;
const ENUMERATION = /\bpsutil\.(?:process_iter|pids)|\bpgrep\b|\bpidof\b|\bps\s+(?:-|aux|ax)|\blsof\b|\bos\.listdir\s*\(\s*['"]\/proc|\bglob\s*\([^)]*\/proc|\bfuser\b|\bwmic\b|\btasklist\b|process\.list|\bps\.?\s*\(|child_process[^\n]*\bps\b/;
const BROAD_NAMES = /(?:^|[^A-Za-z0-9_.\-/])(?:pkill|killall|killall5)(?![A-Za-z0-9_])/;
const RMTREE = /\b(?:rmtree|rmSync|rmdirSync|removedirs|rimraf|rm_rf|rm_r|remove_dir|remove_tree)\s*\(|\bfsp?\.(?:promises\.)?rm\s*\(/;
const OPAQUE = /\b(?:exec|eval|compile)\s*\(|__import__\s*\(|importlib\.import_module|getattr\s*\(\s*(?:os|signal|shutil|subprocess|sys|builtins)\b|globals\s*\(\s*\)\s*\[|b64decode|base64\.|marshal\.loads|pickle\.loads|new\s+Function\s*\(|vm\.run\w+\s*\(|ctypes\.(?:CDLL|cdll)|System\.loadLibrary/;
const CAPABILITY = /\b(?:os|subprocess|shutil|signal|psutil|ctypes|child_process|fs|Process|system|popen|exec|Kernel)\b/;
const STRING_LITERAL = /(?:"""([\s\S]*?)"""|'''([\s\S]*?)'''|"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'|`((?:[^`\\]|\\.)*)`)/g;
const LIST_LITERAL = /[[(]\s*((?:(?:"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')\s*,\s*)+(?:"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'))\s*,?\s*[\])]/g;

function unquoteLiteral(piece) {
  return piece.slice(1, -1).replace(/\\(["'\\])/g, "$1");
}

function embeddedShellStrings(text) {
  const out = [];
  for (const m of text.matchAll(LIST_LITERAL)) {
    const parts = m[1].match(/"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/g) || [];
    out.push(parts.map((p) => {
      const v = unquoteLiteral(p);
      return /[\s"'$`;|&<>()*?]/.test(v) || v === "" ? `'${v.replace(/'/g, `'\\''`)}'` : v;
    }).join(" "));
  }
  for (const m of text.matchAll(STRING_LITERAL)) {
    const value = m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5] ?? "";
    if (DANGER_RAW.test(value) && /\s/.test(value)) out.push(value);
    else if (/^(?:pkill|killall|killall5)$/.test(value.trim())) out.push(value.trim());
  }
  return out;
}

const STRING_CONCAT = /(["'])((?:[^"'\\\n]|\\.)*)\1(?:\s*\+\s*|\s+)(["'])((?:[^"'\\\n]|\\.)*)\3/;

function foldConcatenation(text) {
  let folded = text;
  for (let guard = 0; guard < 64; guard += 1) {
    const next = folded.replace(STRING_CONCAT, (_, quote, a, _quote, b) => `${quote}${a}${b}${quote}`);
    if (next === folded) break;
    folded = next;
  }
  return folded;
}

function scanCode(rawText, lang, st, ctx, depth, origin) {
  const text = foldConcatenation(rawText);
  if (BROAD_NAMES.test(text)) deny("BROAD_KILL_SCRIPT", `${origin} calls pkill/killall, which match processes by name or pattern across every worker`);
  if (KILL_PRIMITIVE.test(text) && ENUMERATION.test(text)) {
    deny("BROAD_KILL_SCRIPT", `${origin} enumerates processes and kills them; that pattern can hit other workers' processes`);
  }
  const literalPids = [
    ...text.matchAll(/\b(?:os\.(?:kill|killpg)|process\.kill)\s*\(\s*(-?\d+)/g),
    ...text.matchAll(/\bProcess\.kill\s*\(?\s*[:'"\w-]+\s*,\s*(-?\d+)/g),
    ...text.matchAll(/(?<![\w.$@])kill\s*\(?\s*['"]?-?\w+['"]?\s*,\s*(-?\d+)/g),
  ];
  for (const m of literalPids) {
    const pid = Number(m[1]);
    if (pid <= 0) deny("KILL_GROUP", `${origin} kills process group or every process (${m[1]})`);
    const problem = ownershipProblem(pid, ctx);
    if (problem) deny("KILL_FOREIGN", `${origin}: ${problem}`);
  }
  if (ctx.strict) {
    if (/\b(?:os\.(?:kill|killpg)|process\.kill)\b(?!\s*\()|\bfrom\s+os\s+import\b[^\n]*\bkill(?:pg)?\b/.test(text)) {
      deny("KILL_UNPROVABLE", `${origin} refers to a kill primitive without calling it directly, so the target PID cannot be proven yours`);
    }
    for (const m of text.matchAll(/\b(?:os\.(?:kill|killpg)|process\.kill)\s*\(\s*([^,)]*)/g)) {
      const arg = m[1].trim();
      if (!/^-?\d+$/.test(arg) && !/^[A-Za-z_][\w.]*\.pid$/.test(arg)) {
        deny("KILL_UNPROVABLE", `${origin} kills ${JSON.stringify(arg)}, which is neither a literal PID nor the .pid of a process the code itself started`);
      }
    }
  }
  if (OPAQUE.test(text) && CAPABILITY.test(text) && (KILL_PRIMITIVE.test(text) || RMTREE.test(text) || ctx.strict)) {
    deny("OPAQUE_EXEC", `${origin} builds or loads code dynamically (exec/eval/__import__/getattr/base64/ctypes) next to process or filesystem capability; the guard cannot see what it will run, so this form is refused`);
  }
  if (RMTREE.test(text)) {
    for (const m of text.matchAll(/(?:rmtree|rmSync|rmdirSync|rimraf|rm_rf|rm_r|remove_tree|removedirs|fsp?\.rm)\s*\(\s*(f?r?['"])((?:[^'"\\\n]|\\.)*)['"]/g)) {
      if (/^f/.test(m[1]) && isDynamicText(m[2])) deny("RM_UNPROVABLE", `${origin} removes ${JSON.stringify(m[2])}, built dynamically`);
      checkDeleteTarget(m[2], st, ctx, "recursive delete");
    }
    if (ctx.strict) {
      for (const m of text.matchAll(/(?:rmtree|rmSync|rmdirSync|rimraf|rm_rf|rm_r|remove_tree|removedirs|fsp?\.rm)\s*\(\s*([^'"\s)][^,)]*)/g)) {
        if (!/^(?:f?r?['"])/.test(m[1])) deny("RM_UNPROVABLE", `${origin} removes ${JSON.stringify(m[1].trim())}, a non-literal path that cannot be proven to be inside your copy`);
      }
    }
  }
  if (ctx.strict && /\bos\.(?:remove|unlink|rmdir)\s*\(|\.unlink\s*\(|\.rmdir\s*\(|\bunlink\s*[(\w]|\bunlinkSync\s*\(/.test(text)
      && /\bos\.(?:walk|listdir|scandir)\s*\(|\bglob\b|\biterdir\s*\(|\brglob\s*\(|\breaddirSync\s*\(|\bFile\.find\b/.test(text)) {
    deny("BULK_DELETE_SCRIPT", `${origin} enumerates files and deletes them one by one, which is a recursive delete the guard cannot bound to your copy`);
  }
  if (lang !== "shell") {
    const sub = { ...ctx, embedded: true };
    for (const piece of embeddedShellStrings(text)) analyzeShell(piece, cloneState(st), sub, depth + 1);
  }
}

// ---------------------------------------------------------------- scripts

// A script is "reviewed" only when it exists unchanged in the task base: the
// commit the worktree was at when fm-spawn launched the worker, carried in the
// launch environment (FM_WORKER_GUARD_BASE). A branch or ref inside the
// worker's own repository could be moved by the worker, so none is consulted;
// without the variable no script is trusted. A file the worker added, edited,
// or committed itself is therefore scanned strictly, like inline code.
function isTrackedUnmodified(file, ctx) {
  const base = process.env.FM_WORKER_GUARD_BASE || "";
  if (!/^[0-9a-f]{7,64}$/.test(base)) return false;
  try {
    const relative = path.relative(ctx.roots.primary, file);
    const bytes = readFileSync(file);
    const hash = createHash(base.length > 40 ? "sha256" : "sha1");
    hash.update(`blob ${bytes.length}\0`);
    hash.update(bytes);
    const trusted = execFileSync("git", ["-C", ctx.roots.primary, "rev-parse", "--verify", `${base}:${relative}`], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      env: { ...process.env, GIT_NO_REPLACE_OBJECTS: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
    }).trim();
    return trusted === hash.digest("hex");
  } catch {
    return false;
  }
}

function languageOf(file, text) {
  const shebang = text.startsWith("#!") ? text.split("\n", 1)[0] : "";
  if (/\b(?:ba|z|da|k|a)?sh\b/.test(shebang) || /\.(?:sh|bash|zsh)$/.test(file)) return "shell";
  if (/python|\.py$/.test(shebang + file)) return "python";
  if (/node|bun|deno|\.(?:m?js|cjs|ts)$/.test(shebang + file)) return "node";
  if (/ruby|\.rb$/.test(shebang + file)) return "ruby";
  if (/perl|\.pl$/.test(shebang + file)) return "perl";
  return shebang ? "other" : "";
}

function userWritable(file) {
  for (const target of [file, path.dirname(file)]) {
    try {
      accessSync(target, fsConstants.W_OK);
      return true;
    } catch {}
  }
  return false;
}

function scanScriptFile(rawPath, st, ctx, depth, hintLang) {
  const abs = path.isAbsolute(rawPath) ? rawPath : st.cwd ? path.join(st.cwd, rawPath) : null;
  if (!abs) return;
  const physical = ctx.roots.physical(abs);
  const virtual = st.vfiles.get(physical) ?? st.vfiles.get(abs);
  let text;
  let strict = true;
  if (virtual !== undefined) {
    text = virtual;
  } else {
    // A script outside the copy is still worker-reachable code (/tmp, home);
    // only installed system locations are trusted as other people's tools.
    if (SYSTEM_PREFIXES.some((prefix) => physical.startsWith(prefix)) && !userWritable(physical)) return;
    try {
      const stat = statSync(physical);
      if (!stat.isFile() || stat.size > MAX_SCRIPT_BYTES) return;
      text = readFileSync(physical, "utf8");
    } catch {
      return;
    }
    strict = !(ctx.roots.contains(physical) && isTrackedUnmodified(physical, ctx));
  }
  const lang = hintLang || languageOf(physical, text);
  if (!lang) return;
  const sub = { ...ctx, strict, embedded: false };
  const origin = `script ${path.relative(ctx.roots.primary, physical) || physical}`;
  if (lang === "shell") {
    if (strict) analyzeShell(text, cloneState(st), { ...sub, nested: true }, depth + 1);
    else scanCode(text, "shell", st, sub, depth, origin);
    if (!strict) analyzeShellBroadOnly(text, cloneState(st), sub, depth + 1);
  } else {
    scanCode(text, lang, st, sub, depth, origin);
  }
}

// A reviewed, committed shell script is held only to the definitive broad motifs.
function analyzeShellBroadOnly(text, st, ctx, depth) {
  try {
    analyzeShell(text, st, { ...ctx, broadOnly: true }, depth);
  } catch (error) {
    if (error instanceof Deny && /^(?:BROAD_KILL|KILL_XARGS)$/.test(error.code)) throw error;
  }
}

// ---------------------------------------------------------------- dispatch

const EXTRA_WRAPPERS = new Set(["busybox", "toybox", "nice", "ionice", "time", "setsid", "stdbuf", "caffeinate", "builtin", "doas", "chronic", "unbuffer", "arch", "script"]);

function unwrap(cw) {
  let words = cw;
  for (let guard = 0; guard < 8 && words.length > 0; guard += 1) {
    const name = basename(words[0].value);
    if (!EXTRA_WRAPPERS.has(name)) break;
    let i = 1;
    while (words[i] && words[i].value.startsWith("-")) {
      const takesArg = (name === "nice" && words[i].value === "-n") || (name === "ionice" && /^-[cn]$/.test(words[i].value)) || (name === "stdbuf" && false);
      i += takesArg ? 2 : 1;
    }
    if (name === "nice" && /^\d+$/.test(words[i]?.value || "")) i += 1;
    words = words.slice(i);
  }
  return words;
}

function xargsInner(args) {
  let i = 0;
  const withArg = new Set(["-I", "-J", "-n", "-P", "-L", "-d", "-E", "-s", "-R", "-S", "-a"]);
  while (args[i] && args[i].value.startsWith("-") && args[i].value !== "--") {
    i += withArg.has(args[i].value) ? 2 : 1;
  }
  if (args[i]?.value === "--") i += 1;
  return args.slice(i);
}

function interpreterInvocation(name, args) {
  // Returns { payload: Word|null, kind: "inline"|"file"|"stdin"|"module", file: Word|null }
  const inlineFlags = SHELLS.has(name) ? /^-[A-Za-z]*c[A-Za-z]*$/ : /^-[A-Za-z]*[ceEp][A-Za-z]*$/;
  for (let i = 0; i < args.length; i += 1) {
    const v = args[i].value;
    if (v === "--eval" || v === "--print" || v === "--command" || v === "--execute") return { kind: "inline", payload: args[i + 1] || null };
    if (inlineFlags.test(v) && !(name === "perl" && /^-[A-Za-z]*[wW]$/.test(v))) {
      let j = i + 1;
      if (args[j]?.value === "--") j += 1;
      return { kind: "inline", payload: args[j] || null };
    }
    if (v === "-m" || v === "-M") return { kind: "module", payload: null };
    if (v === "-") return { kind: "stdin", payload: null };
    if (/^[-+]O$/.test(v) || (/^python/.test(name) && /^-W$/.test(v)) || (name === "node" && /^(?:-r|--require|--import|--loader)$/.test(v))) {
      i += 1;
      continue;
    }
    if (v.startsWith("-") || v.startsWith("+")) continue;
    return { kind: "file", payload: args[i], file: args[i] };
  }
  return { kind: "stdin", payload: null };
}

function langOfInterpreter(name) {
  if (SHELLS.has(name)) return "shell";
  if (/^(?:python|pypy)/.test(name)) return "python";
  if (/^(?:node|nodejs|bun|deno|tsx|ts-node)$/.test(name)) return "node";
  if (/^ruby/.test(name)) return "ruby";
  if (/^perl/.test(name)) return "perl";
  return "other";
}

// Substitutions inside inline code are limited to commands whose output is
// fixed metadata the worker cannot shape: no file, environment, config, branch
// name, directory listing, or argument text is ever echoed back, so the result
// cannot spell a command word or a path.
const FLAG_ONLY_READERS = new Set(["pwd", "whoami", "hostname", "nproc", "uname", "id"]);
const REV_PARSE_ARGS = /^(?:--short(?:=\d+)?|--verify|--show-toplevel|--git-dir|--is-inside-work-tree|HEAD)$/;

function readOnlySubstitution(content, st) {
  const lexed = new Lexer(content).tokenize();
  if (lexed.error) return false;
  const program = splitProgram(lexed.tokens);
  if (program.nodes.length === 0) return false;
  for (const tokens of program.nodes) {
    if (tokens.some((t) => t.type === "group" || t.type === "redir" || (t.type === "word" && t.subs.length > 0))) return false;
    const words = tokens.filter((t) => t.type === "word");
    const name = words[0]?.value || "";
    if (st.pathTouched || name.includes("/") || st.aliases.has(name) || st.functions.has(name)) return false;
    const args = words.slice(1).map((w) => w.value);
    if (FLAG_ONLY_READERS.has(name)) {
      if (!args.every((a) => /^-[A-Za-z]+$/.test(a))) return false;
    } else if (name === "date") {
      if (!args.every((a) => /^\+(?:%[A-Za-z][-:_ ]?)+$/.test(a) || /^-[uR]$/.test(a))) return false;
    } else if (name === "git" && words[1]?.value === "rev-parse") {
      if (!args.slice(1).every((a) => REV_PARSE_ARGS.test(a))) return false;
    } else {
      return false;
    }
  }
  return true;
}

// The payload text with a U+0001 marker where each substitution sat, so a
// substitution that forms a command word is visible to the shell walk.
const SUBSTITUTION_MARK = "\u0001";
function payloadText(word) {
  if (word.subs.length === 0) return word.value;
  let text = word.value;
  for (const sub of [...word.subs].sort((a, b) => b.at - a.at)) {
    if (!Number.isInteger(sub.at) || sub.at < 0 || sub.at > word.value.length) {
      deny("OPAQUE_EXEC", "a substitution inside inline code sits at a position the guard cannot reconstruct");
    }
    text = text.slice(0, sub.at) + SUBSTITUTION_MARK + text.slice(sub.at);
  }
  return text;
}

function runInline(text, lang, st, ctx, depth, origin) {
  if (lang === "shell") {
    analyzeShell(text, cloneState(st), { ...ctx, nested: true, strict: ctx.strict ?? true }, depth + 1);
  } else {
    scanCode(text, lang, st, { ...ctx, strict: true }, depth, origin);
  }
}

function dispatch(rawWords, st, ctx, position, extra = {}) {
  let cw = unwrap(rawWords);
  if (cw.length === 0) return;
  if (cw[0].value.includes(SUBSTITUTION_MARK)) {
    deny("OPAQUE_EXEC", "a command word is produced by a substitution inside inline code, which the guard cannot read without running it");
  }
  if (!cw[0].literal || cw[0].subs.length > 0) {
    const ref = cw[0].value.match(/^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/);
    if (ref && st.vars.has(ref[1]) && cw[0].subs.length === 0) {
      const expanded = lexWords(st.vars.get(ref[1]));
      if (expanded) cw = [...expanded, ...cw.slice(1)];
    } else if (ctx.nested || !ctx.broadOnly) {
      deny("OPAQUE_EXEC", `command word ${JSON.stringify(cw[0].value)} is built dynamically and cannot be inspected`);
    } else {
      return;
    }
  }
  if (st.aliases.has(cw[0].value)) {
    const expanded = lexWords(st.aliases.get(cw[0].value));
    if (expanded) cw = [...expanded, ...cw.slice(1)];
  }
  const name = basename(cw[0].value);
  const args = cw.slice(1);

  if (/^(?:pkill|killall|killall5|skill|slay)$/.test(name)) {
    deny("BROAD_KILL", `${name} matches processes by name or pattern and reaches other workers' benches`);
  }
  if (name === "fuser" && args.some((w) => /^-[A-Za-z]*k/.test(w.value))) deny("BROAD_KILL", "fuser -k kills every process holding a file or port");
  if (name === "tmux" && args.some((w) => /^kill-(?:server|session|window|pane)$/.test(w.value))) deny("BROAD_KILL", "tmux kill-* closes sessions that belong to other workers");
  if (name === "herdr" && args.some((w) => /^(?:stop|delete)$/.test(w.value)) && args.some((w) => /^(?:server|session)$/.test(w.value))) {
    deny("BROAD_KILL", "herdr server/session stop or delete affects the captain's fleet; only the guarded lab helper may do it");
  }
  if (name === "launchctl" && args.some((w) => /^(?:kill|stop|remove|bootout|unload)$/.test(w.value))) deny("BROAD_KILL", "launchctl kill/stop/remove/unload stops services other work depends on");

  if (ctx.broadOnly && name !== "xargs" && name !== "kill") {
    // committed scripts: only the definitive motifs above, plus nested analysis below
  }

  if (name === "kill") {
    if (ctx.broadOnly) {
      if (args.some((w) => w.subs.length > 0 && w.subs.some((s) => /pgrep|pidof|lsof|\bps\b/.test(s.content)))) deny("BROAD_KILL", "kill $(pgrep ...) kills whatever matches, across every worker");
      return;
    }
    return checkKill(args, st, ctx);
  }
  if (name === "parallel" && args.some((w) => /^(?:kill|pkill|killall)$/.test(w.value))) {
    deny("KILL_XARGS", "parallel kill feeds the kill PIDs the guard cannot prove are yours");
  }
  if (name === "ssh" && !ctx.broadOnly) {
    const operands = args.filter((w) => !w.value.startsWith("-"));
    // Options with values (-p 22, -i key, -o X=Y) make the host position
    // ambiguous, so every suffix of the operand list is read as a command.
    for (let k = 1; k < operands.length; k += 1) {
      analyzeShell(operands.slice(k).map((w) => w.value).join(" "), cloneState(st), { ...ctx, nested: true }, (ctx.depth ?? 0) + 1);
    }
    return;
  }
  if (name === "git" && !ctx.broadOnly) {
    const dirFlag = args.findIndex((w) => w.value === "-C");
    const sub = args.slice(dirFlag === -1 ? 0 : dirFlag + 2).find((w) => !w.value.startsWith("-"));
    if (sub?.value === "clean") {
      const target = dirFlag === -1 ? st.cwd : wordValue(args[dirFlag + 1], st);
      const base = target && (path.isAbsolute(target) ? target : st.cwd ? path.join(st.cwd, target) : null);
      if (!base || !ctx.roots.contains(ctx.roots.physical(base))) deny("RM_OUTSIDE", "git clean outside your isolated copy deletes another tree's untracked files");
    }
    return;
  }
  if (name === "rsync" && !ctx.broadOnly && args.some((w) => /^--(?:del|delete|delete-[a-z-]+|remove-source-files|remove-sent-files)(?:=|$)/.test(w.value))) {
    // Which operand is the destination depends on option values, so with a
    // delete flag every non-option word must resolve inside the copy.
    for (const word of args.filter((w) => !w.value.startsWith("-"))) {
      const value = wordValue(word, st);
      const abs = value && !/^[^/]+:/.test(value) && (path.isAbsolute(value) ? value : st.cwd ? path.join(st.cwd, value) : null);
      if (!abs || !ctx.roots.contains(ctx.roots.physical(abs))) deny("RM_OUTSIDE", `rsync --delete operand ${JSON.stringify(word.value)} is not provably inside your isolated copy`);
    }
    return;
  }
  if (name === "xargs") {
    const inner = xargsInner(args);
    const innerName = basename(inner[0]?.value || "");
    if (/^(?:kill|pkill|killall)$/.test(innerName)) deny("KILL_XARGS", "xargs kill feeds the kill PIDs the guard cannot prove are yours");
    if (ctx.broadOnly) return;
    if (innerName === "rm" && recursiveFlag(inner.slice(1)).recursive) deny("RM_UNPROVABLE", "xargs rm -r feeds deletions paths the guard cannot resolve before they run");
    if (inner.length > 0) {
      const sub = { ...ctx, embedded: true };
      dispatch(inner, st, sub, position);
    }
    return;
  }
  if (name === "rm") {
    if (ctx.broadOnly) return;
    return checkRm(args, st, ctx);
  }
  if (name === "find") {
    if (ctx.broadOnly) return;
    return checkFind(args, st, ctx);
  }
  if (name === "eval") {
    for (const word of args) {
      for (const sub of word.subs) {
        if (!readOnlySubstitution(sub.content, st)) deny("OPAQUE_EXEC", `eval code is partly produced by $(${sub.content.slice(0, 60)}), which the guard cannot read without running it`);
      }
    }
    const text = args.map((w) => payloadText(w)).join(" ");
    return runInline(text, "shell", st, ctx, ctx.depth ?? 0, "eval");
  }
  if (name === "source" || name === ".") {
    if (args[0]) scanScriptFile(args[0].value, st, ctx, ctx.depth ?? 0, "shell");
    return;
  }
  if (SHELLS.has(name) || isInterpreter(name)) {
    const lang = langOfInterpreter(name);
    const invocation = interpreterInvocation(name, args);
    if (invocation.kind === "inline") {
      if (!invocation.payload) return;
      for (const sub of invocation.payload.subs) {
        if (!readOnlySubstitution(sub.content, st)) {
          deny("OPAQUE_EXEC", `${name} inline code is partly produced by $(${sub.content.slice(0, 60)}), which the guard cannot read without running it (only plain readers such as pwd, date, basename or git rev-parse are allowed inside inline code)`);
        }
      }
      return runInline(payloadText(invocation.payload), lang, st, ctx, ctx.depth ?? 0, `${name} inline code`);
    }
    if (invocation.kind === "file") {
      const file = invocation.file;
      if (file.subs.length > 0 || !file.literal && wordValue(file, st) === null) {
        if (ctx.strict !== false) deny("OPAQUE_EXEC", `${name} runs a script whose path ${JSON.stringify(file.value)} is built dynamically`);
        return;
      }
      return scanScriptFile(wordValue(file, st) ?? file.value, st, ctx, ctx.depth ?? 0, lang === "other" ? "" : lang);
    }
    if (invocation.kind === "stdin") {
      const bodies = position?.stdinBodies ?? [];
      for (const body of bodies) runInline(body, lang, st, ctx, ctx.depth ?? 0, `${name} stdin`);
      if (position?.pipedFrom && bodies.length === 0) {
        const producer = position.pipedFrom;
        if (producer.literalText !== null) runInline(producer.literalText, lang, st, ctx, ctx.depth ?? 0, `${name} piped input`);
        else if (!/^n?awk$|^gawk$|^mawk$/.test(name)) deny("OPAQUE_EXEC", `${name} executes piped input that is not a literal the guard can read`);
      }
    }
    return;
  }
  if (cw[0].value.includes("/") || cw[0].value.startsWith(".")) {
    const value = wordValue(cw[0], st);
    if (value !== null) scanScriptFile(value, st, ctx, ctx.depth ?? 0, "");
  }
}

// ---------------------------------------------------------------- shell walk

function stripPrefixKeywords(tokens) {
  let i = 0;
  while (i < tokens.length && tokens[i].type === "word" && KEYWORDS_PREFIX.has(tokens[i].value) && tokens[i].literal) i += 1;
  return tokens.slice(i);
}

function literalProducerText(tokens) {
  const words = tokens.filter((t) => t.type === "word");
  const heredoc = tokens.find((t) => t.type === "redir" && typeof t.heredoc === "string");
  const name = basename(words[0]?.value || "");
  if (name === "cat" && heredoc && words.length === 1) return heredoc.heredoc;
  if ((name === "echo" || name === "printf") && words.slice(1).every((w) => w.literal && w.subs.length === 0)) {
    return words.slice(1).filter((w) => !w.value.startsWith("-") || w.value === "-").map((w) => w.value).join(" ").replace(/\\n/g, "\n");
  }
  return null;
}

export function analyzeShell(text, st, ctx, depth = 0) {
  if (depth > MAX_DEPTH) deny("DEPTH", "command nesting is too deep to inspect");
  const lexed = new Lexer(text).tokenize();
  if (lexed.error) {
    if (DANGER_RAW.test(text)) deny("UNPARSEABLE", `command text contains kill/delete words but cannot be parsed (${lexed.error})`);
    return;
  }
  const program = splitProgram(lexed.tokens);
  for (let n = 0; n < program.nodes.length; n += 1) {
    const tokens = stripPrefixKeywords(program.nodes[n]);
    const first = tokens[0];
    if (!first) continue;
    if (first.type === "word" && KEYWORDS_SKIP.has(first.value) && first.literal) {
      if (first.value === "for") {
        const variable = tokens[1]?.value;
        if (variable) {
          st.vars.delete(variable);
          st.ownPids.delete(variable);
        }
      }
      continue;
    }
    for (const token of tokens) {
      if (token.type === "group") {
        analyzeShell(token.content, token.kind === "subshell" ? cloneState(st) : st, ctx, depth + 1);
      } else if (token.type === "word") {
        for (const sub of token.subs) analyzeShell(sub.content, cloneState(st), ctx, depth + 1);
      }
    }
    const defined = tokens[0].type === "word" && tokens[1]?.type === "group" && tokens[1].kind === "subshell" && tokens[2]?.type === "group" && tokens[2].kind === "brace"
      ? tokens[0].value
      : tokens[0].type === "word" && tokens[0].value === "function" && tokens[1]?.type === "word" ? tokens[1].value : null;
    if (defined) st.functions.add(defined);
    const position = commandPosition(tokens);
    const words = position.words;
    if (words.some((w) => /^PATH\+?=/.test(w.value))) st.pathTouched = true;
    for (const payload of position.wrapperPayloads) analyzeShell(payload, cloneState(st), ctx, depth + 1);

    // virtual files written by this very command line (heredoc / echo redirection)
    const heredocToken = tokens.find((t) => t.type === "redir" && typeof t.heredoc === "string");
    const writeTargets = [];
    for (let t = 0; t < tokens.length; t += 1) {
      if ((tokens[t].type === "redir" && (tokens[t].value === ">" || tokens[t].value === ">>") && tokens[t + 1]?.type === "word")) writeTargets.push(tokens[t + 1]);
    }
    if (position.command && basename(position.command.value) === "tee") {
      for (const w of words.slice(position.index + 1)) if (!w.value.startsWith("-")) writeTargets.push(w);
    }
    const body = heredocToken ? heredocToken.heredoc : literalProducerText(tokens);
    if (body !== null && body !== undefined) {
      for (const target of writeTargets) {
        const value = wordValue(target, st);
        if (value === null) continue;
        const abs = path.isAbsolute(value) ? value : st.cwd ? path.join(st.cwd, value) : null;
        if (abs) st.vfiles.set(ctx.roots.physical(abs), (st.vfiles.get(ctx.roots.physical(abs)) ?? "") + body);
      }
    }

    if (!position.command) {
      for (const w of words) {
        const m = w.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s);
        if (!m) continue;
        if (m[2] === "$!" || m[2] === "$$") st.ownPids.add(m[1]);
        else st.ownPids.delete(m[1]);
        const value = w.subs.length === 0 ? wordValue({ ...w, value: m[2] }, st) : null;
        if (value !== null) st.vars.set(m[1], value);
        else st.vars.delete(m[1]);
      }
      continue;
    }

    const cmdName = basename(position.command.value);
    const args = words.slice(position.index + 1);
    if (cmdName === "cd" || cmdName === "pushd" || cmdName === "popd") {
      if (cmdName !== "cd") st.cwd = null;
      else if (args.length === 0) st.cwd = ctx.roots.home;
      else {
        const value = wordValue(args.find((a) => !a.value.startsWith("-")) || args[0], st);
        if (value === null || value === "-") st.cwd = null;
        else {
          const expanded = expandTilde(value, ctx.roots);
          st.cwd = path.isAbsolute(expanded) ? path.normalize(expanded) : st.cwd ? path.join(st.cwd, expanded) : null;
        }
      }
      continue;
    }
    if (cmdName === "trap") {
      const handler = args.find((a) => !a.value.startsWith("-"));
      if (handler) analyzeShell(payloadText(handler), cloneState(st), { ...ctx, nested: true, strict: ctx.strict ?? true }, depth + 1);
      continue;
    }
    if (cmdName === "alias") {
      for (const a of args) {
        const m = a.value.match(/^([^=]+)=(.*)$/s);
        if (m) st.aliases.set(m[1], m[2]);
      }
      continue;
    }
    if (cmdName === "export" || cmdName === "declare" || cmdName === "local" || cmdName === "readonly" || cmdName === "typeset") {
      for (const a of args) {
        const m = a.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s);
        if (!m) continue;
        const value = a.subs.length === 0 ? wordValue({ ...a, value: m[2] }, st) : null;
        if (value !== null) st.vars.set(m[1], value);
        else st.vars.delete(m[1]);
      }
      continue;
    }
    if (/^(?:sh|bash|zsh|dash|ksh|ash|python\d*(?:\.\d+)?|node|nodejs|ruby|perl|php|lua|source|\.)$/.test(cmdName)) {
      for (let t = 0; t + 1 < tokens.length; t += 1) {
        if (tokens[t].type === "redir" && tokens[t].value === "<" && tokens[t + 1].type === "group" && tokens[t + 1].kind === "subshell") {
          deny("OPAQUE_EXEC", `${cmdName} runs a script produced by a process substitution, which the guard cannot read without running it`);
        }
      }
    }
    const positionExtras = { stdinBodies: [], pipedFrom: null };
    for (const t of tokens) if (t.type === "redir" && typeof t.heredoc === "string" && t.fd === 0) positionExtras.stdinBodies.push(t.heredoc);
    for (let t = 0; t < tokens.length; t += 1) {
      if (tokens[t].type === "redir" && tokens[t].value === "<<<" && tokens[t + 1]?.type === "word") positionExtras.stdinBodies.push(tokens[t + 1].value);
    }
    if (n > 0 && (program.separators[n - 1] === "|" || program.separators[n - 1] === "|&")) {
      positionExtras.pipedFrom = { literalText: literalProducerText(stripPrefixKeywords(program.nodes[n - 1])) };
    }
    dispatch(words.slice(position.index), st, { ...ctx, depth }, { ...position, ...positionExtras });
  }
}

// ---------------------------------------------------------------- entry

export function decide(options) {
  const home = options.home || process.env.HOME || "/";
  const roots = new Roots(options.root, options.extraRoots || [], home);
  tableCache = null;
  const ownerPid = resolveOwnerPid(options.ownerPid);
  const ctx = { roots, ownerPid, strict: true, nested: false, embedded: false };
  const st = {
    cwd: options.cwd ? roots.physical(options.cwd) : null,
    vars: new Map(),
    ownPids: new Set(),
    aliases: new Map(),
    functions: new Set(),
    vfiles: new Map(),
    pathTouched: false,
  };
  try {
    if (options.code !== undefined && options.code !== null) {
      const lang = /^(?:py|python)/i.test(options.lang || "") ? "python" : /^(?:js|javascript|node|ts)/i.test(options.lang || "") ? "node" : "other";
      scanCode(options.code, lang, st, ctx, 0, "eval tool code");
    }
    if (options.command !== undefined && options.command !== null) analyzeShell(options.command, st, ctx, 0);
  } catch (error) {
    if (error instanceof Deny) return { allow: false, code: error.code, reason: error.message };
    return { allow: false, code: "INTERNAL", reason: `worker-guard [INTERNAL]: policy error, command refused (${error?.message || error}). ${HINT}` };
  }
  return { allow: true };
}

function parseArguments(argv) {
  const result = { extraRoots: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    const take = () => {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      i += 1;
      return argv[i];
    };
    if (name === "--root") result.root = take();
    else if (name === "--extra-root") result.extraRoots.push(take());
    else if (name === "--owner-pid") result.ownerPid = take();
    else if (name === "--cwd") result.cwd = take();
    else if (name === "--command") result.command = take();
    else if (name === "--code") result.code = take();
    else if (name === "--lang") result.lang = take();
    else if (name === "--home") result.home = take();
    else if (name === "--stdin-json") result.stdinJson = true;
    else throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function main() {
  let options;
  try {
    options = parseArguments(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`worker-guard: ${error.message}\n`);
    process.exit(2);
  }
  if (!options.root) {
    process.stderr.write("worker-guard [CONFIG]: no worker root configured, command refused\n");
    process.exit(2);
  }
  if (options.stdinJson) {
    let payload;
    try {
      payload = JSON.parse(readFileSync(0, "utf8"));
    } catch {
      process.stderr.write("worker-guard [PAYLOAD]: hook payload is not valid JSON, tool call refused\n");
      process.exit(2);
    }
    const input = payload?.tool_input ?? payload?.toolInput ?? {};
    if (typeof input.command === "string") options.command = input.command;
    if (typeof payload?.cwd === "string" && !options.cwd) options.cwd = payload.cwd;
    if (options.command === undefined) process.exit(0); // not an execution-shaped tool
  }
  const verdict = decide(options);
  if (verdict.allow) process.exit(0);
  // Optional audit trail of denials (FM_WORKER_GUARD_LOG, set by fm-spawn in the
  // launch environment): lets firstmate see what a worker tried.
  if (process.env.FM_WORKER_GUARD_LOG) {
    try {
      const subject = options.command ?? options.code ?? "";
      appendFileSync(process.env.FM_WORKER_GUARD_LOG, `${new Date().toISOString()}\tdeny\t${verdict.code}\t${JSON.stringify(String(subject).slice(0, 300))}\n`, { mode: 0o600 });
    } catch {}
  }
  process.stderr.write(`${verdict.reason}\n`);
  process.exit(2);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) main();
