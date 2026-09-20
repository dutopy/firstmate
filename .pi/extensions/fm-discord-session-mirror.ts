// Native Pi session mirror for the captain's Discord console
// (docs/discord-conversation-console.md, "Session mirror").
//
// The captain's terminal Pi session is mirrored into one configured #firstmate
// channel through the console's own bot identity, so the mirror introduces no
// second bot and no webhook identity. This extension owns WHICH dialog is new -
// a durable cursor over the live session file - and
// bin/fm-discord-conversation-console.sh's `mirror` subcommand owns the
// delivery: the configured channel, the existing identity, and the shared
// nonce-keyed receipt.
//
// Delivery discipline is the same one the other mirrors already carry:
//
//   * Durable cursor. The position is per session file and advances only after
//     an item's delivery is settled, so a restart resumes instead of replaying.
//   * Exactly-once posting. Each item carries a durable item key derived from
//     its session and source position, and the receipt is keyed by that key, so
//     the same item delivered twice converges on one post whatever the cursor
//     did. Two identical lines from two positions still post twice.
//   * Bounded posts. The command renders one bounded Discord body per item and
//     states any truncation in place, so a mirrored item is never a silently
//     partial message.
//   * Whole turns only. Collection happens at turn_end, never mid-turn; an item
//     with no visible text (a tool-only turn), an errored assistant message, and
//     an operational injection are all skipped rather than posted.
//
// The mirror is inert unless the console config exists with `mirror.enabled`
// true, `mirror.channel_id` set, and `live.posting` true. Both the channel and
// the switch are configuration, and the config is re-read at every turn end, so
// flipping `mirror.enabled` off stops the mirror at the next turn boundary with
// no Pi restart. When the cursor holds no record for the current session file
// and the extension never saw that session start, the cursor is seeded at the
// current position and nothing is posted: enabling the mirror mid-session
// mirrors from then on instead of dumping the session's history.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, SessionManager } from "@earendil-works/pi-coding-agent";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const defaultRoot = resolve(extensionDir, "../..");
const fmRoot = process.env.FM_ROOT_OVERRIDE || defaultRoot;
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || defaultRoot;
const state = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const config = process.env.FM_CONFIG_OVERRIDE || join(fmHome, "config");
const configFile = join(config, "discord-conversation-console.json");
const consoleScript = join(fmRoot, "bin", "fm-discord-conversation-console.sh");
// The console owns this record's meaning; the extension is its only writer. It
// lives beside the console's other state so `status` can report it.
const cursorDir = join(state, "discord-workspace", "conversation-console");
const cursorFile = join(cursorDir, "mirror-cursor.json");

const CURSOR_SCHEMA = "fm-discord-conversation-console.mirror-cursor.v1";
// A turn end must never be held for long: the batch is small and each item is
// one Discord post, so a slow or hung child is bounded and left unrecorded for
// the next turn to retry instead of blocking the captain's session.
const DELIVERY_TIMEOUT_MS = 20000;
// New dialog beyond this many items per turn end waits for the next boundary, so
// a long backlog mirrors as a bounded sequence instead of one burst.
const MAX_ITEMS_PER_TURN = 8;
// The visible text one item may carry. The command bounds the posted body far
// below this; the cap only keeps a pathological message inside the command's own
// raw read bound instead of being refused there.
const ITEM_RAW_CAP = 12000;
const ITEM_KEY_SESSION_CAP = 120;

type MirrorCursor = { file: string; index: number };
type MirrorItem = { tag: "captain" | "main"; text: string; index: number };
type MirrorEntry = {
  type?: string;
  message?: {
    role?: string;
    content?: unknown;
    errorMessage?: string;
    stopReason?: string;
  };
};

const scriptEnv = {
  ...process.env,
  FM_HOME: fmHome,
  FM_ROOT_OVERRIDE: fmRoot,
  FM_STATE_OVERRIDE: state,
  FM_CONFIG_OVERRIDE: config,
};

function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        const piece = part as { type?: string; text?: string };
        return piece && piece.type === "text" && typeof piece.text === "string" ? piece.text : "";
      })
      .filter((text) => text.length > 0)
      .join("\n");
  }
  return "";
}

// Operational injections (watcher wakes, session starts, launch briefs, the
// away supervisor) are fleet machinery, never captain dialog. The classifier is
// the single owner of that question; mirroring an injection would feed the
// captain's console its own supervision traffic.
function isOperationalUserText(text: string): boolean {
  return classifyFirstmateOperationalText(text) !== undefined;
}

function capItemText(text: string): string {
  if (text.length <= ITEM_RAW_CAP) return text;
  const note = `\n[mirror truncated: ${text.length - ITEM_RAW_CAP} characters omitted]\n`;
  const room = ITEM_RAW_CAP - note.length;
  const head = Math.ceil(room / 2);
  return text.slice(0, head) + note + text.slice(head - room);
}

function readCursor(): MirrorCursor | null {
  try {
    const parsed = JSON.parse(readFileSync(cursorFile, "utf8")) as Partial<MirrorCursor>;
    if (typeof parsed.file === "string" && typeof parsed.index === "number" && parsed.index >= 0) {
      return { file: parsed.file, index: Math.floor(parsed.index) };
    }
  } catch {
    // Absent or unreadable: treated as "no record for this session", which seeds
    // rather than replays. Over-delivery is refused by the receipt either way.
  }
  return null;
}

function writeCursor(file: string, index: number, lastError: string): void {
  const record = {
    schema: CURSOR_SCHEMA,
    file,
    index,
    recorded_at: new Date().toISOString(),
    last_error: lastError,
  };
  try {
    mkdirSync(dirname(cursorFile), { recursive: true });
    const tmp = `${cursorFile}.tmp-${process.pid}`;
    writeFileSync(tmp, `${JSON.stringify(record)}\n`, { mode: 0o600 });
    renameSync(tmp, cursorFile);
  } catch {
    // An unwritable cursor is not a reason to lose the turn: the receipt still
    // refuses a second post for an item already delivered.
  }
}

// The durable item key. It names the session and the source position, never the
// text, so a replayed position converges on one post while two identical lines
// from two positions still post twice, and two sessions never collide on the
// same entry index. It stays inside the key shape the command accepts.
function sessionKey(file: string): string {
  const stem = basename(file).replace(/\.jsonl$/, "");
  // Sanitized into the key shape the command accepts, including its leading
  // character, so a pathologically named session file can never hand the
  // command an item key it would refuse on every turn.
  const cleaned = stem.replace(/[^A-Za-z0-9_-]/g, "-").replace(/^[^A-Za-z0-9]+/, "");
  return (cleaned || "session").slice(0, ITEM_KEY_SESSION_CAP);
}

type MirrorSettings = { enabled: boolean; channel: string };

function deliverySettings(): MirrorSettings {
  const off: MirrorSettings = { enabled: false, channel: "" };
  try {
    if (!existsSync(configFile) || !existsSync(consoleScript)) return off;
    const raw = JSON.parse(readFileSync(configFile, "utf8")) as {
      live?: { posting?: boolean };
      mirror?: { enabled?: boolean; channel_id?: unknown };
    };
    const channel = typeof raw.mirror?.channel_id === "string" ? raw.mirror.channel_id : "";
    if (raw.mirror?.enabled !== true || !channel) return off;
    if (raw.live?.posting !== true) return off;
    return { enabled: true, channel };
  } catch {
    // A missing, unreadable, or malformed config is a disabled mirror, never a
    // crashed turn.
    return off;
  }
}

function collectDialog(entries: readonly unknown[], start: number): { items: MirrorItem[]; exhausted: boolean } {
  const items: MirrorItem[] = [];
  for (let index = start; index < entries.length; index += 1) {
    const entry = entries[index] as MirrorEntry;
    if (entry?.type === "message") {
      const message = entry.message;
      const usable =
        message &&
        (message.role === "user" || message.role === "assistant") &&
        // An errored or failed assistant message is a broken turn, not captain
        // dialog, so a partial turn is never mirrored.
        !(message.role === "assistant" && (message.errorMessage || message.stopReason === "error"));
      if (usable) {
        const text = textOfContent(message.content).trim();
        if (text && !(message.role === "user" && isOperationalUserText(text))) {
          items.push({ tag: message.role === "user" ? "captain" : "main", text: capItemText(text), index });
        }
      }
    }
    if (items.length >= MAX_ITEMS_PER_TURN) {
      return { items, exhausted: index + 1 >= entries.length };
    }
  }
  return { items, exhausted: true };
}

type MirrorCollection = { file: string; index: number; items: MirrorItem[]; exhausted: boolean; seed: number | null };

function collectItems(sessionManager: SessionManager, anchor: MirrorCursor | null): MirrorCollection {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const cursor = readCursor();
  if (cursor && cursor.file === file) {
    const collected = collectDialog(entries, Math.min(cursor.index, entries.length));
    return { file, index: entries.length, ...collected, seed: null };
  }
  if (anchor && anchor.file === file) {
    // This session started under the mirror's watch, so its dialog is mirrored
    // from its own beginning.
    const collected = collectDialog(entries, Math.min(anchor.index, entries.length));
    return { file, index: entries.length, ...collected, seed: null };
  }
  // No record for this session and no session start seen: seed the position and
  // post nothing, so enabling the mirror mid-session never dumps history.
  return { file, index: entries.length, items: [], exhausted: true, seed: entries.length };
}

function deletes(path: string): void {
  try {
    unlinkSync(path);
  } catch {
    // best effort cleanup of the staged item text
  }
}

function runDelivery(item: MirrorItem, key: string, channel: string): Promise<{ ok: boolean; detail: string }> {
  return new Promise((resolvePromise) => {
    const textFile = join(cursorDir, `mirror-item-${process.pid}-${item.index}.txt`);
    try {
      mkdirSync(cursorDir, { recursive: true });
      writeFileSync(textFile, `${item.text}\n`, { mode: 0o600 });
    } catch (error) {
      resolvePromise({ ok: false, detail: `could not stage the mirror item: ${String(error)}` });
      return;
    }
    let settled = false;
    const finish = (ok: boolean, detail: string): void => {
      if (settled) return;
      settled = true;
      deletes(textFile);
      resolvePromise({ ok, detail });
    };
    const child = spawn(
      consoleScript,
      [
        "mirror",
        "--config", configFile,
        "--tag", item.tag,
        "--channel", channel,
        "--item-key", key,
        "--text-file", textFile,
      ],
      { stdio: ["ignore", "ignore", "pipe"], env: scriptEnv },
    );
    let stderr = "";
    child.stderr?.on("data", (chunk: Buffer) => {
      if (stderr.length < 400) stderr += chunk.toString("utf8");
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(false, `mirror delivery for entry ${item.index} exceeded ${DELIVERY_TIMEOUT_MS}ms`);
    }, DELIVERY_TIMEOUT_MS);
    child.on("error", (error) => {
      clearTimeout(timer);
      finish(false, `could not start the console mirror command: ${String(error)}`);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) {
        // A settled non-delivery (the command refuses to mirror operational
        // text) also exits 0, so the item is finished either way and the next
        // item follows.
        finish(true, "");
        return;
      }
      const lines = stderr.split("\n").filter((line) => line.trim().length > 0);
      finish(false, (lines[lines.length - 1] ?? `exit ${code}`).trim().slice(0, 300));
    });
  });
}

export default function (pi: ExtensionAPI) {
  // The position this Pi session started at, for the session file this process
  // is actually supervising. Volatile by design: the durable cursor is the
  // authority across a restart, and this only supplies "this session's own
  // beginning" for a session the mirror has never recorded.
  let anchor: MirrorCursor | null = null;
  let delivering = false;

  pi.on?.("session_start", (_event, ctx) => {
    const sessionManager = ctx?.sessionManager;
    if (!sessionManager) return;
    anchor = { file: sessionManager.getSessionFile() ?? "", index: sessionManager.getEntries().length };
  });

  pi.on?.("session_shutdown", () => {
    anchor = null;
  });

  pi.on?.("turn_end", async (_event, ctx) => {
    const settings = deliverySettings();
    if (!settings.enabled || delivering) return;
    const sessionManager = ctx?.sessionManager;
    if (!sessionManager) return;
    let collected: MirrorCollection;
    try {
      collected = collectItems(sessionManager, anchor);
    } catch {
      return;
    }
    if (!collected.file) return;
    if (collected.seed !== null) {
      writeCursor(collected.file, collected.seed, "");
      return;
    }
    if (collected.items.length === 0) {
      writeCursor(collected.file, collected.index, "");
      return;
    }
    const key = sessionKey(collected.file);
    delivering = true;
    try {
      let delivered = 0;
      let lastError = "";
      for (const item of collected.items) {
        const outcome = await runDelivery(item, `${key}:${item.index}`, settings.channel);
        if (!outcome.ok) {
          lastError = outcome.detail;
          break;
        }
        delivered += 1;
        // The cursor advances only once an item is settled, so a failure leaves
        // every un-delivered item for the next turn end.
        writeCursor(collected.file, item.index + 1, "");
      }
      if (delivered === collected.items.length) {
        // Only a batch that reached the end of the entries may jump to it; a
        // batch capped by MAX_ITEMS_PER_TURN resumes at the next entry.
        if (collected.exhausted) writeCursor(collected.file, collected.index, "");
      } else if (lastError) {
        writeCursor(collected.file, collected.items[delivered].index, lastError);
      }
    } finally {
      delivering = false;
    }
  });
}
