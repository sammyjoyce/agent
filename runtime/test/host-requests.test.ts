import assert from "node:assert/strict";
import { test } from "node:test";
import { HostRequests } from "../src/tools.js";
import type { OwnerGate } from "../src/failover/owner-gate.js";
import type { HostCommand } from "../src/generated/HostCommand.js";

test("interrupt fences new host calls until owned effects settle and the next turn resumes", async () => {
  const calls: { request: number; call: string }[] = [];
  const cancelled: string[] = [];
  const requests = new HostRequests((request, call) => calls.push({ request, call }),
    (_request, call) => cancelled.push(call));
  const operation: HostCommand = { type: "exec", program: "/bin/sleep", args: ["60"], cwd: "/", timeout_seconds: 90 };
  let settled = false;
  const pending = requests.call(7, operation).then((result) => { settled = true; return result; });
  const admitted = calls[0]; assert.ok(admitted);
  requests.cancelRequest(7); requests.cancelRequest(7);
  assert.deepEqual(cancelled, [admitted.call]);
  await assert.rejects(requests.call(7, operation), /interrupted before/);
  assert.equal(calls.length, 1, "An interrupted turn must not start another effect");
  assert.equal(settled, false, "Cancellation keeps ownership until the executor confirms its result");
  assert.equal(requests.reply(8, admitted.call, { type: "written" }), false);
  assert.equal(requests.reply(7, admitted.call, { type: "process", exit_code: 143, stdout: "", stderr: "", truncated: false }), true);
  assert.equal((await pending).type, "process");
  requests.resumeRequest(7);
  const next = requests.call(7, operation);
  const correction = calls[1]; assert.ok(correction);
  requests.cancelRequest(7);
  assert.deepEqual(cancelled, [admitted.call, correction.call]);
  requests.reply(7, correction.call, { type: "written" }); await next;
  requests.finish(7);
  const independent = requests.call(9, operation);
  const other = calls[2]; assert.ok(other);
  requests.reply(9, other.call, { type: "written" }); await independent;
});

test("interrupt immediately releases embedding callers but preserves independent work and ignores late replies", async () => {
  const calls: { request: number; call: string }[] = [], cancelled: string[] = [];
  const requests = new HostRequests((request, call) => calls.push({ request, call }),
    (_request, call) => cancelled.push(call));
  const embedding: HostCommand = { type: "embed", purpose: "query", texts: ["retained context"] };
  const held = requests.call(7, embedding);
  let result: "pending" | "rejected" = "pending";
  const rejected = held.catch((error: unknown) => {
    assert.ok(error instanceof Error); result = "rejected";
  });
  const independent = requests.call(8, embedding);
  const first = calls[0], second = calls[1]; assert.ok(first && second);
  requests.cancelRequest(7); requests.cancelRequest(7);
  try {
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(result, "rejected", "Read-only cancellation must release the caller without waiting for a host reply");
    await rejected;
    assert.deepEqual(cancelled, [first.call]);
    assert.equal(requests.reply(7, first.call, { type: "failed", message: "Late cancellation receipt" }), false);
    assert.equal(requests.reply(8, second.call, { type: "failed", message: "Independent reply" }), true);
    assert.deepEqual(await independent, { type: "failed", message: "Independent reply" });
    await assert.rejects(requests.call(7, embedding), /interrupted before/);
    requests.resumeRequest(7);
    const next = requests.call(7, embedding); const third = calls[2]; assert.ok(third);
    requests.reply(7, third.call, { type: "failed", message: "New turn" }); await next;
  } finally {
    requests.reply(7, first.call, { type: "failed", message: "Cleanup" });
    requests.reply(8, second.call, { type: "failed", message: "Cleanup" });
    requests.finish(7); requests.finish(8);
    await rejected;
  }
});

function ownerGate() {
  const waiting: { open(): void; refuse(error: Error): void; signal: AbortSignal | undefined }[] = [];
  const gate: OwnerGate = {
    fresh: (signal) => new Promise<void>((resolve, reject) => {
      signal?.addEventListener("abort", () => reject(new Error("The wait at the gate was aborted")), { once: true });
      waiting.push({ open: resolve, refuse: reject, signal });
    }),
  };
  return { gate, waiting };
}

test("a replicated owner emits a host call only after the owner gate opens for it", async () => {
  const calls: string[] = [], { gate, waiting } = ownerGate();
  const requests = new HostRequests((_request, call) => calls.push(call), () => {}, gate);
  const operation: HostCommand = { type: "exec", program: "/bin/true", args: [], cwd: "/", timeout_seconds: 5 };
  const pending = requests.call(7, operation);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(waiting.length, 1, "the call asks the gate once");
  assert.deepEqual(calls, [], "nothing is emitted while the gate is closed");
  waiting[0]?.open();
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(calls.length, 1);
  assert.equal(requests.reply(7, calls[0] ?? "", { type: "written" }), true);
  assert.deepEqual(await pending, { type: "written" });
});

test("a call that ends while it waits at the owner gate never emits a frame", async () => {
  const calls: string[] = [], cancelled: string[] = [], { gate, waiting } = ownerGate();
  const requests = new HostRequests((_request, call) => calls.push(call), (_request, call) => cancelled.push(call), gate);
  const operation: HostCommand = { type: "exec", program: "/bin/true", args: [], cwd: "/", timeout_seconds: 5 };
  const stop = new AbortController();
  const aborted = requests.call(7, operation, stop.signal);
  const interrupted = requests.call(8, operation);
  const ended = requests.call(9, operation);
  const refused = requests.call(10, operation);
  const fence = new Error("The authority refused this owner");
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(waiting.length, 4);
  stop.abort();
  requests.cancelRequest(8);
  requests.finish(9);
  waiting[3]?.refuse(fence);
  await assert.rejects(aborted, /stopped before the host operation started/);
  await assert.rejects(interrupted, /interrupted before the host operation started/);
  await assert.rejects(ended, /request ended before the host operation/);
  await assert.rejects(refused, (error) => error === fence, "the gate's refusal reaches the caller unchanged");
  assert.ok(waiting.slice(0, 3).every((waiter) => waiter.signal?.aborted), "each ended call leaves the gate");
  for (const waiter of waiting) waiter.open();
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.deepEqual(calls, [], "a late opening emits nothing for a call that ended");
  assert.deepEqual(cancelled, [], "a call that never started has nothing to cancel");
  requests.resumeRequest(8);
  const next = requests.call(8, operation);
  await new Promise<void>((resolve) => setImmediate(resolve));
  waiting[4]?.open();
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(calls.length, 1, "the request works again after the interrupt is resumed");
  requests.reply(8, calls[0] ?? "", { type: "written" }); await next;
});

test("calls that wait at the owner gate count toward the pending limit", async () => {
  const { gate, waiting } = ownerGate();
  const requests = new HostRequests(() => {}, () => {}, gate);
  const operation: HostCommand = { type: "exec", program: "/bin/true", args: [], cwd: "/", timeout_seconds: 5 };
  const held = Array.from({ length: 128 }, () => requests.call(7, operation));
  await assert.rejects(requests.call(7, operation), /Too many pending host operations/);
  assert.equal(waiting.length, 128);
  requests.finish(7);
  await Promise.allSettled(held);
});
