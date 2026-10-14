// Destructive-command guard for Firstmate-launched omp (Oh My Pi) task workers.
//
// Loaded by bin/fm-spawn.sh with `-e` for ship and scout workers only. Every
// bash and eval tool call - including the ones a `task` subagent makes, which
// this session's extension also sees - is checked by the shared transport
// bin/fm-worker-guard-pretool-check.sh before it runs, and a nonzero verdict
// blocks it. The worker identity (FM_WORKER_GUARD_ROOT and
// FM_WORKER_GUARD_EXTRA_ROOTS) is fixed in the launch environment and read by
// that transport; nothing here accepts it from the model. The transport fails
// closed, and so does this extension if the transport cannot run.
// docs/worker-guard.md owns the contract, the false positives and the limits.
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const transport = resolve(dirname(fileURLToPath(import.meta.url)), "fm-worker-guard-pretool-check.sh");

type Verdict = { code: number; stderr: string };

function check(args: string[]): Promise<Verdict> {
  return new Promise((done) => {
    const child = spawn(transport, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => done({ code: 2, stderr: "worker-guard: the guard could not run; tool call refused" }));
    child.on("close", (code) => done({ code: code === 0 ? 0 : 2, stderr }));
  });
}

export default function (pi: { on?: (event: string, handler: (event: any, ctx: any) => unknown) => void }) {
  pi.on?.("tool_call", async (event: any, ctx: any) => {
    if (!event || event.type !== "tool_call") return {};
    const input = event.input || {};
    const cwd = String((typeof input.cwd === "string" && input.cwd) || ctx?.cwd || "");
    const base = ["--omp", "--owner-pid", String(process.pid), "--cwd", cwd];
    let args: string[] | null = null;
    if (event.toolName === "bash" && typeof input.command === "string") {
      args = [...base, "--command", input.command];
    } else if (event.toolName === "eval" && typeof input.code === "string") {
      args = [...base, "--lang", String(input.language || ""), "--code", input.code];
    }
    if (!args) return {};
    const verdict = await check(args);
    if (verdict.code === 0) return {};
    return { block: true, reason: verdict.stderr.trim() || "denied by the worker destructive-command guard" };
  });
}
